# Envoy AI Gateway v0.4 → v0.5 마이그레이션 가이드

> 산출물 ① (킥오프 §2.2). Day 3 오전 뼈대 → Day 4 오후 yaml diff 채움 → Day 8 polish.

## 1. 전제 — 의존성 버전 요구사항

킥오프 문서 §3.4 참고. v0.5 도입 전 다음 조건이 충족되어야 함.

| 컴포넌트 | v0.4 | v0.5 | 검증 커맨드 |
|----------|------|------|-------------|
| Kubernetes | v1.30+ | **v1.32+** | `kubectl version` |
| Envoy Gateway | v1.5.x | **v1.6.x** | `kubectl get deploy -n envoy-gateway-system envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| Envoy Proxy | v1.34.x | **v1.36.4** | `kubectl get deploy -n envoy-gateway-system <envoy-proxy-deploy> -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| Gateway API | v1.3.x | **v1.4.0** | `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'` |

**본 프로젝트 환경 (2026-04-23 점검 결과):**
- K8s v1.32.0 ✓
- Envoy Gateway v1.6 계열 ✓ (kind cluster `ai-gateway-poc`)
- AI Gateway v0.5 CRD 설치됨 — `gatewayconfigs`, `aigatewayroutes`, `aiservicebackends`, `backendsecuritypolicies`, `mcproutes` ✓

## 2. Breaking Change 1 — ExtProc resources 설정 위치 변경

### AS-IS (v0.4)
```yaml
# ❌ DEPRECATED — v0.6에서 제거됨
spec:
  filterConfig:
    externalProcessor:
      resources:
        limits:
          memory: "512Mi"
          cpu: "500m"
```

### TO-BE (v0.5)
```yaml
# ✅ NEW — GatewayConfig CRD 사용
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: GatewayConfig
metadata:
  name: memory-enabled-config
  namespace: default
spec:
  extProc:
    kubernetes:
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
```

Gateway에 연결:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-gateway
  annotations:
    aigateway.envoyproxy.io/gateway-config: memory-enabled-config
```

### diff 요약
- 위치: `Gateway.spec.filterConfig.externalProcessor.resources` → `GatewayConfig.spec.extProc.kubernetes.resources`
- 주입 방식: Gateway에 직접 → GatewayConfig CRD + Gateway annotation
- 본 프로젝트 기준: GatewayConfig는 AI Gateway built-in ExtProc의 resources만 관리한다. Redis env는 Custom ExtProc인 `memory-extproc` Deployment가 소유한다.

## 3. Breaking Change 2 — schema 필드 rename

### AS-IS (v0.4)
```yaml
# ❌ DEPRECATED
schema:
  version: "/v1beta/openai"
```

### TO-BE (v0.5)
```yaml
# ✅ NEW
schema:
  prefix: "/v1beta/openai"
```

### diff 요약
- 필드명 `version` → `prefix` 일괄 변경.
- 의미 변경 없음 (HTTP path prefix로 공급자 엔드포인트 매핑).
- 현재 저장소 기준 기본 PoC 경로는 `AIServiceBackend(ai-service-openai-via-mock)`에서 `schema.name: OpenAI`만 사용한다.
- `schema.prefix`는 외부 OpenRouter 전환용 `aiservice-backend-openrouter-external.yaml`에서 `prefix: /api/v1`로만 사용한다.

## 4. 본 프로젝트에서의 실제 전환 과정

### 4.0 구조 이해 — GatewayConfig와 Custom ExtProc의 역할 분리

v0.5에서 **두 종류의 ExtProc**가 공존함을 먼저 짚어둘 필요가 있다.

| 구분 | 구성 방식 | 본 프로젝트 대상 파일 |
|------|-----------|----------------------|
| AI Gateway **Built-in ExtProc** (토큰 계산·provider 라우팅 등 AI Gateway 내부 로직) | `GatewayConfig.spec.extProc.kubernetes`가 resources/env/image를 선언. Gateway annotation(`aigateway.envoyproxy.io/gateway-config`)으로 연결되면 AI Gateway controller가 생성·주입 | `gatewayconfig.yaml` (신규) |
| **Custom ExtProc** (우리 메모리 로직) | `Deployment` + `Service` + `EnvoyExtensionPolicy`. AI Gateway controller 소관 밖 | `memory-extproc.yaml`, `extproc-policy.yaml` (유지) |

즉 **Custom ExtProc의 env는 계속 Deployment spec이 소유**하고, `GatewayConfig`는 AI Gateway 자체 ExtProc의 env/resources만 담당한다. Breaking Change의 실제 전환점은 "AI Gateway의 ExtProc 구성 위치 변경"이지, 커스텀 ExtProc까지 GatewayConfig로 이관하는 것이 아니다.

### 4.1 `gatewayconfig.yaml` 신규 도입 (Breaking Change 1 대응)

v0.4 스타일(Gateway `filterConfig.externalProcessor.resources`)은 레포에 없었지만, v0.5의 정식 경로로 `gatewayconfig.yaml`을 신규 추가했다.

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1   # v1beta1 아님 (설치된 CRD 버전)
kind: GatewayConfig
metadata:
  name: memory-enabled-config
  namespace: default
spec:
  extProc:
    kubernetes:
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "512Mi" }
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-gateway
  namespace: default
  annotations:
    aigateway.envoyproxy.io/gateway-config: memory-enabled-config
# ...
```

