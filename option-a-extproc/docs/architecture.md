# Architecture — Envoy AI Gateway v0.5 Memory ExtProc

> 산출물 ③ (킥오프 §2.2). 2026-04-23 Day 3 오전 작성 — 결정 기록. Day 7-8에 검증 결과 덧붙임.

## 0. 시스템 개요

```
Client ──▶ Envoy Gateway (AI Gateway v0.5) ──▶ Upstream (LLM Provider)
                │
                ├── EnvoyExtensionPolicy → Custom ExtProc (memory-extproc, gRPC)
                │        │
                │        └── Redis (chat:<session_id>)
                │
                └── GatewayConfig ─→ AI Gateway Built-in ExtProc (토큰 계산·provider 라우팅)
```

### 0.0 핵심 설계 제약 (PR #6 리뷰 반영, 승격)

> v0.5 AI Gateway 위에 시스템을 설계하려면 이 제약들을 **먼저 이해**해야 한다. 이후 모든 결정이 이 제약에서 출발한다.

1. **AIServiceBackend는 외부 HTTPS를 직접 참조할 수 없다** — `AIServiceBackend.spec.backendRef.kind`는 반드시 Envoy Gateway의 `Backend` CRD(`gateway.envoyproxy.io/v1alpha1`)여야 한다. raw K8s `Service`도 불가. 외부 `openrouter.ai` 연결은 `Backend(fqdn)` + 필요 시 TLS 정책 + CoreDNS 해상도를 거쳐야 한다. 즉 AI Gateway는 "직접 외부 호출 구조"가 아니라 **항상 Backend abstraction을 통과**한다. (참고: 공식 reject 메시지 "BackendRef must be a Backend resource of Envoy Gateway", #[902](https://github.com/envoyproxy/ai-gateway/issues/902))
   - **위반 시 실패 형태:** `kubectl apply` 시 webhook reject + error 메시지 "BackendRef must be a Backend resource of Envoy Gateway". AIServiceBackend가 `Accepted=False` 상태로 고정.
   - **탐지 방법**
     - *1차 확인:* `kubectl apply` stderr 또는 `kubectl get aiservicebackend -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` ≠ `True`.
     - *심화 디버깅:* `kubectl describe aiservicebackend <name>`의 Events, `kubectl logs -n envoy-gateway-system deploy/ai-gateway-controller`에서 reconcile 실패 이유.
2. **AIGatewayRoute 경로에도 Custom ExtProc를 명시적으로 attach해야 한다** — 본 프로젝트는 `EnvoyExtensionPolicy.targetRefs`에 `HTTPRoute/test-route`와 `HTTPRoute/ai-route-openai`를 모두 선언해, 디버그 경로와 공식 v0.5 경로 양쪽에 동일한 메모리 ExtProc를 적용한다.
   - **위반 시 실패 형태:** AIGatewayRoute 경로 호출 시 200은 반환되지만 **mock/backend 로그에 merged messages 누락**(원본 body만 도달) + Redis에 user/assistant 저장 안 됨. "경로는 동작하는데 메모리 기능이 silent-fail".
   - **탐지 방법**
     - *1차 확인:* `scripts/verify-step5.sh` Phase 2-B에서 `received_messages_count >= 3`와 assistant Redis 저장을 함께 확인.
     - *심화 디버깅:* ExtProc 로그(`kubectl logs -n ai-gateway-system -l app=memory-extproc`)에서 `🔁 merged messages count` 라인이 해당 요청 시각에 나타나는지, `kubectl get httproute ai-route-openai -n default -o yaml`로 정책 attach 대상을 재확인.
3. **CRD 실측 버전은 `v1alpha1`** — 킥오프 문서 표기(`v1beta1`)와 다름. upgrade 전환은 `docs/migration-v04-to-v05.md` §5.1 참고.
   - **위반 시 실패 형태:** manifest `apiVersion: v1beta1`로 작성 시 `error: unable to recognize "...": no matches for kind "GatewayConfig" in version "aigateway.envoyproxy.io/v1beta1"`.
   - **탐지 방법**
     - *1차 확인:* `kubectl apply` stderr의 "no matches for kind" 에러.
     - *심화 디버깅:* `kubectl get crd gatewayconfigs.aigateway.envoyproxy.io -o jsonpath='{.spec.versions[*].name}'`로 설치 CRD 버전 확인 + `kubectl explain` 비교.
4. **EnvoyExtensionPolicy CRD는 `processingMode.response.headers`를 노출하지 않는다** — SSE 감지를 헤더로 하려면 CRD 기능 확장 대기. 현재는 body prefix fallback.
   - **위반 시 실패 형태:** `response.headers: Send` 지정 시 `strict decoding error: unknown field "spec.extProc[0].processingMode.response.headers"` → policy `Accepted=False`, 전체 ExtProc 체인 미적용.
   - **탐지 방법**
     - *1차 확인:* `kubectl apply` stderr의 "strict decoding error"; `kubectl get envoyextensionpolicy -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'` ≠ `True`.
     - *심화 디버깅:* `kubectl explain envoyextensionpolicy.spec.extProc.processingMode --recursive`로 노출된 필드 vs manifest 비교.
5. **Body mutation 시 Content-Length가 자동 재계산되지 않는다** — ExtProc가 `HeaderMutation(remove_headers=['content-length'])`을 반드시 내보내야 한다. 그러면 Envoy가 chunked로 재작성.
   - **위반 시 실패 형태:** Envoy가 500 + `response_code_details: "mismatch_between_content_length_and_the_length_of_the_mutated_body"`. 요청 바디가 upstream에 전혀 전달되지 않음.
   - **탐지 방법**
     - *1차 확인:* curl 응답 status 500 + 빈 body.
     - *심화 디버깅:* `kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gateway`의 access log에서 `response_code_details` 필드 값 확인. ExtProc가 `HeaderMutation(remove_headers=['content-length'])`를 내보내는지 로그로 역추적.

이 5개 제약은 **본 PoC 설계 전반에 반영되어 있으며**, 위반 시 나타나는 증상과 대응은 각 장에서 다룬다.

### 0.1 표준 배포 패턴 — GatewayConfig + Custom ExtProc 병행 (PR #4 리뷰 반영, 표준 고정)

v0.5에서 ExtProc는 **두 계층으로 병행 운영**한다. 이 구조를 본 프로젝트의 **표준 패턴**으로 고정한다 — 이후 Day 7 Phase 2-B/운영 전환에서도 이 원칙 유지.

| 레이어 | 용도 | 구성 리소스 | 수정 주체 |
|--------|------|-------------|-----------|
| **AI Gateway Built-in ExtProc** | 토큰 계산, provider 라우팅, schema 변환 등 AI Gateway 자체 로직 | `GatewayConfig.spec.extProc.kubernetes` (resources/env/image) + Gateway annotation `aigateway.envoyproxy.io/gateway-config` | AI Gateway controller (자동 주입) |
| **Custom ExtProc** (본 프로젝트 메모리 로직) | 대화 히스토리 주입·저장 | `Deployment` + `Service` + `EnvoyExtensionPolicy`(+`ReferenceGrant`) | 사용자 (`memory-extproc.yaml`, `extproc-policy.yaml`) |

**원칙:**
- **Built-in ExtProc의 env/resources는 GatewayConfig가 단독 소유.** `memory-extproc` Deployment spec에 중복 선언하지 않는다.
- **Custom ExtProc의 env는 Deployment spec이 단독 소유.** GatewayConfig로 이관하지 않는다(그러면 메모리 Pod가 env를 못 받음).
- 두 ExtProc가 같은 request에 대해 **순차적으로 작동 가능**하지만, Filter 순서는 Envoy Gateway가 정책별로 관리. 현재는 Custom만 request/response body mutation 담당.
- 추후 새로운 커스텀 ExtProc를 추가할 때도 동일 패턴 — 별도 Deployment + `EnvoyExtensionPolicy`로 연결.

**메모리 파이프라인:**
1. Client는 `x-session-id` 헤더와 함께 `/v1/chat/completions` 호출.
2. ExtProc `request_headers`에서 session_id 추출, `request_body`에서 Redis history와 messages 병합.
3. `CONTINUE_AND_REPLACE`로 body mutation → 합쳐진 messages가 담긴 body로 upstream에 전달.
4. `response_body`에서 assistant 응답을 Redis에 append.

## 1. 결정 기록 (Decision Log)

본 프로젝트의 주요 아키텍처 결정 6개. 각각 **근거 / 대안 / 트레이드오프** 3항목.

> **정책 확정 상태 (Day 3 리뷰 반영):** 아래 결정 중 #2 세션 ID 정책, #4 stream 범위, #5 fail mode 세 가지는 **PoC 수준의 잠정 결정**이다. 운영 전환 시 재검토 대상이며, 각 결정 하위의 "후속 검토" 항목에 변경 경로를 남겨둔다.

### 결정 1 — Option A (Custom ExtProc) 채택

- **근거:** 킥오프 §5.1에서 Option A는 "완전한 유연성, 중첩 JSON 조작 가능, 외부 저장소 연동 자유". 메모리 로직을 Gateway 내부(ExtProc)에 두면 client가 session_id만 전달하면 돼 client 복잡도 최소화.
- **대안:** Option B (Body Mutation + 외부 서비스). 설정 기반이라 코드는 적지만 top-level 필드 한계 + 별도 Memory Service 필요.
- **트레이드오프:** 개발 복잡도 ↑ (gRPC ExtProc SDK), 하지만 control 완전. PoC 단계에서는 단일 컴포넌트로 구현/디버깅이 유리.

### 결정 1-a — 세션 ID 누락 시 400 반환 (PoC 잠정)

- **근거:** PoC 단계에서는 client SDK가 명시적으로 세션을 관리하도록 강제해 동작 흐름을 단순화. 기존 `default` 공유 버킷은 세션 오염 위험.
- **대안:** 서버 측 UUID 자동 발급 후 response header(`x-session-id`)로 회신.
- **트레이드오프:** PoC에서는 400이 더 명확하지만 **실사용 UX 측면에서는 공격적**. `curl` 실수만으로 400이 뜸.
- **후속 검토:** 프로덕션 전환 시 "UUID fallback + header 회신"으로 완화 가능. 해당 전환이 발생하면 본 문서를 업데이트하고 `ops-checklist.md` 롤백 절차에 반영.

### 결정 2 — GatewayConfig CRD 필수 도입

- **근거:** 킥오프 §3.3 Breaking Change. v0.4의 `filterConfig.externalProcessor.resources`는 v0.6에서 제거 예정. Goal 1(마이그레이션) 충족의 필수 요소.
- **대안:** `EnvoyExtensionPolicy`만 유지. Day 4에 작업 최소. 하지만 Goal 1 미충족 → 프로젝트 핵심 산출물(마이그레이션 가이드) 공백.
- **트레이드오프:** 추가 manifest 1개(`gatewayconfig.yaml`) + Gateway annotation 배선. 이득은 Goal 1 정식 충족 + 공식 v0.5 배포 패턴 증명.

### 결정 3 — `schema.name` 기본 사용, `schema.prefix`는 외부 OpenRouter 전환용

- **근거:** 현재 기본 PoC 경로는 `AIServiceBackend(ai-service-openai-via-mock)`에서 `schema.name: OpenAI`만 선언한다. `schema.prefix`는 OpenRouter의 `/api/v1` upstream prefix가 필요한 외부 전환용 `aiservice-backend-openrouter-external.yaml`에서만 사용한다.
- **대안:** 기본 mock 경로에도 `schema.prefix`를 두는 방식. 하지만 mock backend는 OpenAI-compatible path prefix 변환 검증 대상이 아니므로 기본 PoC 경로에 불필요한 설정을 늘린다.
- **트레이드오프:** 기본 PoC와 외부 전환 경로의 schema 설정이 다르다. 대신 실제 사용 목적에 맞춰 mock 경로는 `schema.name`만, OpenRouter 경로는 `schema.name` + `schema.prefix: /api/v1`로 분리된다.

### 결정 4 — OpenAI `stream:false` 전용 (PoC scope)

- **근거:** ExtProc `response_body`는 `Streamed` 모드에서 여러 chunk로 수신. SSE 포맷(`data: {...}\n\n`) 청크 조립 + 완성된 assistant content 추출은 PoC 2주 범위에서 복잡도 과대. stream:false로 좁혀야 assistant 저장(Goal 2 핵심)이 안정적.
- **대안:** streaming 지원. 실제 운영 환경에서는 필요하지만 PoC에서는 out-of-scope.
- **트레이드오프:** streaming 요청이 들어오면 mutation 없이 통과 + 경고 로그. 운영 체크리스트에 "streaming 확장"을 follow-up 항목으로 명시.
- **현재 활성 여부 — Day 4 PM 필수 적용, body-level 감지로 전환:** Day 3에는 `response_headers` 분기 + content-type 감지로 구현했으나 Day 4 PM에 **Envoy Gateway v1.6 `EnvoyExtensionPolicy` CRD가 `processingMode.response.headers` 필드를 노출하지 않음**을 확인(`kubectl explain envoyextensionpolicy.spec.extProc.processingMode` 결과). 따라서 `response_headers` 이벤트는 ExtProc로 전달되지 않으며 해당 분기는 앞으로도 dead code. 대신 **body-level 감지**로 전환: `response_body`의 **첫 chunk**가 `data:` / `event:` / `id:` 중 하나로 시작하면 SSE로 간주하고 누적 건너뜀. 이 경로는 Envoy Gateway CRD 업그레이드 없이 작동한다. `_extract_content_type` 헬퍼와 `response_headers` 분기는 향후 CRD가 해당 필드를 노출할 때 복원 가능하도록 유지.

- **SSE 감지 보강 (PR #4 리뷰 반영):**
  - **Heuristic 오탐 경계:** prefix `data:` / `event:` / `id:`는 SSE 표준이지만, JSON 응답 중에도 동일 시퀀스가 나올 수는 없으므로(`{` 또는 공백으로 시작해야 함) 오탐 가능성 낮음. 그러나 **late-chunk 재감지**를 추가: 첫 chunk가 JSON 시작처럼 보여도 이후 chunk 중간에 `\ndata: ` 패턴이 보이면 SSE로 판정, 그 시점부터 누적 중단.
  - **Partial stream 처리 기준:** SSE로 판정되면 **저장 대상 제외**(assistant 저장 skip). Chunk는 계속 수신하되 `response_buffer`에 누적하지 않고 단순 통과(body mutation 없음, end_of_stream까지 대기). 이로써 Envoy가 client에 보내는 스트림은 온전히 유지되며 ExtProc는 기록만 남긴다.
  - **late-chunk 감지 실패 케이스:** 드물게 JSON 응답 중간에 `\ndata:` 서브스트링이 자연스럽게 포함되면 false positive 가능. 그 경우 assistant 저장이 skip되지만 request는 통과하므로 fail-degraded와 동등한 품질 저하에 그침.
  - **SSE 오탐 시 영향 범위 (PR #5 리뷰 반영, 명시):**
    - **영향 있음:** 해당 턴의 `assistant` 메시지 1건이 Redis에 저장되지 않는다. 다음 턴은 이전 user 메시지까지만 history로 사용.
    - **영향 없음:** request 본문(merged messages)은 정상적으로 upstream에 전달되어 LLM 응답도 정상 반환. client는 응답을 받는다. `user` 턴 저장도 정상(저장 skip은 assistant 한정).
    - **운영 영향 요약:** "저장 누락 한정" — 서비스 중단·보안 사고·데이터 손상 없음. 최악 시나리오는 history 품질의 점진적 저하이며, 이는 fail-degraded와 동등 등급.
  - **xDS transient 실패 조건 및 대응 (PR #7 리뷰 반영):**
    - **재현 조건:** HTTPRoute `backendRefs`를 patch로 교체한 직후 약 3-8초 간 Envoy listener/cluster가 재생성되는 동안 발생. 증상은 `curl: (52) Empty reply from server` 또는 HTTP 502/503. 원인은 Envoy가 이전 cluster를 drain하면서 새 cluster를 아직 ready 상태로 올리지 못함.
    - **대응 정책 (현행):** `scripts/verify-step5.sh`의 Phase2A 블록은 `switch_backend` 후 **ping 200을 받을 때까지 최대 10회(초당 재시도)** 대기. retry 성공 시 **warning만** 출력하고 Gate를 pass. 전체 실패 시 fail.
    - **운영 환경에서는:** client에게 xDS 재구성 순간의 transient를 보이면 안 된다. 운영 전환에서는 **HTTPRoute를 교체 패턴 대신 새 이름으로 추가 → 트래픽 shift → 구 라우트 삭제** 순서(blue-green)를 사용할 것. `ops-checklist.md`에 배포 절차로 기록 필요.
- **후속 검토:** streaming 지원을 정식 범위로 올리려면 SSE 청크 누적 파서 + `delta.content` 연결 로직이 필요. 본 문서에 별도 섹션으로 추가.

### 결정 5 — Fail-Degraded (Redis 장애 시 대화는 계속)

- **근거:** Gateway 중단보다 "기억 없는 대화"가 사용자 경험상 덜 파괴적. LLM 호출 자체를 막으면 모든 요청이 실패하지만, history 없이 통과하면 "새 대화처럼" 동작.
- **대안:**
  - fail-open: Redis 장애 무시하고 그대로 진행 — 로그에 흔적 안 남아 관찰성 ↓.
  - fail-closed: 503 반환 — 가용성 ↓.
- **트레이드오프:** client가 history를 받지 못함을 모름 → 응답 헤더 `x-memory-degraded: true` 또는 로그로만 식별. 운영 체크리스트에 "fail-degraded 발생 시 대응" 항목.
- **장기 위험 및 관측성 보강 (Day 3 리뷰 반영):** fail-degraded는 **조용한 품질 저하**를 유발할 수 있다(사용자 대화가 매번 "새 대화"처럼 동작). 현재 `server.py`는 GET/SETEX 실패를 `_REDIS_FAIL_COUNTER`(get/set 각각)에 누적 카운트하고 세션 ID·err·누적 횟수를 로그에 찍는다. **중요:** 이 카운터는 **프로세스 로컬** 변수이므로 Pod 재시작 시 리셋되고 여러 Replica의 합계가 나오지 않는다. 운영 지표로 신뢰 불가. 로컬 디버깅·재현 테스트 용도로만 사용한다.
- **후속 검토 (운영 전 필수):**
  - `_REDIS_FAIL_COUNTER`를 Prometheus counter(`ext_proc_redis_fail_total{op}`)로 승격, Pod 간 합계와 alert 룰(5분 윈도우에서 N회 이상) 설정.
  - fail-closed 모드 옵션(env `FAIL_MODE=closed`)을 배포별 선택 가능하게 추가 검토.
  - 파싱 실패 로그 preview의 PII 마스킹 규칙 — 현재는 길이 64자 제한만 적용. 운영 전환 시 주요 필드(`messages[*].content`, `user`, `metadata` 등)에 대한 구조적 마스킹 추가.

- **Redis 보안/네트워크 가정 (PR #4 리뷰 반영, PR #5에서 운영 전 필수 결정 항목으로 승격):**
  - **현재 가정:** ExtProc ↔ Redis 통신은 기본값으로 **클러스터 내부 평문** TCP(`redis://redis-master.ai-gateway-system.svc.cluster.local:6379`)를 사용한다. 인증은 `REDIS_PASSWORD`(Secret `redis`의 `redis-password` 키) 1단. 다만 `server.py`와 `memory-extproc.yaml`은 `REDIS_TLS_ENABLED`, `REDIS_TLS_CA_CERT_PATH`, `REDIS_TLS_CHECK_HOSTNAME`를 통해 **TLS 전환 가능한 형태**로 정리됐다.
  - **운영 전 필수 결정 (블로커) — 본 프로젝트 확정 결정 (PR #6 리뷰 반영):**
    1. **Redis TLS 적용: 코드/매니페스트 준비 완료, 클러스터 활성화는 후속 검증 필요.** 현재 저장소는 client 측 `ssl=True`, CA cert path, hostname 검증 옵션을 둘 수 있게 리팩토링됐고 Deployment에도 `/etc/redis-tls/ca.crt` mount 경로를 추가했다. 다만 실제 활성화는 Redis chart의 `tls.enabled=true`와 `redis-tls-ca` Secret 배포, 실제 클러스터 스모크가 뒤따라야 하므로 운영 전에는 여전히 **검증 블로커**다.
       - **활성화 조건:** `REDIS_TLS_ENABLED=true`일 때는 `REDIS_TLS_CA_CERT_PATH`가 유효한 CA 파일을 가리켜야 하고, `REDIS_TLS_CHECK_HOSTNAME=true`를 만족할 수 있도록 Redis 서버 인증서 SAN/CN이 서비스 이름과 맞아야 한다. `redis-tls-ca` Secret은 `ai-gateway-system`에 생성하고 `memory-extproc`에 `/etc/redis-tls/ca.crt`로 mount하는 경로로 고정한다.
       - **실패 정책:** 현재 구현은 TLS 실패 시 자동 plaintext fallback을 하지 않는다. `REDIS_TLS_ENABLED=true` 상태에서 인증서/hostname/handshake가 실패하면 Redis GET/SETEX가 실패하고, 요청 자체는 **결정 5의 fail-degraded** 정책을 따라 history 없이 통과한다. 운영 환경에서는 이를 "허용된 fallback"이 아니라 **misconfiguration**로 본다.
    2. **NetworkPolicy 적용: 확정, `networkpolicy-redis.yaml` 신규 도입.** `app.kubernetes.io/name: redis` Pod에 Ingress 제한 — `app: memory-extproc` Pod에서만 TCP 6379 허용. Day 8 apply 확인 완료. 운영에서는 해당 NetworkPolicy를 반드시 유지하고, CNI가 NetworkPolicy를 enforce하는지(`kubectl exec`로 외부 Pod에서 `redis-cli ping` 실패 확인) 추가 검증.
       - **CNI 의존성 주의 (PR #7 리뷰 반영):** NetworkPolicy는 **CNI가 enforce해야 의미가 있다**. 본 PoC 환경(kind)은 CNI가 enforce해서 정책이 실제 동작(tight policy 적용 시 504 재현으로 확인). 그러나 CNI에 따라 NetworkPolicy를 **무시**하는 경우가 있음 (예: kindnet vanilla, flannel without egress-controller, AWS VPC CNI의 특정 버전 등). 운영 CNI가 Calico / Cilium / Antrea 같은 enforce-capable CNI인지 사전 확인 필수. 미확인 시 정책을 apply해도 **보안 상으로 효력 없음**.
       - **적용 범위 명시:** 현재 NetworkPolicy는 Redis Pod 기준 **Ingress 제한**만 수행한다. 허용 source는 (a) `ai-gateway-system` 네임스페이스의 `app: memory-extproc` Pod, (b) Redis Pod 상호 복제 트래픽 두 가지다. Redis Egress는 별도로 제한하지 않는다. ExtProc → Redis 트래픽 경로는 `memory-extproc` Pod TCP 6379 → `redis-master.ai-gateway-system.svc.cluster.local`이다.
    - **TLS 미적용 조건 명확화 (PR #7 리뷰 반영):** 본 프로젝트에서 Redis TLS를 생략한 결정은 **다음 3조건이 모두 유지되는 환경에서만 허용**된다.
      (a) ExtProc와 Redis가 **동일 Kubernetes 클러스터 내부**에서만 통신 (외부 노출 없음).
      (b) 클러스터 네트워크 세그먼트가 **신뢰 가능** (회사 내부망·VPC 등 외부 접근 차단).
      (c) `networkpolicy-redis.yaml`이 실제 enforce되어 의도하지 않은 Pod에서 Redis 접근 차단됨.
      위 3조건 중 하나라도 깨지면 TLS를 실제 활성화하지 않은 배포는 **차단**한다.
  - **권장 검토 (Recommended):**
    3. **Pod-to-Pod mTLS** — 서비스 메시(예: Linkerd/Istio) 도입 시 TLS를 메시 계층에서 처리 가능. TLS 적용과 중복 시 하나 선택.
  - **본 PoC 유지 사유:** kind cluster 단일 노드, 외부 노출 없음, 디버깅 용이성 우선. 운영 전환 시 본 가정을 **명시적으로 재평가**(`ops-checklist.md` §1의 "운영 전 필수 결정" 체크 항목).

### 결정 5-a — 멀티 choice 응답 채택 정책 (PR #3 리뷰 반영)

- **근거:** OpenAI chat.completions는 `n>1` 요청 시 `choices` 배열에 여러 assistant 응답을 담는다. 현재 `_extract_assistant_content`는 role이 `assistant`인 **첫 항목**을 채택한다(방어적 순회지만 실질은 first).
- **선택:** **first 채택**. 사유 — `n=1` 호출이 PoC 표준이고, 모델의 자연스러운 "주 응답"은 `choices[0]`. 해석 가능성 최대.
- **대안:**
  - `last` 채택: 최신 선택지 우선. 의미 있는 사용례 드묾.
  - `finish_reason` 우선: `stop`인 choice 우선, `length` 등 잘린 응답 회피. 메모리 품질 측면 장점.
- **트레이드오프:** 현재는 first가 단순하고 예측 가능. `n>1` + finish_reason 혼합 사용 사례가 늘면 `finish_reason` 우선으로 재평가.
- **후속 검토:** 멀티-choice 사용이 정식 범위가 될 때 본 결정을 갱신. `docs/ops-checklist.md`에 "멀티 choice 정책 확인" 항목 추가 고려.

### 결정 6 — 실행 순서 "먼저 완주, 그 다음 증명" (Phase 2-A 먼저, Phase 2-B 나중)

- **근거:** AIServiceBackend + AIGatewayRoute + BackendSecurityPolicy 경로는 v0.5 공식 경로지만 CRD webhook reject, schema mismatch, policy binding 등 디버깅 난이도 높음. Proxy 경로로 Step 5를 먼저 닫으면 Goal 2가 확보된 상태에서 Phase 2-B 실험 가능 — 실패해도 프로젝트 완주 리스크 0.
- **대안:** AIServiceBackend를 Primary로. Goal 3 "v0.5 기능 활용"이 가장 강력히 증명되지만, Day 7 오전부터 디버깅 수렁에 빠지면 Goal 2도 못 닫을 위험.
- **트레이드오프:** 구현 컴포넌트가 2개(proxy + AIServiceBackend) → 코드/매니페스트 중복. 대신 "완주 + 증명" 둘 다 확보.

## 2. 왜 Proxy를 먼저, AIServiceBackend를 나중에 썼는가

**요지:** 완주 리스크와 v0.5 증명 리스크를 분리.

- **Phase 2-A (Proxy):** FastAPI 기반 OpenRouter proxy. OpenAI SDK를 `https://openrouter.ai/api/v1`로 고정해 semantic 검증을 수행한다. 성공 확률 높음. Step 5 Gate 6-semantic / Gate 7-assistant 저장을 여기서 닫는다.
- **Phase 2-B (AIServiceBackend):** v0.5 공식 경로. 성공하면 Goal 3 "v0.5 기능 활용"의 가장 강력한 증거. **실패해도 Step 5는 이미 Proxy에서 닫혀 있으므로 프로젝트 완주에 영향 없음** — failure analysis를 작성하면 "도입 시도 + 원인 분석"으로 Goal 3 부분 충족, Plan C(AIServiceBackend → Mock provider)로 최소 기준 2개 확보하면 Goal 3 **완전 충족**.

> 이 순서는 엔지니어링 레벨이 아닌 **프로젝트 관리 레벨의 결정**이다.

## 3. AIServiceBackend 경로 검증 결과

> 2026-04-23 Day 7 PM 업데이트 — 최소 기준 2개(apply 성공 / HTTP 200 OK) **모두 충족**. Plan C(Mock provider 연결) 채택.

### 3.A 성공 케이스 — 2026-04-23 Day 7 PM 검증

**결론: 최소 기준 2개 모두 충족.**

#### 적용된 구조
- `gateway.envoyproxy.io/v1alpha1.Backend` (`mock-llm-backend-eg`) — `mock-llm-backend.default.svc.cluster.local:8000` FQDN 래핑. AIServiceBackend가 raw Service 참조 불가 제약 때문(공식 에러: "BackendRef must be a Backend resource of Envoy Gateway").
- `aigateway.envoyproxy.io/v1alpha1.AIServiceBackend` (`ai-service-openai-via-mock`) — `schema.name: OpenAI`, `backendRef.kind: Backend`로 위 Backend 참조.
- `aigateway.envoyproxy.io/v1alpha1.BackendSecurityPolicy` (`openrouter-api-key-policy`) — `type: APIKey` + `apiKey.secretRef: openrouter-secret`, `targetRefs`로 AIServiceBackend 연결.
- `aigateway.envoyproxy.io/v1alpha1.AIGatewayRoute` (`ai-route-openai`) — Gateway `ai-gateway` 부모에 붙음, `backendRefs`로 AIServiceBackend 참조.

#### 최소 기준 검증 결과
| 기준 | 결과 | 증거 |
|------|------|------|
| 1. apply webhook reject 없이 성공 | ✓ | `kubectl get aiservicebackend,backendsecuritypolicy,aigatewayroute -n default`에서 3종 모두 `Accepted=True` |
| 2. AIGatewayRoute 경로 HTTP 200 OK | ✓ | `curl POST /v1/chat/completions` → `HTTP/1.1 200 OK`, mock provider 응답 수신 |

#### 추가 검증 결과
- [x] merged messages가 provider 요청 payload에 도달
- [x] assistant 저장 동작
- [ ] semantic "홍길동" + "개발자" 재현

**현재 구조:** `EnvoyExtensionPolicy`는 `HTTPRoute/test-route`와 `HTTPRoute/ai-route-openai` 둘 다 대상으로 선언된다. `test-route`는 `Host: debug.local` 디버그 경로, `ai-route-openai`는 기본 호스트의 공식 v0.5 경로다. 두 경로를 호스트로 분리해 route 충돌 없이 공존시켰다.

**검증 범위 정리:**
- Phase 2-A(OpenRouter proxy) — semantic memory 검증
- Phase 2-B(AIGatewayRoute + mock backend) — 공식 경로에서 merged messages + assistant 저장 검증

이로써 Goal 2와 Goal 3이 같은 저장소 구조 안에서 분리 검증된다.

### 3.B Plan C 활성화 기록

- **활성화 이유 (외부 API 제약):** `AIServiceBackend.spec.backendRef`가 Envoy Gateway `Backend` CRD만 수용. 외부 `openrouter.ai` 직결은 추가 `Backend`(FQDN+TLS) + DNS 구성 필요. PoC 일정 감안 kind cluster 내부의 `mock-llm-backend`로 AIServiceBackend를 연결하는 Plan C 채택.
- **구성:** `AIServiceBackend` → `Backend(mock-llm-backend-eg)` → `Service/mock-llm-backend:8000`.
- **효과:** Goal 3 **최소 기준 2개 충족 → "v0.5 공식 경로 사용" 증명 완결**. 또한 `extproc-policy.yaml`이 `ai-route-openai`에도 붙도록 업데이트되어, 공식 경로에서 merged messages와 assistant 저장까지 검증 가능해졌다. Semantic 증명은 여전히 Phase 2-A proxy 경로가 담당한다.

#### Plan C의 한계 (PR #6 리뷰 반영, 명시)

Plan C는 **경로 증명 전용**이며 다음 항목은 **미검증**임을 분명히 한다:

- ❌ **외부 HTTPS 왕복(TLS handshake, SNI, 인증서)** — mock은 HTTP + 클러스터 내부. 실제 OpenRouter endpoint 대상 TLS 경로는 통과해본 적이 없다.
- ❌ **`BackendTLSPolicy` 설정의 유효성** — 초안 매니페스트(`backend-tls-policy-openrouter-external.yaml`)는 있으나 기본 PoC 적용 대상이 아니며 실클러스터 지원/동작 검증 전이다.
- ❌ **외부 DNS 해상도 + egress 제약** — CoreDNS → 외부 DNS → egress NAT 경로가 real 환경에서 작동하는지.
- ❌ **외부 네트워크 장애 시 AI Gateway의 fail 동작** — timeout, connection refuse, DNS 실패 케이스.
- ❌ **BackendSecurityPolicy `APIKey`가 실제 OpenRouter 인증 헤더로 정상 주입되는지** — mock은 key 검증 안 함.

**운영 전 필수 검증:**
1. `Backend` spec을 `fqdn: { hostname: openrouter.ai, port: 443 }`로 전환.
2. TLS 정책 지원 범위 확인 후 필요한 경우 SNI=`openrouter.ai` 기준으로 적용.
3. AIGatewayRoute 경로 curl → 실제 200 + semantic 재현 확인.
4. 네트워크 장애 주입 테스트(`kubectl exec ... iptables -A OUTPUT -d openrouter.ai -j DROP`)로 timeout 처리 확인.
5. 모든 결과를 본 문서 §3.A에 추가.

이 5개가 green이 되기 전까지 **Plan C 상태로는 프로덕션 배포 불가**.

#### 미검증 상태에서 발생 가능한 실제 장애 시나리오 (PR #7 리뷰 반영)

- **시나리오 A — TLS misconfig (SNI/hostname 불일치):** 운영 전환 시 `openrouter.ai` 기준 TLS hostname 검증이 맞지 않으면 upstream handshake 단계에서 거부 → Envoy TLS 오류 + 요청 502. mock Plan C에서는 TLS 레이어 자체가 없어 재현 불가 — 운영 환경에서만 최초 노출.
- **시나리오 B — DNS egress 차단:** `openrouter.ai` DNS 해상도 실패(CoreDNS upstream 차단, NetworkPolicy egress 과도 제한) 시 Envoy `cluster_not_found` 또는 `no_healthy_upstream` → 모든 요청 503. mock은 cluster-internal ClusterIP라 DNS 미사용, 이 경로도 운영 전환에서 최초 노출. 해결: `NetworkPolicy`에 egress 53/TCP+UDP 허용 + `openrouter.ai` 대상 443/TCP 허용.

두 시나리오 모두 **Plan C로는 사전 포착 불가** → 운영 전환 리허설이 반드시 필요함을 의미.

### 3.C 후속 과제 (운영 전환용)
- [ ] `Backend` CRD를 `openrouter.ai`로 전환 + TLS 정책 적용 가능 여부 확인
- [ ] AIGatewayRoute 경로에서 실제 OpenRouter semantic 재검증
- [ ] `test-route` 없이도 디버깅 가능한 blue-green 운영 절차 문서화

### 3.D 외부 OpenRouter 전환 설계 (M3)

저장소에는 운영 전환용 초안 매니페스트를 추가한다.

- `aiservice-backend-openrouter-external.yaml`
  - `Backend(openrouter-api-backend-eg)` → `openrouter.ai:443`
  - `AIServiceBackend(ai-service-openrouter-external)` → 위 Backend 참조
- `backend-security-policy-openrouter-external.yaml`
  - `openrouter-secret`를 외부 경로용 AIServiceBackend에 연결
- `aigateway-route-openrouter-external.yaml`
  - `ai-route-openai`의 backendRef를 외부 OpenRouter용 AIServiceBackend로 전환
- `backend-tls-policy-openrouter-external.yaml`
  - `openrouter.ai` hostname 검증용 초안. 기본 PoC 적용 대상은 아니며 실클러스터 지원 확인 후 적용

이 매니페스트는 **기본 PoC 배포 대상이 아니다**. 기본값은 계속 Plan C(mock)이며, 외부 경로는 운영 전환 또는 리허설 시에만 적용한다.

#### 3.D.1 BackendTLSPolicy 관련 주의

공식 Gateway API 문서 기준 `BackendTLSPolicy`는 기본적으로 **Service 대상 정책**이다. 일부 구현은 다른 backend 종류를 추가 지원할 수 있지만, 이는 구현체별 동작이다. 따라서 현재 저장소는 다음 원칙을 따른다.

1. `Backend(openrouter.ai:443)` + `AIServiceBackend` 경로를 먼저 분리해 둔다.
2. 실제 클러스터에서는 설치된 Envoy Gateway 버전이 `Backend` 대상 TLS 정책을 지원하는지 먼저 확인한다.
3. 지원이 불명확하면, `backend-tls-policy-openrouter-external.yaml`은 적용하지 않고 Service 기반 egress shim 또는 구현체 지원 확인 후 별도 PR로 확정한다.
4. 적용 트리거는 pre-prod에서 DNS 해상도, 443 egress, 인증 헤더, 실제 200 응답이 모두 확인된 시점이다.

즉, 현재 단계의 산출물은 **전환 경로 분리와 운영 전제 명문화**이며, TLS 정책 초안은 존재하지만 기본 적용/실클러스터 검증 항목으로 남긴다.

#### 3.D.2 dev / prod 정책 분리

- **dev / PoC**
  - Plan C(mock) 유지
  - `debug.local` + proxy 경로로 semantic 검증
  - 외부 OpenRouter 의존 없음
- **prod / pre-prod**
  - plaintext fallback 없음은 **hard requirement**
  - mock → external 전환은 Redis TLS + NetworkPolicy enforcement + OpenRouter secret + pre-prod 200 검증이 모두 green일 때만 허용
  - 외부 OpenRouter 경로 적용 시 DNS, egress 443, API key, TLS 검증이 모두 green이어야 함
  - hostname 검증은 `openrouter.ai` 기준으로 수행하며, 내부 DNS 이름을 TLS hostname으로 사용하지 않는다
  - 외부 provider timeout/5xx/DNS 실패는 **fail-closed**로 취급하며 자동 mock fallback을 두지 않는다

#### 3.D.3 DNS / hostname 전제

- Redis TLS는 내부 DNS(`redis-master.ai-gateway-system.svc.cluster.local`)를 전제로 한다.
- 외부 OpenRouter TLS는 `openrouter.ai` SNI/hostname 검증을 전제로 한다.
- 두 경로는 검증 대상 호스트명이 다르므로 운영 문서에서 혼용하지 않는다.

### 3.F 라우팅 구조 결정 (PR #6 리뷰 반영)

**현 PoC 상태:** `test-route`는 `Host: debug.local` 전용 디버그 경로이고, `ai-route-openai`는 기본 호스트의 공식 경로다. 둘 다 path는 `/v1/chat/completions`를 사용하지만 host로 분리되므로 충돌하지 않는다.

**`scripts/verify-step5.sh`의 처리:** Phase 1/2-A는 `Host: debug.local`로 보내고, Phase 2-B는 기본 호스트로 보낸다. 더 이상 AIGatewayRoute를 삭제/복원하는 toggle workaround가 필요 없다.

**운영 전환 시 결정 (택1, Day 8 이후 과제):**

| 옵션 | 설명 | 추천도 |
|------|------|--------|
| **A. 단일 라우팅 (AIGatewayRoute 전용)** | `test-route`를 제거하고 AIGatewayRoute만 남김 | **운영 최종형** |
| **B. Host 분리 (현재 PoC)** | `debug.local` → test-route, 기본 호스트 → AIGatewayRoute | **현재 채택** — 충돌 없이 Step 4/5 모두 검증 가능 |
| **C. Toggle** | 배포마다 AIGatewayRoute를 지웠다 복원 | 폐기 |

**결정:** PoC는 **옵션 B(Host 분리)** 를 사용하고, 운영 전환 시 **옵션 A**로 일원화한다. 운영 전환 PR에는 다음을 포함:
- `test-route.yaml` 삭제
- `verify-step4.sh`의 debug host 의존 제거 또는 별도 내부 디버그 경로 대체
- `ops-checklist.md` §6 롤백 절차를 단일 라우팅 기준으로 조정

#### 옵션 A 구현 상세 — Custom ExtProc을 AIGatewayRoute 경로에 연동 (PR #7 리뷰 반영)

AIGatewayRoute는 apply 시 내부적으로 HTTPRoute를 **자동 생성**한다. 이름은 보통 `<aigatewayroute-name>` 또는 `<aigatewayroute-name>-<hash>` 패턴. Custom ExtProc을 이 경로에도 태우는 두 가지 방법:

**방법 1 — `EnvoyExtensionPolicy.targetRefs` 확장 (추천, 단순):**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: ext-proc-memory-policy
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: ai-route-openai  # AIGatewayRoute가 생성한 HTTPRoute (이름 동일)
  extProc:
    - backendRefs:
        - name: memory-extproc
          namespace: ai-gateway-system
          port: 50051
      processingMode:
        request: { body: Buffered }
        response: { body: Streamed }
```

**방법 2 — `AIGatewayRoute.spec.filterConfig.externalProcessor` (native):**
```yaml
spec:
  filterConfig:
    type: ExternalProcessor
    externalProcessor:
      # resources만 노출 — backend 연결 메커니즘은 controller가 관리
      resources: { requests: { cpu: "100m" }, limits: { cpu: "500m" } }
```
이 경로는 AI Gateway built-in ExtProc의 리소스 제어에 가깝고, Custom ExtProc을 직접 주입하기엔 제약이 크다. **방법 1이 실용적**.

**자동 생성 HTTPRoute 이름 확인:**
```bash
kubectl get httproute -n default -l aigateway.envoyproxy.io/owning-aigatewayroute=ai-route-openai
```

`EnvoyExtensionPolicy.targetRefs`는 실제 존재하는 `HTTPRoute` 이름과 정확히 일치해야 한다. 따라서 AIGatewayRoute가 생성한 HTTPRoute 이름이 `ai-route-openai`인지 반드시 확인하고, controller가 hash suffix 등 다른 이름을 생성하면 `extproc-policy.yaml`의 targetRef도 그 이름으로 맞춘다.

**현재 적용 상태:**
1. `EnvoyExtensionPolicy.targetRefs`에 `test-route`, `ai-route-openai` 둘 다 선언
2. `test-route`에는 `hostnames: [debug.local]` 지정
3. `verify-step4.sh`, `verify-step5.sh`는 디버그 경로에서 `Host: debug.local` 헤더 사용
4. Phase 2-B는 기본 호스트의 `AIGatewayRoute`를 직접 호출해 merged messages + assistant 저장을 검증

### 3.D Failure Analysis (해당 없음)
최소 기준 2개 모두 달성했으므로 failure analysis 작성 대상 아님.

## 3.D Content-Length 처리 원칙 (PR #5 리뷰 반영)

- **원칙:** **모든 mutated request는 chunked transfer로 upstream 전달**한다.
- **구현:** ExtProc의 `request_headers` 응답에서 `content-length` 헤더를 `HeaderMutation(remove_headers=[...])`로 제거한다. Envoy는 본문 교체 후 Content-Length를 재계산하지 않으므로, 헤더를 남기면 `mismatch_between_content_length_and_the_length_of_the_mutated_body` 500이 발생한다.
- **대안 검토:** `request_body` 응답 시점에 새 body 길이로 Content-Length를 재설정하는 방법도 가능. 그러나 (1) chunked가 Envoy·대부분 upstream에서 투명하게 동작하고 (2) 코드 한 곳에서 결정되어 단순하며 (3) `stream:false` + JSON만 다루는 PoC 범위에서 성능 차이 무시 가능.
- **리스크:** 일부 upstream이 Content-Length에 의존할 수 있다(예: 고정 길이 제약 프록시). 본 PoC 대상(OpenAI chat.completions, echo-backend, mock LLM)은 모두 chunked 정상 수용 확인됨. 운영 전환 시 대상 upstream의 chunked 호환성을 `ops-checklist.md`의 "배포 전 환경 체크"에 포함시킨다.

## 3.E 검증 전략 표준 — 경로·역할 2축 분리 (PR #5/#6 리뷰 반영, 표준 고정)

본 프로젝트의 **검증 전략 표준**은 아래 2축으로 **항상 분리**한다.

| 축 | Phase 2-A (Proxy 경로) | Phase 2-B (AIServiceBackend 경로) |
|----|------------------------|-----------------------------------|
| **검증 대상** | **semantic** — 모델이 memory를 반영해 응답 의미가 바뀌는가 | **구조 + memory path** — v0.5 공식 라우팅 체인에서 merged messages와 assistant 저장이 실제로 동작하는가 |
| **경로 구성요소** | ExtProc → FastAPI proxy → 실제 OpenRouter | ExtProc → AIGatewayRoute → AIServiceBackend → Backend → upstream |
| **upstream** | `openrouter.ai` (실제) | `mock-llm-backend` (Plan C) 또는 `openrouter.ai`(운영) |
| **결정성** | 확률적 (모델 응답) | 결정적 (상태 코드·CRD 상태) |
| **사용 지점** | `scripts/verify-step5.sh` Phase2A, 수동 | `scripts/verify-step5.sh` Phase2B, 수동 curl |

**원칙:** 두 축이 동시에 **green**이어야 "memory pipeline + model behavior + v0.5 공식 경로"가 완결됐다고 본다. 둘 중 하나만 쓰면 semantic 또는 공식 경로 메모리 동작 중 하나를 놓친다.

### 3.E 기존 내용 — Mock vs Real Proxy 분리

본 프로젝트의 upstream 검증은 **2계층**으로 고정한다.

| 계층 | 대상 | 목적 | 결정성 | 사용 위치 |
|------|------|------|--------|-----------|
| **Mock LLM** | `tests/mock-llm/` | merged messages 수신 여부·순서·최종 user content를 **deterministic**하게 반사 | 100% | CI/자동화(`verify-step5.sh` Phase 1), 발표 데모 |
| **OpenRouter proxy** | `tests/openrouter-proxy/` | **실제 모델 응답의 semantic**이 memory에 의해 바뀌는지 검증 | 확률적 | 수동·키 필요(`verify-step5.sh` Phase 2-A) |

**원칙:**
- Mock은 pipeline 결함을 분리 검증한다 — 실패 시 ExtProc/매니페스트 쪽 문제.
- Proxy는 semantic을 검증한다 — 실패 시 merged content가 충분하지 않거나 모델이 기억 안 함.
- 두 계층 모두 green이어야 "memory pipeline + model behavior"가 완성됐다고 본다.
- **AIServiceBackend(Phase 2-B)도 이 전략을 따른다** — 필요시 AIServiceBackend 뒤에 Mock을 붙여(Plan C) 공식 route 경로를 검증하고, 그 다음 OpenRouter로 바꿔 semantic을 재검증.

## 4. 데이터 흐름 상세

### 4.1 Request Path
```
1. Client → Envoy Gateway (x-session-id header)
2. Envoy → ExtProc.request_headers       ── session_id 추출
3. Envoy → ExtProc.request_body          ── history 병합, CONTINUE_AND_REPLACE
4. Envoy → Upstream (merged messages 포함 body)
```

### 4.2 Response Path
```
5. Upstream → Envoy (stream:false JSON 응답)
6. Envoy → ExtProc.response_body         ── chunk 누적 (end_of_stream 대기)
7. ExtProc → Redis (assistant append)
8. Envoy → Client (응답 그대로 전달)
```

### 4.3 Redis Key 구조
- Key: `chat:<session_id>`
- Value: JSON array `[{"role":"system"|"user"|"assistant"|"tool","content":"..."}...]`
- TTL: `MEMORY_TTL_SECONDS` (기본 3600s)
- Max length: `MAX_HISTORY_LENGTH` (기본 20, 초과 시 앞에서 잘림)

## 5. Non-Goals (이번 PoC 범위 밖)

- Streaming (`stream:true`) 응답 지원
- Long-term Memory (세션 간 지속)
- Semantic Memory (벡터 임베딩 / 유사도 검색)
- 프로덕션 배포 가이드 / 성능 벤치마크
- MCP 세션 메모리

## 6. 관련 산출물

킥오프 §2.2 공식 산출물 기준:

- 마이그레이션 가이드: [`migration-v04-to-v05.md`](./migration-v04-to-v05.md)
- 운영 체크리스트: [`ops-checklist.md`](./ops-checklist.md)
- PoC 구현체: `server.py` + 매니페스트 yaml + `scripts/verify-*.sh` + `tests/`

부속 문서(프로젝트 내부 기록 — `private_docs/`, gitignore 대상): 프로젝트 계획, 발표 자료, 릴리스 노트, project-log.
