# 운영 체크리스트

> 산출물 ④ (킥오프 §2.2). Day 4 PM 골격 → Day 7 확인 커맨드 보강 → Day 8 polish.
>
> 이 문서는 프로덕션 도입 전에 수행해야 할 스모크·관찰·장애 대응 절차를 체크박스로 정리한다. 자동화 스크립트(`scripts/verify-*.sh`)는 Day 7에 작성되며, 본 문서는 각 항목의 확인 커맨드를 함께 제공해 수동 검증도 가능하게 한다.

## 1. 배포 전 환경 체크

- [ ] Kubernetes v1.32+ — `kubectl version --short`
- [ ] Envoy Gateway v1.6 계열 설치 확인 — `kubectl get deploy -n envoy-gateway-system envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'`
- [ ] AI Gateway v0.5 CRD 설치 확인 — `kubectl get crd | grep aigateway.envoyproxy.io`
  - `gatewayconfigs`, `aigatewayroutes`, `aiservicebackends`, `backendsecuritypolicies` 4종 존재 필수
  - `served`/`storage` 버전 확인 — `kubectl get crd gatewayconfigs.aigateway.envoyproxy.io -o jsonpath='{.spec.versions[*].name}'` (현재 `v1alpha1`, upgrade 리스크는 `migration-v04-to-v05.md` §5.1 참조)