**주의:** 킥오프 문서(§3.3)는 `v1beta1`으로 표기되어 있으나 실제 설치 환경은 `v1alpha1`. manifest는 `v1alpha1`로 작성. 버전이 올라가면 일괄 `sed`로 교체 가능.

### 4.2 `memory-extproc.yaml` 변화 — Custom ExtProc env 유지

4.0에서 정리한 구조적 사실에 따라 Deployment는 계속 Custom ExtProc의 env를 소유한다. `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `MEMORY_TTL_SECONDS`, `MAX_HISTORY_LENGTH`는 물론, Redis TLS 전환용 `REDIS_TLS_ENABLED`, `REDIS_TLS_CA_CERT_PATH`, `REDIS_TLS_CHECK_HOSTNAME`도 `memory-extproc.yaml`에 남긴다. 잘못 GatewayConfig로 이관하면 커스텀 ExtProc Pod가 필요한 설정을 받지 못하고, built-in extproc가 불필요한 Redis Secret을 요구하게 된다.

실클러스터 점검 결과도 이 전제를 뒷받침했다. `GatewayConfig.spec.extProc.kubernetes.env`에 Redis Secret을 넣으면 Envoy data plane Pod(`envoy-gateway-system`)의 `ai-gateway-extproc` 컨테이너가 해당 Secret을 찾지 못해 `CreateContainerConfigError`가 발생했다. 따라서 현재 저장소 기준으로 GatewayConfig는 **resources만 관리**하고, Redis 관련 env는 `memory-extproc.yaml`에만 둔다.

### 4.3 `extproc-policy.yaml` 변화 — SSE 감지 활성화 시도·롤백

- **시도:** `processingMode.response.headers: Send`를 추가해 SSE content-type 감지를 서버 측에서 사용하려 했다.
- **결과:** `kubectl apply` 시 `strict decoding error: unknown field "spec.extProc[0].processingMode.response.headers"`. Envoy Gateway v1.6의 `EnvoyExtensionPolicy` CRD가 해당 필드를 **노출하지 않음** (`kubectl explain envoyextensionpolicy.spec.extProc.processingMode` 확인).
- **대응:** `response.headers: Send`는 제거. 대신 ExtProc `server.py`의 `response_body` 첫 chunk prefix(`data:` / `event:` / `id:`) 기반 **body-level SSE 감지**로 전환. `docs/architecture.md` 결정 4 참조.

diff:
```yaml
   processingMode:
     request:
       body: Buffered
     response:
+      # body-level SSE 감지로 대체. EnvoyExtensionPolicy CRD는 response.headers 필드 미노출.
       body: Streamed
```

### 4.4 디버그 경로와 AIGatewayRoute 공식 경로 병행

초기 PoC는 `test-route`와 `AIGatewayRoute`가 모두 `/`를 잡아 충돌 위험이 있었다. 현재 저장소는 두 경로를 다음처럼 분리한다.

| 경로 | 용도 | 설정 |
|------|------|------|
| `test-route` | Step 4 / Mock / OpenRouter proxy 디버그 경로 | `hostnames: [debug.local]` |
| `ai-route-openai` | 기본 호스트의 공식 v0.5 경로 | `AIGatewayRoute` + `AIServiceBackend` |

또한 `extproc-policy.yaml`의 `targetRefs`에 `HTTPRoute/test-route`와 `HTTPRoute/ai-route-openai`를 모두 선언해, **Custom ExtProc가 디버그 경로와 공식 경로 양쪽에 동일하게 적용**되도록 했다. 이 구성이 Goal 2(메모리 구현)와 Goal 3(v0.5 기능 활용)를 같은 저장소 안에서 동시에 충족시키는 실제 전환점이다.

## 5. 호환성 노트

- v0.4 스타일은 v0.5에서 **deprecated 경고**로 통과할 수 있으나, v0.6에서 완전 제거 예정.
- 전환 즉시 이득: GatewayConfig로 AI Gateway built-in ExtProc resources를 선언적으로 관리.
- 다운타임: Gateway annotation 추가 시 envoy-proxy pod recreate. 10-30초 드롭 예상.

### 5.1 CRD 버전 차이와 upgrade 리스크 (PR #4 리뷰 반영)

킥오프 문서와 실제 설치 환경 간 **GatewayConfig CRD 버전이 다르다**. 이 차이는 manifest 호환성에 직접 영향을 주므로 명시해둔다.

| 소스 | 표기 버전 | 실제 상태 |
|------|-----------|-----------|
| 킥오프 §7.2 예제 | `aigateway.envoyproxy.io/v1beta1` | 문서용 가이드. 실제 설치와 불일치 |
| 본 프로젝트 `gatewayconfig.yaml` | `aigateway.envoyproxy.io/v1alpha1` | **실측 CRD 버전** (`kubectl get crd gatewayconfigs.aigateway.envoyproxy.io -o jsonpath='{.spec.versions[*].name}'` 결과 `v1alpha1`) |

#### Upgrade 리스크

1. **필드 호환성** — `v1alpha1` → `v1beta1` 전환 시 스키마가 완전 호환되지 않을 수 있다. 알파 버전은 semver 보장 없음.
2. **Storage version 전환** — CRD의 `served`/`storage` 버전이 바뀌면 기존 object를 새 version으로 migrate해야 할 수 있다. `kubectl convert` 또는 수동 re-apply.
3. **다른 CRD와의 연계** — `AIGatewayRoute`, `AIServiceBackend`, `BackendSecurityPolicy`도 동일한 group. 버전 일괄 승격 여부 확인.
4. **AI Gateway controller 버전 종속** — Helm chart 버전(`v0.5.x`)과 CRD 버전은 릴리스 노트로 매칭 확인 필수. 미스매치 시 webhook rejection 또는 silent drop.

#### Upgrade 절차 (권장)
1. 프리체크: `kubectl get crd gatewayconfigs.aigateway.envoyproxy.io -o yaml`로 `served`/`storage` 매핑과 `conversion` 설정 확인.
2. dry-run apply: `kubectl apply --dry-run=server -f gatewayconfig.yaml`로 새 버전 manifest 검증.
3. 백업: 현재 `gatewayconfig.yaml`을 `gatewayconfig-v1alpha1.bak.yaml`로 저장.
4. manifest `apiVersion` 일괄 변경(`sed -i 's|v1alpha1|v1beta1|g' gatewayconfig.yaml`).
5. rolling apply + `kubectl describe gatewayconfig`에서 `Accepted=True` 재확인.

### 5.2 운영 전환 시 Redis 보안 가정 재평가

`architecture.md` 결정 5 "Redis 보안/네트워크 가정" 섹션 참고. migration 시점에 TLS / NetworkPolicy / Pod-to-Pod mTLS 3개 중 적어도 하나는 적용 결정을 내려야 한다.

## 6. 롤백 절차

1. v0.4 스타일 manifest 백업 위치: `git tag v0.4-snapshot` (본 프로젝트에서는 Initial commit `61bb03e`가 v0.4 스타일).
2. 롤백 순서:
   - `kubectl delete gatewayconfig memory-enabled-config`
   - `git checkout 61bb03e -- memory-extproc.yaml extproc-policy.yaml`
   - `kubectl apply -f memory-extproc.yaml -f extproc-policy.yaml`

## 7. 참고 문서

- [Envoy AI Gateway v0.5 Release Notes](https://aigateway.envoyproxy.io/release-notes/v0.5/)
- [GatewayConfig 문서](https://aigateway.envoyproxy.io/docs/0.5/capabilities/gateway-config/)
- [Body Mutation 문서](https://aigateway.envoyproxy.io/docs/capabilities/traffic/header-body-mutations/)
- 본 프로젝트 `docs/architecture.md`