- [ ] Redis 가용성 — `kubectl get pods -n ai-gateway-system -l app.kubernetes.io/name=redis` → 전 Pod Running
- [x] **운영 전 필수 결정 (블로커) — PoC 확정** (PR #7 리뷰 반영)
  - [ ] **Redis TLS 활성화 검증** — 저장소는 TLS-ready 상태(`REDIS_TLS_ENABLED`, `REDIS_TLS_CA_CERT_PATH`, `REDIS_TLS_CHECK_HOSTNAME`, `/etc/redis-tls/ca.crt` mount)지만, 실제 배포 전에는 Redis chart `tls.enabled=true` + `redis-tls-ca` Secret + 실클러스터 연결 검증까지 끝나야 한다. 아직 **배포 블로커로 유지**.
    - 필수 env:
      `REDIS_TLS_ENABLED=true`, `REDIS_TLS_CA_CERT_PATH=/etc/redis-tls/ca.crt`
    - 권장 env:
      `REDIS_TLS_CHECK_HOSTNAME=true`
    - 전제:
      Redis 서버 인증서 SAN/CN이 `redis-master.ai-gateway-system.svc.cluster.local` 또는 실제 서비스명과 일치해야 한다.
  - [x] **NetworkPolicy 적용 여부 확정** — **본 PoC: 적용됨** (`networkpolicy-redis.yaml`). `kubectl get networkpolicy -n ai-gateway-system redis-allow-memory-extproc` 존재 확인. CNI enforcement 확인 완료.
    - 현재 정책은 **cluster-wide deny-by-default가 아니라 Redis ingress allowlist**다.
    - 허용 기준은 `namespace=ai-gateway-system` + `label app=memory-extproc`, 그리고 Redis Pod 상호 통신이다.
    - 필수 전제: Redis Helm chart의 기본 `networkPolicy.enabled=false` 상태에서 repo의 `networkpolicy-redis.yaml`만 Redis Pod를 선택해야 한다.
    - 이유: Kubernetes NetworkPolicy는 union(OR) 방식이므로, Redis chart의 permissive policy가 함께 있으면 repo allowlist가 사실상 무력화된다.
  - [ ] (권장) Pod-to-Pod mTLS 또는 서비스 메시 도입 여부 판단 — PoC 범위 외.
- [ ] **Content-Length chunked 호환성 운영 전 검증 (PR #6 리뷰)** — 대상 upstream이 `Transfer-Encoding: chunked`를 수용하는지 아래 커맨드로 확인.
  ```bash
  curl -sS -o /dev/null -w "%{http_code}\n" \
    -X POST https://<upstream> -H "Transfer-Encoding: chunked" \
    -H "Content-Type: application/json" -d '{"model":"...","messages":[...]}'
  ```
  본 프로젝트 PoC 대상(`openrouter.ai`, `echo-backend`, `mock-llm-backend`)은 모두 200 확인 대상으로 관리한다. 외부 경로는 실제 pre-prod 검증 완료 전까지 mock과 동급으로 간주하지 않는다.
- [ ] `openrouter.key` 파일 준비 (외부 경로 필수) — `ls -la openrouter.key` (gitignore 대상이므로 로컬에만)
- [ ] Secret 생성 — `kubectl create secret generic openrouter-secret --from-file=OPENROUTER_API_KEY=./openrouter.key -n default`
  - 값은 OpenRouter raw key(`sk-or-v1-...`)만 저장하고 `Bearer ` 접두사는 넣지 않는다.
- [ ] Phase 2-A semantic 검증 경로가 `openrouter-proxy` + `OPENROUTER_API_KEY` + `OPENROUTER_BASE_URL=https://openrouter.ai/api/v1` 기준으로 배포됐는지 확인
- [ ] 이미지 빌드 및 kind 로드 — `docker build -t memory-extproc:latest . && kind load docker-image memory-extproc:latest --name ai-gateway-poc`
- [ ] 외부 OpenRouter 경로 적용 시 전환용 매니페스트 사용 여부 확인
  - `aiservice-backend-openrouter-external.yaml`
  - `backend-security-policy-openrouter-external.yaml`
  - `aigateway-route-openrouter-external.yaml`
  - `backend-tls-policy-openrouter-external.yaml` (초안, 기본 적용 전 실클러스터 지원 확인)

## 2. 스모크 테스트 실행

- [ ] `debug.local` 디버그 경로 확인 — `curl -sS -H 'Host: debug.local' http://localhost:28080/ -o /dev/null -w "%{http_code}\n"` 또는 `scripts/verify-step4.sh` 시작 전 첫 요청 확인
- [ ] `scripts/verify-step4.sh` exit 0 — ExtProc ↔ Redis ↔ body mutation 파이프라인
- [ ] `scripts/verify-step5.sh` exit 0 — Mock(Phase 1) + Proxy(Phase 2-A) + AIServiceBackend(Phase 2-B) 경로
- [ ] `ai-route-openai`에 Custom ExtProc attach 확인 — AIGatewayRoute가 생성한 실제 HTTPRoute 이름을 `kubectl get httproute -n default -l aigateway.envoyproxy.io/owning-aigatewayroute=ai-route-openai`로 확인하고, `extproc-policy.yaml`의 `targetRefs` 이름과 일치해야 한다.
- [ ] `./.venv/bin/pytest tests/unit -v` — ExtProc 헬퍼 단위 테스트 green

## 3. 관찰 항목

- [ ] Redis TTL 정상 — `kubectl exec -it -n ai-gateway-system redis-master-0 -- redis-cli -a "$REDIS_PASSWORD" TTL chat:<sid>` → 양수
- [ ] Redis TLS Secret 확인 — `kubectl get secret -n ai-gateway-system redis-tls-ca`
- [ ] Redis TLS env 확인 — `kubectl get deploy -n ai-gateway-system memory-extproc -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REDIS_TLS_ENABLED")].value}'`
- [ ] Redis chart NetworkPolicy 비활성화 확인 — `helm get values redis -n ai-gateway-system | grep networkPolicy`
  - `networkPolicy.enabled=false`가 필수다.
  - `kubectl get networkpolicy -n ai-gateway-system` 결과에서 Redis Pod를 선택하는 policy는 `redis-allow-memory-extproc`만 남아야 한다.
- [ ] NetworkPolicy 범위 확인 — `kubectl describe networkpolicy -n ai-gateway-system redis-allow-memory-extproc`
  - 허용 ingress source는 `app: memory-extproc`와 Redis Pod 상호 통신 2종만 보여야 한다.
  - Redis egress는 현재 제한하지 않는 것이 정상이다.
- [ ] ExtProc 로그 레벨 — `kubectl logs -n ai-gateway-system -l app=memory-extproc --tail=50`에서 경고(⚠️) 빈도 모니터링
- [ ] Redis fail 카운터 — 로그에서 `fail_count_get=` / `fail_count_set=` 추이 (`grep fail_count`). 로컬 프로세스 변수이므로 운영 전 Prometheus counter로 승격 필요(`architecture.md` 결정 5).
- [ ] Envoy request latency p95 — `kubectl port-forward -n envoy-gateway-system svc/envoy-default-ai-gateway-<hash> 9901:19001` 후 admin의 `stats/prometheus`에서 `envoy_cluster_upstream_rq_time`
- [ ] GatewayConfig reconcile 상태 — `kubectl get gatewayconfig -n default memory-enabled-config -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` → `True`

## 4. Fail mode 동작 확인 (fail-degraded)

### 4.1 기대 동작 요약
| 장애 종류 | ExtProc 동작 | Client 응답 | 사이드 이펙트 |
|-----------|--------------|-------------|----------------|
| Redis GET 실패 | history 없이 빈 배열로 병합, 로그 1건 + `_REDIS_FAIL_COUNTER['get']++` | HTTP 200 + LLM 응답 정상 (단, "새 대화처럼") | 해당 turn은 history 없음 |
| Redis SETEX 실패 | user/assistant 저장 skip, 로그 1건 + `_REDIS_FAIL_COUNTER['set']++` | HTTP 200 + LLM 응답 정상 | 다음 turn에서 이 turn이 누락됨 |
| Redis 복구 이후 | 기존 key가 TTL 살아있으면 이어서 쌓임, TTL 만료됐으면 새 세션으로 동작 | HTTP 200 정상 | — |
| Body JSON parse 실패 | mutation 없이 원본 통과 (fail-open) | HTTP 200 + LLM 응답 정상 (무history) | user 저장도 skip |
| Response JSON parse 실패 | assistant 저장 skip, 로그 1건 | HTTP 200 정상 | 해당 turn assistant 미저장 |

### 4.2 재현 커맨드

- [ ] Redis 종료 — `kubectl scale statefulset -n ai-gateway-system redis-master --replicas=0`
- [ ] 요청이 400/500 없이 통과 — `curl -X POST http://localhost:28080/v1/chat/completions -H "Host: debug.local" -H "Content-Type: application/json" -H "x-session-id: fail-test" -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'` → `200 OK`
- [ ] ExtProc 로그에 `⚠️ redis GET failed (fail-degraded)` + `fail_count_get=` 카운트 증가 확인 — `kubectl logs -n ai-gateway-system -l app=memory-extproc --tail=30 | grep fail`
- [ ] 응답 JSON에 history가 포함되지 않음 (새 대화처럼 동작) — echo-backend 응답 body의 `messages` 길이 = 1
- [ ] Redis 복구 — `kubectl scale statefulset -n ai-gateway-system redis-master --replicas=1` → 다음 요청부터 history 재누적
- [ ] 복구 후 검증 — 동일 `x-session-id`로 요청 시 ExtProc 로그에 `🔁 merged messages count:` 라인이 다시 증가하면 OK

## 4-A. Redis TLS 활성화 점검

- [ ] Redis chart values 확인 — `helm get values redis -n ai-gateway-system | grep tls.enabled`
- [ ] `redis-tls-ca` Secret 생성 — `kubectl create secret generic redis-tls-ca --from-file=ca.crt=./ca.crt -n ai-gateway-system`
- [ ] memory-extproc Pod에 CA mount 존재 — `kubectl exec -n ai-gateway-system deploy/memory-extproc -- ls /etc/redis-tls/ca.crt`
- [ ] hostname 검증 조건 확인 — Redis 인증서 SAN/CN에 `redis-master.ai-gateway-system.svc.cluster.local` 또는 배포 시 사용하는 서비스명이 포함됨
- [ ] TLS 연결 성공 — `kubectl logs -n ai-gateway-system -l app=memory-extproc --tail=50 | grep -i ssl` 에 치명 오류 없음
- [ ] 세션 저장 재검증 — `bash scripts/verify-step4.sh` 실행 후 Redis key 증가 확인
- [ ] `redis-tls-ca` 갱신 시 Secret 재적용 후 `kubectl rollout restart deployment -n ai-gateway-system memory-extproc`

### 4-A.2 Redis TLS Secret 로테이션

- [ ] 신규 CA 배포 — `kubectl apply -f` 또는 `kubectl create secret generic redis-tls-ca ... --dry-run=client -o yaml | kubectl apply -f -`
- [ ] `memory-extproc` rollout restart 수행
- [ ] restart 후 Step 4 재검증
- [ ] 기존 CA 폐기 전 새 CA 기준 연결 성공 로그 확인

### 4-A.3 Redis NetworkPolicy enforcement 검증 결과

- [x] 2026-04-27 검증 결과: Redis ingress allowlist enforcement PASS.
- [x] `memory-extproc` Pod -> Redis TLS 접속 성공.
- [x] 다른 Pod -> Redis 접속은 timeout으로 차단됨.
  - `default` namespace 임의 Pod 차단 확인.
  - `ai-gateway-system` namespace의 `app=memory-extproc` label 없는 임의 Pod 차단 확인.
- [x] NetworkPolicy 적용 상태에서 `GATEWAY_URL=http://localhost:28082 bash scripts/verify-step4.sh` Gate 1-7 PASS.
- [x] 실패 사례 기록:
  - Redis Helm chart의 permissive NetworkPolicy가 함께 있으면 Redis ingress가 열려 enforcement가 실패한다.
  - 이때 `redis-cli` 결과가 `NOAUTH Authentication required.`이면 네트워크 차단 성공이 아니라 Redis까지 연결된 뒤 인증에서 실패한 것이다.
  - 정상 차단 기준은 connection timeout이다.

## 4-B. 외부 OpenRouter 공식 경로 점검

- [ ] `kubectl apply -f aiservice-backend-openrouter-external.yaml`
- [ ] `kubectl apply -f backend-security-policy-openrouter-external.yaml`
- [ ] `kubectl get backend -n default openrouter-api-backend-eg -o yaml`
- [ ] 설치된 Envoy Gateway 버전에서 `BackendTLSPolicy` 대상 종류 지원 범위 확인
- [ ] 지원 확인 후에만 `kubectl apply -f backend-tls-policy-openrouter-external.yaml`
- [ ] CoreDNS / egress 정책에서 `openrouter.ai:443` 및 DNS(53 TCP/UDP) 허용 확인
- [ ] `openrouter-secret` 최신화 후 실제 200 응답 확인
  - `Authorization: Bearer <OPENROUTER_API_KEY>` 형태가 upstream에 전달되는지 확인
- [ ] route 전환용 manifest 적용 — `kubectl apply -f aigateway-route-openrouter-external.yaml`
- [ ] external 검증 — `VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh`
- [ ] mock → external 전환은 Redis TLS / NetworkPolicy / DNS / secret / pre-prod 200이 모두 green일 때만 수행
- [ ] 배포 전환 시 `AIGatewayRoute` backendRef를 `ai-service-openrouter-external`로 바꾸고, xDS 수렴 시간 동안 blue-green 또는 staged rollout 사용

### 4-B.0 2026-04-27 공식 경로 검증 결과

- [x] 실제 생성 HTTPRoute 이름 확인 — `HTTPRoute/ai-route-openai`
- [x] Custom ExtProc attach 확인 — `extproc-policy.yaml` targetRefs에 `HTTPRoute/test-route`, `HTTPRoute/ai-route-openai` 반영, `Accepted=True`
- [x] OpenRouter external 매니페스트 server dry-run PASS
  - `aiservice-backend-openrouter-external.yaml`
  - `backend-security-policy-openrouter-external.yaml`
  - `aigateway-route-openrouter-external.yaml`
  - `backend-tls-policy-openrouter-external.yaml`
- [x] `BackendTLSPolicy/openrouter-backend-tls` 상태 확인 — `Accepted=True`, `ResolvedRefs=True`
- [x] `VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh` PASS
  - Phase2C external OpenRouter: HTTP 200 OK
  - assistant content: non-empty
  - Redis assistant turn 저장 확인
- [x] 첫 실패 원인 분류 — `localhost:28080` port-forward 미기동으로 인한 검증 전제 문제. port-forward 기동 후 재실행 PASS.
- [ ] 남은 리스크
  - Redis TLS 활성화 검증 미완료
  - NetworkPolicy enforcement는 검증 완료. 단, Redis Helm chart의 `networkPolicy.enabled=false` 전제가 깨지면 재검증 필요
  - Phase2A는 `openrouter-proxy` 배포 없음으로 skip
  - Phase2B는 현재 AIGatewayRoute가 external backend를 가리켜 mock 공식 경로 검증 skip

### 4-B.1 외부 의존성 실패 정책

- [ ] `openrouter.ai` timeout, DNS 실패, 5xx는 **fail-closed**로 판단한다.
- [ ] 운영 경로에서 mock backend로 자동 fallback하지 않는다.
- [ ] 장애 시 조치는 route를 명시적으로 이전 mock/proxy 경로로 되돌리는 롤백이다.

### 4-A.1 TLS 실패 정책

- [ ] `REDIS_TLS_ENABLED=true` 상태에서 handshake/CA/hostname 오류가 나면 이를 **배포 실패**로 판단한다.
- [ ] 현재 구현은 TLS 실패 시 자동 plaintext fallback을 하지 않는다.
- [ ] 요청 자체는 fail-degraded로 통과할 수 있으므로, 운영에서는 ExtProc 로그의 Redis 오류를 성공으로 오인하지 않도록 별도 점검한다.

## 5. 세션 격리 재현 테스트

- [ ] 서로 다른 `x-session-id` 두 개로 동시 요청 → Redis key `chat:<sid1>`, `chat:<sid2>` 각각 독립 존재
- [ ] `x-session-id` 헤더 없이 요청 → **400** 반환 (`architecture.md` 결정 1-a 정책)
- [ ] TTL 경과 후 새 요청 → history 초기화됨

## 6. 롤백 절차

> v0.4 스냅샷 위치: Initial commit `61bb03e` (tag `v0.4-snapshot` 예정).

### 6.1 부분 롤백 — GatewayConfig만 제거, 커스텀 ExtProc 유지

배포 후 GatewayConfig 쪽에 문제(webhook rejection, built-in ExtProc 충돌 등)가 생긴 경우.

```bash
# 1. Gateway annotation 제거 — 연결 해제
kubectl annotate gateway -n default ai-gateway \
  aigateway.envoyproxy.io/gateway-config-

# 2. GatewayConfig 삭제
kubectl delete gatewayconfig -n default memory-enabled-config

# 3. Envoy 재기동 (annotation 변경 즉시 반영 안 될 때만)
kubectl rollout restart deployment -n envoy-gateway-system \
  envoy-default-ai-gateway-27dc8f39

# 4. Custom ExtProc 작동 확인 — 메모리 기능은 EnvoyExtensionPolicy로 살아있음
kubectl logs -n ai-gateway-system -l app=memory-extproc --tail=20
```

기대 결과: Custom ExtProc는 영향 없이 계속 작동, built-in ExtProc 로직(토큰 계산 등)만 비활성화.

### 6.2 전체 롤백 — v0.4 스타일 manifest로 회귀

v0.5 도입 자체를 철회하는 경우.

```bash
# 1. v0.5 전용 리소스 제거
kubectl delete gatewayconfig -n default memory-enabled-config --ignore-not-found
kubectl delete aigatewayroute -n default --all --ignore-not-found
kubectl delete aiservicebackend -n default --all --ignore-not-found
kubectl delete backendsecuritypolicy -n default --all --ignore-not-found

# 2. manifest를 v0.4 스냅샷으로 되돌림
git checkout 61bb03e -- memory-extproc.yaml extproc-policy.yaml test-route.yaml

# 3. 재배포
kubectl apply -f memory-extproc.yaml -f extproc-policy.yaml -f test-route.yaml

# 4. Envoy 재기동
kubectl rollout restart deployment -n envoy-gateway-system \
  envoy-default-ai-gateway-27dc8f39

# 5. 스모크 재실행
bash scripts/verify-step4.sh
```

### 6.3 1-command 긴급 롤백 (PR #5 리뷰 반영)

장애 탐지 직후 "더 이상 악화시키지 않는" 한 줄 명령:

```bash
# HTTPRoute 백엔드를 echo-backend(안전한 반사 서버)로 즉시 전환 → ExtProc·Redis 경로는 유지하되
# upstream을 중립화해 사고 원인 격리. Gateway/ExtProc 자체 결함이면 이어 §6.1 부분 롤백 수행.
kubectl patch httproute test-route -n default --type merge -p \
  '{"spec":{"hostnames":["debug.local"],"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}],"backendRefs":[{"name":"echo-backend","port":80}]}]}}'
```

### 6.4 실패 시점별 롤백 기준 (PR #5 리뷰 반영)

| 실패 시점 | 증상 | 롤백 범위 |
|-----------|------|-----------|
| **Deploy** — ExtProc 이미지 롤아웃 실패 | Pod CrashLoopBackOff, readiness 실패 | `kubectl rollout undo deployment -n ai-gateway-system memory-extproc` (마지막 이전 이미지 복귀) |
| **Route** — HTTPRoute/AIGatewayRoute 변경 후 5xx | 특정 경로만 장애, ExtProc Pod는 정상 | §6.3 1-command로 이전 backend(echo 또는 proxy)로 즉시 전환 |
| **Config** — GatewayConfig / EnvoyExtensionPolicy 변경 후 전체 장애 | 모든 요청이 500 또는 timeout | §6.1 부분 롤백 — `kubectl annotate gateway ... -` + `delete gatewayconfig` |
| **Code** — `server.py` 변경 후 assistant 저장 오류 | 응답은 정상, Redis에 쓰레기 데이터 | 이미지 이전 tag로 `rollout undo`, Redis 세션 키 `DEL chat:*` |
| **Data** — Redis 장애 | 응답은 정상(fail-degraded), history 유실 | Redis 복구 후 자동 재누적. 복구 불가 시 `kubectl scale statefulset redis-master --replicas=1` 또는 snapshot restore |

### 6.5 Day 단위 세분 롤백 (이번 PoC 동안)

| 시점 | 머지 커밋 | 롤백 포인트 |
|------|-----------|-------------|
| Initial commit | `61bb03e` | v0.4 스타일 원본 |
| Day 3 refactor | `86ceb08` (PR #2 merge) | server.py 리팩토링만, 매니페스트는 v0.4 원본 |
| Day 3 review 반영 | `7cdaf90` (PR #3 merge) | 방어 코드 + 정책 문서화 포함 |
| Day 4 PM GatewayConfig | `6c01e3c` (PR #4 merge) | v0.5 공식 경로 도입 |

롤백 커맨드: `git revert <merge-commit>` 또는 `git reset --hard <prev-commit>` 후 재배포.

- [ ] 롤백 후 스모크 재실행 — §2의 두 verify 스크립트 green 확인

## 7. 후속 개선 항목 (post-PoC)

`architecture.md` 결정별 "후속 검토"에서 이관한 항목:

- [ ] `_REDIS_FAIL_COUNTER` → Prometheus counter(`ext_proc_redis_fail_total{op}`) 승격 + alert 룰
- [ ] 세션 ID 누락 시 UUID auto-fallback 모드 (결정 1-a)
- [ ] `FAIL_MODE=closed` env 옵션 (결정 5)
- [ ] 파싱 실패 로그 preview PII 마스킹 규칙 (결정 5 후속 검토)
- [ ] 멀티 choice 응답 채택 정책 재평가 (결정 5-a)
- [ ] SSE/streaming 응답 지원 — SSE 청크 파서 + `delta.content` 누적 (결정 4 후속)
