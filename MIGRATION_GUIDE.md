# Envoy AI Gateway v0.4 → v0.5 마이그레이션 가이드
## + LLM 대화 메모리 PoC (통합 아키텍처) 구현

> **작성일:** 2026-04-26  
> **최종 수정:** 2026-04-27 (통합 아키텍처 반영)  
> **검증 환경:** Windows 11 Pro, Docker Desktop (WSL2), Kind v1.32  
> **구현 방식:** 통합 — ExtProc 서버사이드 메모리 + Body Mutation + 토큰 레이트 리밋

---

## 목차

1. [의존성 변경사항](#1-의존성-변경사항)
2. [Breaking Changes 요약](#2-breaking-changes-요약)
3. [환경 구성 단계별 절차](#3-환경-구성-단계별-절차)
4. [실제 겪은 문제와 해결책](#4-실제-겪은-문제와-해결책)
5. [메모리 PoC 아키텍처 및 구현](#5-메모리-poc-아키텍처-및-구현)
6. [동작 검증 결과](#6-동작-검증-결과)
7. [운영 체크리스트](#7-운영-체크리스트)

> **아키텍처 변경 이력**  
> - v1 (2026-04-26): Option B (클라이언트 사이드 메모리 + Body Mutation)  
> - v2 (2026-04-27): 통합 — Option A ExtProc (서버사이드 투명 메모리) + Option B 기능 통합

---

## 1. 의존성 변경사항

### 1.1 컴포넌트 버전

| 컴포넌트 | v0.4 | v0.5 (검증) | 비고 |
|----------|------|-------------|------|
| Kubernetes | v1.30+ | **v1.32.0** | Kind 이미지: `kindest/node:v1.32.0` |
| Envoy Gateway | v1.5.x | **v1.6.2** | Helm OCI chart |
| AI Gateway | v0.4.x | **v0.5.0** | Helm OCI chart (CRDs 별도) |
| Gateway API CRDs | v1.3.x | **v1.4.0** | Envoy Gateway Helm에 포함 |
| kind | — | v0.31.0 | Windows: choco install kind |
| helm | — | v4.1.3 | Windows: choco install kubernetes-helm |

### 1.2 설치 도구 (Windows)

```powershell
# 관리자 PowerShell
choco install kind kubernetes-helm -y
```

---

## 2. Breaking Changes 요약

### 2.1 CRD API 버전 — **가장 중요**

>  **v0.5.0 실제 확인**: 문서에는 `v1beta1`으로 기술되어 있으나,  
> **실제 배포된 Helm 차트의 모든 AI Gateway CRD는 `v1alpha1`입니다.**

```yaml
#  잘못된 표기 (문서 기준)
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute

#  실제 동작하는 표기 (v0.5.0 Helm 기준)
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
```

**영향받는 리소스 전체:**

| 리소스 | 올바른 apiVersion |
|--------|-----------------|
| `AIGatewayRoute` | `aigateway.envoyproxy.io/v1alpha1` |
| `AIServiceBackend` | `aigateway.envoyproxy.io/v1alpha1` |
| `BackendSecurityPolicy` | `aigateway.envoyproxy.io/v1alpha1` |
| `GatewayConfig` | `aigateway.envoyproxy.io/v1alpha1` |
| `MCPRoute` | `aigateway.envoyproxy.io/v1alpha1` |

확인 방법:
```bash
kubectl get crd | grep aigateway
# 각 CRD의 실제 지원 버전 확인
kubectl get crd aigatewayroutes.aigateway.envoyproxy.io \
  -o jsonpath='{.spec.versions[*].name}'
```

### 2.2 CRD 설치 방식 변경 — **신규 필수 단계**

v0.5부터 AI Gateway CRD가 **별도 Helm 차트**로 분리되었습니다.  
메인 차트보다 **반드시 먼저** 설치해야 합니다.

```bash
#  v0.4 방식 (CRD가 메인 차트에 포함)
helm install aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v0.4.x

#  v0.5 방식 (CRD 차트 선설치 필수)
helm install aieg-crds oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v0.5.0 -n envoy-ai-gateway-system --create-namespace

helm install aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v0.5.0 -n envoy-ai-gateway-system
```

> CRD 없이 메인 차트만 설치하면 컨트롤러가 다음 오류와 함께 `CrashLoopBackOff`:
> ```
> failed to apply indexing: unable to retrieve the complete list of server APIs:
> aigateway.envoyproxy.io/v1alpha1: no matches for aigateway.envoyproxy.io/v1alpha1
> ```

### 2.3 GatewayConfig CRD (NEW)

v0.4의 `filterConfig.externalProcessor.resources`가 `GatewayConfig` CRD로 대체됩니다.

```yaml
#  v0.4 방식 (DEPRECATED, v0.6에서 제거 예정)
spec:
  filterConfig:
    externalProcessor:
      resources:
        limits:
          memory: "512Mi"

#  v0.5 방식
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: GatewayConfig
metadata:
  name: my-config
spec:
  extProc:
    kubernetes:
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
```

Gateway에서 어노테이션으로 참조:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    aigateway.envoyproxy.io/gateway-config: my-config  # ← 참조
```

### 2.4 schema.prefix (NEW)

OpenAI 호환 비표준 경로를 가진 백엔드(OpenRouter 등)를 위한 신규 필드.

```yaml
#  v0.4 방식
spec:
  schema:
    name: OpenAI
    version: "api/v1"   # version 필드 오용

#  v0.5 방식
spec:
  schema:
    name: OpenAI
    prefix: "api/v1"    # /api/v1/chat/completions 로 라우팅
```

기본값: `prefix` 미설정 시 `"v1"` → `/v1/chat/completions`

### 2.5 AIServiceBackend에서 제거된 필드

```yaml
#  v1alpha1에서 동작하지 않음 (strict decoding error)
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
spec:
  timeouts:          # ← 제거됨
    request: 120s

#  timeouts는 AIGatewayRoute rule 레벨에서만 지정
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
spec:
  rules:
    - backendRefs:
        - name: my-backend
      timeouts:
        request: 120s  # ← 여기에
```

---

## 3. 환경 구성 단계별 절차

### 전제 조건 확인

```bash
docker ps           # Docker Desktop 실행 확인
kind version        # v0.27+
helm version        # v3.x+
kubectl version     # 클라이언트 v1.30+
ollama list         # (로컬 LLM 사용 시) 모델 확인
```

### Step 1: Kind 클러스터 생성 (K8s 1.32)

```bash
kind create cluster \
  --name ai-gateway-poc \
  --image kindest/node:v1.32.0
```

### Step 2: Redis 배포 — Envoy Gateway보다 먼저

>  **순서 중요**: Envoy Gateway의 rate limit 서비스가 Redis에 의존하므로  
> **반드시 Redis를 먼저** 배포해야 합니다.

```bash
kubectl apply -f k8s/01-redis.yaml
kubectl wait --for=condition=available deployment/redis \
  -n redis-system --timeout=120s
```

### Step 3: Envoy Gateway 설치 (rate limiting 포함)

```bash
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.2 \
  -n envoy-gateway-system --create-namespace \
  --wait --timeout 5m \
  -f manifests/envoy-gateway-values.yaml \
  -f k8s/envoy-gateway-ratelimit-addon.yaml
```

`envoy-gateway-ratelimit-addon.yaml` 핵심 설정:
```yaml
config:
  envoyGateway:
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis.redis-system.svc.cluster.local:6379
```

### Step 4: AI Gateway CRDs 먼저, 이후 컨트롤러

```bash
# 1. CRDs 먼저
helm upgrade -i aieg-crds oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v0.5.0 \
  -n envoy-ai-gateway-system --create-namespace

# 2. 컨트롤러
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v0.5.0 \
  -n envoy-ai-gateway-system \
  --wait --timeout 5m
```

컨트롤러 정상 확인:
```bash
kubectl rollout status deployment/ai-gateway-controller \
  -n envoy-ai-gateway-system
```

### Step 5: 매니페스트 적용 순서

```bash
# 1. Gateway 인프라 (GatewayClass, GatewayConfig, EnvoyProxy, Gateway)
kubectl apply -f k8s/02-gateway.yaml

# 2. 백엔드 (Backend, AIServiceBackend, TLS, Secret, BackendSecurityPolicy)
kubectl apply -f k8s/03-backends.yaml

# 3. 라우팅 + 레이트 리밋 (AIGatewayRoute, BackendTrafficPolicy)
kubectl apply -f k8s/04-routes.yaml

# 4. 부가 서비스
kubectl apply -f k8s/05-memory-service.yaml
```

> 순서를 지키지 않으면 참조 오류가 발생합니다.  
> (예: AIGatewayRoute가 존재하지 않는 Gateway를 참조)

### Step 6: 접근 설정 (Kind 환경)

Kind 클러스터의 Envoy Proxy 서비스는 `envoy-gateway-system` 네임스페이스에 생성됩니다.

```bash
# 서비스 이름 자동 탐색
GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-name=<gateway-name>" \
  -o jsonpath='{.items[0].metadata.name}')

# port-forward
kubectl port-forward -n envoy-gateway-system svc/$GW_SVC 8080:80 &
kubectl port-forward -n default svc/memory-service 8081:8080 &
```

---

## 4. 실제 겪은 문제와 해결책

### 문제 1: AI Gateway CRDs 미설치로 CrashLoopBackOff

**증상**
```
Error: resource Deployment/envoy-ai-gateway-system/ai-gateway-controller not ready.
status: InProgress, Available: 0/1
context deadline exceeded
```

컨트롤러 로그:
```
failed to apply indexing: unable to retrieve the complete list of server APIs:
aigateway.envoyproxy.io/v1alpha1: no matches for aigateway.envoyproxy.io/v1alpha1, Resource=
```

**원인**  
v0.5부터 CRD가 별도 Helm 차트(`ai-gateway-crds-helm`)로 분리됨.  
메인 차트(`ai-gateway-helm`) 단독 설치 시 CRD 없이 컨트롤러만 기동 → 크래시.

**해결**
```bash
helm install aieg-crds oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v0.5.0 -n envoy-ai-gateway-system --create-namespace

# 컨트롤러 재시작
kubectl rollout restart deployment/ai-gateway-controller \
  -n envoy-ai-gateway-system
kubectl rollout status deployment/ai-gateway-controller \
  -n envoy-ai-gateway-system --timeout=120s
```

---

### 문제 2: GatewayConfig apiVersion 불일치

**증상**
```
error: resource mapping not found for name: "memory-poc-config"
namespace: "default" from "k8s/02-gateway.yaml":
no matches for kind "GatewayConfig" in version "aigateway.envoyproxy.io/v1beta1"
ensure CRDs are installed first
```

**원인**  
공식 문서 및 소스 코드는 `v1beta1`을 목표 버전으로 기술하지만,  
v0.5.0 배포된 Helm 차트의 CRD 실제 지원 버전은 `v1alpha1`.

**확인 방법**
```bash
kubectl get crd gatewayconfigs.aigateway.envoyproxy.io \
  -o jsonpath='{.spec.versions[*].name}'
# 출력: v1alpha1
```

**해결**  
모든 AI Gateway 리소스의 `apiVersion`을 `v1alpha1`으로 변경:
```bash
# 일괄 치환
sed -i 's|aigateway.envoyproxy.io/v1beta1|aigateway.envoyproxy.io/v1alpha1|g' \
  k8s/02-gateway.yaml k8s/03-backends.yaml k8s/04-routes.yaml
```

---

### 문제 3: AIServiceBackend의 spec.timeouts 필드 오류

**증상**
```
Error from server (BadRequest): AIServiceBackend in version "v1alpha1" cannot be
handled as a AIServiceBackend:
strict decoding error: unknown field "spec.timeouts"
```

**원인**  
`spec.timeouts`는 `AIServiceBackend`의 v1alpha1 스펙에 없는 필드.  
(v1beta1 초안에서는 존재하나 현재 배포 버전에는 미포함)

**해결**  
`AIServiceBackend`에서 `timeouts` 제거, `AIGatewayRoute` 규칙 레벨로 이동:

```yaml
#  오류
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
spec:
  timeouts:
    request: 120s

#  올바른 위치
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
spec:
  rules:
    - backendRefs:
        - name: my-backend
      timeouts:
        request: 120s
```

---

### 문제 4: Redis 배포 순서 오류

**증상**  
Envoy Gateway rate limit 서비스가 Redis에 연결하지 못해 초기화 실패.

**원인**  
`envoy-gateway-ratelimit-addon.yaml`이 Redis URL을 하드코딩하므로,  
Redis가 준비되기 전에 Envoy Gateway를 설치하면 rate limit 서비스가 계속 재시도.

**해결 — 설치 순서 고정**
```
1. Kind 클러스터 생성
2. Redis 배포 + 준비 대기  ← 반드시 먼저
3. Envoy Gateway 설치
4. AI Gateway CRDs 설치
5. AI Gateway 컨트롤러 설치
6. K8s 매니페스트 적용
```

---

### 문제 5: ExtProc 이미지 빌드 — Envoy proto 컴파일 의존성

**증상**  
팀원 레포의 Dockerfile이 `COPY envoy/api /app/envoy/api`를 하지만, 해당 디렉토리가 `.gitignore`에 포함되어 레포에 없음:
```
error: failed to solve: failed to read dockerfile: ...
COPY failed: file not found in build context: envoy/api
```

**원인**  
Envoy ExtProc gRPC를 Python에서 사용하려면 `external_processor_pb2.py` 등 컴파일된 protobuf 파일이 필요하며, 이는 envoy 소스 레포에서 `grpcio-tools.protoc`로 생성해야 합니다.  
팀원은 빌드 전에 별도로 `git clone envoy` 후 생성하는 로컬 사전 단계가 있었음.

**해결**  
Dockerfile을 멀티스테이지 빌드로 교체 — 빌드 컨텍스트에 대한 사전 단계 불필요:
```dockerfile
FROM python:3.12-slim AS proto-builder
RUN apt-get install -y git && pip install grpcio-tools==1.80.0
# 3개 레포 sparse clone: envoyproxy/envoy, cncf/xds, bufbuild/protoc-gen-validate
RUN git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/envoyproxy/envoy.git /envoy && \
    cd /envoy && git sparse-checkout set api
# ... (xds, pgv 동일)
RUN find /envoy/api /xds/udpa /pgv/validate -name "*.proto" | \
    xargs python -m grpc_tools.protoc \
        -I /envoy/api -I /xds -I /pgv \
        --python_out=/pb --grpc_python_out=/pb

FROM python:3.12-slim
COPY --from=proto-builder /pb/ /app/proto/
ENV PYTHONPATH=/app/proto
```

>  **3개 레포를 클론해야 하는 이유**: `external_processor.proto`의 transitive import가  
> `udpa/annotations/status.proto` (cncf/xds 레포)와 `validate/validate.proto` (bufbuild 레포)를 포함.  
> `grpcio-tools`는 google/protobuf 만 자동 제공, 나머지는 별도 `-I` 경로 지정 필요.

---

### 문제 9: Redis 키 형식 불일치 (Memory Service vs ExtProc)

**증상**  
ExtProc과 Memory Service REST API가 같은 Redis 인스턴스를 쓰지만 키가 달라  
`/history` 슬래시 명령어로 조회 시 ExtProc이 저장한 데이터가 보이지 않음.

| 구현 | 키 형식 |
|------|---------|
| Memory Service (본인) | `memory:session:{session_id}` |
| ExtProc (팀원) | `chat:{session_id}` |

**해결**  
`extproc/server.py`의 키 형식을 Memory Service와 통일:
```python
# 변경 전 (팀원 코드)
r.get(f"chat:{session_id}")
r.setex(f"chat:{session_id}", ...)

# 변경 후 (통합)
REDIS_KEY_PREFIX = "memory:session"
r.get(f"{REDIS_KEY_PREFIX}:{session_id}")
r.setex(f"{REDIS_KEY_PREFIX}:{session_id}", ...)
```

단위 테스트(`tests/unit/test_processor.py`)도 함께 업데이트:
```python
# 변경 전
assert captured["key"] == "chat:sid"

# 변경 후
assert captured["key"] == "memory:session:sid"
```

---

### 문제 10: ExtProc 네임스페이스 불일치

**증상**  
팀원 레포의 `memory-extproc.yaml`은 `namespace: ai-gateway-system`을 사용하지만,  
이 레포의 Redis는 `redis-system`, 애플리케이션 서비스는 `default`를 사용함.  
그대로 적용하면 Redis 연결 실패 + 크로스 네임스페이스 ReferenceGrant 추가 필요.

**해결**  
ExtProc 배포를 `default` 네임스페이스로 통일, Redis 주소 수정:
```yaml
# k8s/06-extproc.yaml
metadata:
  namespace: default        # ai-gateway-system → default
spec:
  containers:
    env:
      - name: REDIS_HOST
        value: redis.redis-system.svc.cluster.local  # 이 레포 Redis 위치
```

`EnvoyExtensionPolicy`도 동일 네임스페이스 → ReferenceGrant 불필요:
```yaml
# k8s/07-extproc-policy.yaml
metadata:
  namespace: default
spec:
  extProc:
    - backendRefs:
        - name: memory-extproc
          namespace: default   # 동일 네임스페이스
```

---

## 5. 메모리 PoC 아키텍처 및 구현

### 5.1 최종 통합 아키텍처

두 구현 방식(Option A, Option B)을 통합하여 각각의 강점을 결합했습니다.

| 구성 요소 | 출처 | 역할 |
|-----------|------|------|
| **ExtProc (server.py)** | Option A (팀원) | 게이트웨이 내 서버사이드 메모리: Redis 히스토리 조회·병합·저장 |
| **BodyMutation** | Option B (본인) | 백엔드별 파라미터 강제: `stream=false`, `max_tokens`, 모델명 정규화 |
| **토큰 레이트 리밋** | Option B (본인) | `x-tenant-id` 기준 입력/출력 토큰 버짓 |
| **Memory Service REST API** | Option B (본인) | 세션 관리 전용: `/clear`, `/history`, `/system` 슬래시 명령어 지원 |

**통합 요청 흐름:**
```
클라이언트 (x-session-id 헤더만, 현재 메시지만 전송)
  ↓
Envoy AI Gateway
  ↓ [1. ExtProc gRPC]
     memory-extproc: Redis에서 history 조회 → current_msg와 병합
                     → CONTINUE_AND_REPLACE (전체 messages 교체)
  ↓ [2. AI Gateway BodyMutation]
     stream=false, max_tokens 강제, ollama/ prefix 제거
  ↓ [3. 토큰 레이트 리밋 체크]
  ↓
LLM Backend (OpenRouter / Ollama)
  ↓
Envoy AI Gateway
  ↓ [4. ExtProc response_body]
     assistant content 추출 → Redis 저장
  ↓
클라이언트 (응답 수신)
```

**v1 (Option B) vs 통합 v2 비교:**

| 항목 | v1 (Option B만) | v2 (통합) |
|------|----------------|-----------|
| 히스토리 조회 | 클라이언트가 매 요청 전 Memory Service 호출 | ExtProc이 Gateway 내부에서 자동 처리 |
| messages 구성 | 클라이언트가 history + new_msg 직접 조립 | ExtProc이 서버사이드 병합 |
| 응답 저장 | 클라이언트가 응답 후 Memory Service 호출 | ExtProc이 response_body에서 자동 저장 |
| 클라이언트 복잡도 | 높음 (Memory Service 직접 관리) | 낮음 (헤더 1개만 추가) |

### 5.2 ExtProc 구현 상세 (extproc/server.py)

```python
# Redis 키 형식: Memory Service REST API와 동일하게 유지 (상호운용)
REDIS_KEY_PREFIX = "memory:session"

# 요청 처리 단계
# 1. request_headers: x-session-id 추출, Content-Length 제거
# 2. request_body:
#      history = redis.get(f"memory:session:{session_id}")
#      merged = truncate(history + current_messages)
#      → CONTINUE_AND_REPLACE: {**payload, "messages": merged}
#      user 메시지를 Redis에 선저장
# 3. response_body:
#      end_of_stream 시 choices[0].message.content 추출
#      → assistant 메시지 Redis 추가 저장
```

**장애 처리 정책:**

| 상황 | 처리 방식 | 결과 |
|------|-----------|------|
| Redis 연결 실패 | fail-degraded | 히스토리 없이 계속 진행 (요청 차단 안 함) |
| JSON 파싱 실패 | fail-open | 원본 body 그대로 전달 |
| SSE 스트리밍 응답 | skip | assistant 저장 건너뜀 (PoC 한계) |
| x-session-id 헤더 누락 | fail-closed | 400 즉시 반환 |

**Dockerfile — 자체 완결 멀티스테이지 빌드:**
```dockerfile
# Stage 1: proto 컴파일 (git clone → grpcio-tools protoc)
FROM python:3.12-slim AS proto-builder
# envoy/api + cncf/xds(udpa) + bufbuild/pgv(validate) 클론
# find ... | xargs python -m grpc_tools.protoc ...

# Stage 2: 런타임
FROM python:3.12-slim
COPY --from=proto-builder /pb/ /app/proto/
ENV PYTHONPATH=/app/proto
```

>  최초 빌드 시 proto 소스 클론 + 컴파일로 수분 소요.  
> Docker 레이어 캐시 이후 재빌드는 빠름.

### 5.3 K8s 리소스 구성

```
k8s/
├── 02-gateway.yaml         GatewayConfig + Gateway (v0.5 NEW)
├── 03-backends.yaml        AIServiceBackend + BodyMutation (OpenRouter/Ollama)
├── 04-routes.yaml          AIGatewayRoute + BackendTrafficPolicy (토큰 레이트 리밋)
├── 05-memory-service.yaml  Memory Service REST API (관리 명령어 전용)
├── 06-extproc.yaml         Memory ExtProc Deployment + Service (gRPC :50051)
└── 07-extproc-policy.yaml  EnvoyExtensionPolicy → Gateway 바인딩
```

**EnvoyExtensionPolicy 핵심 설정:**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: memory-extproc-policy
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-memory-poc       # 전체 트래픽에 적용
  extProc:
    - backendRefs:
        - name: memory-extproc
          namespace: default
          port: 50051
      processingMode:
        request:
          body: Buffered         # 전체 body 메모리에 적재 후 처리
        response:
          body: Streamed         # 청크 단위 수신, end_of_stream 시 저장
```

> **Gateway 타겟의 의미:** `kind: Gateway`를 타겟으로 설정하면  
> Gateway를 통과하는 모든 트래픽(AIGatewayRoute 포함)에 ExtProc이 적용됩니다.

### 5.4 v0.5 신규 기능 활용 지점

**GatewayConfig (NEW)**
```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: GatewayConfig
metadata:
  name: memory-poc-config
spec:
  extProc:
    kubernetes:
      resources:
        requests: { cpu: "50m", memory: "64Mi" }
        limits:   { cpu: "200m", memory: "256Mi" }
```

**schema.prefix (NEW) — OpenRouter 비표준 경로 처리**
```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
metadata:
  name: openrouter
spec:
  schema:
    name: OpenAI
    prefix: "api/v1"   # /api/v1/chat/completions 로 라우팅
```

**bodyMutation — 백엔드별 파라미터 강제 적용**
```yaml
# OpenRouter: 비용 제어
bodyMutation:
  set:
    - path: "stream"
      value: "false"
    - path: "max_tokens"
      value: "2048"

# Ollama: 모델명 정규화 + 제한
bodyMutation:
  set:
    - path: "model"
      value: '"llama3.2"'   # "ollama/" 접두사 제거
    - path: "stream"
      value: "false"
    - path: "max_tokens"
      value: "1024"
```

**token_ratelimit 통합 — x-tenant-id 기준 버짓**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
spec:
  rateLimit:
    type: Global
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: x-tenant-id
                  type: Distinct
          limit:
            requests: 50000   # 입력 토큰/시간
            unit: Hour
          cost:
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_input_token
```

**RegularExpression 헤더 매칭 — 백엔드 분기**
```yaml
rules:
  # Ollama 로컬 백엔드
  - matches:
      - headers:
          - type: RegularExpression
            name: x-ai-eg-model
            value: "ollama/.*"
    backendRefs:
      - name: ollama

  # OpenRouter (기본)
  - matches:
      - headers:
          - type: RegularExpression
            name: x-ai-eg-model
            value: ".*"
    backendRefs:
      - name: openrouter
```

### 5.5 Memory Service REST API (관리 전용, Python FastAPI)

```
GET    /sessions/{id}            → 전체 히스토리 반환
POST   /sessions/{id}/messages   → 메시지 추가 (MAX_HISTORY 초과 시 앞부터 제거)
DELETE /sessions/{id}            → 세션 삭제
POST   /sessions/{id}/reset      → 시스템 프롬프트로 초기화
GET    /sessions/{id}/ttl        → 남은 TTL 확인
GET    /health                   → Redis 연결 상태
```

환경 변수:

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `REDIS_URL` | `redis://localhost:6379` | Redis 접속 주소 |
| `MAX_HISTORY_LENGTH` | `20` | 세션당 최대 메시지 수 |
| `SESSION_TTL_SECONDS` | `3600` | 세션 만료 시간 (초) |

---

## 6. 동작 검증 결과

### 6.1 헬스체크

```bash
curl http://localhost:8081/health
# {"status":"ok","redis":"connected"}
```

### 6.2 OpenRouter 백엔드 (google/gemma-3-4b-it:free)

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "x-ai-eg-model: google/gemma-3-4b-it:free" \
  -H "x-tenant-id: test" \
  -d '{"model":"google/gemma-3-4b-it:free","messages":[{"role":"user","content":"Say hello."}]}'
# → {"choices":[{"message":{"content":"Hello there! 😊"}}], "usage":{...}}
```

### 6.3 Ollama 백엔드 (llama3.2)

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "x-ai-eg-model: ollama/llama3.2" \
  -H "x-tenant-id: test" \
  -d '{"model":"ollama/llama3.2","messages":[{"role":"user","content":"Hi."}]}'
# → {"model":"llama3.2","choices":[{"message":{"content":"Hello!"}}]}
#   BodyMutation이 "ollama/" 접두사를 제거하여 llama3.2로 전달됨
```

### 6.4 메모리 연속 대화 검증 (통합 아키텍처)

통합 후 클라이언트는 현재 메시지만 전송, ExtProc이 서버사이드에서 자동 병합:

```
Turn 1  클라이언트 전송: messages=[{user: "My name is Hong Gildong."}]
        ExtProc: Redis 조회 → 빈 히스토리 → merged=1개 → LLM 전달
        LLM 응답: "Okay, Hong Gildong. I've got it!"
        ExtProc: Redis에 user+assistant 저장 (총 2개)

Turn 2  클라이언트 전송: messages=[{user: "What did I tell you my name was?"}]
        ExtProc: Redis 조회 → 2개 히스토리 → merged=3개 → LLM 전달
        LLM 응답: "You told me your name was Hong Gildong."   기억 성공
        ExtProc: Redis에 추가 저장 (총 4개)

Redis 최종: 4개 메시지 (key: memory:session:{session_id})
```

**v1 대비 클라이언트 변화:**
```python
# v1 (Option B): 클라이언트가 매 요청 전 히스토리 조회 + 병합
history = fetch_history(session_id)          # Memory Service 호출
messages = history + [{"role": "user", ...}] # 직접 조립
# 응답 후
save_message(session_id, "user", ...)        # Memory Service 저장
save_message(session_id, "assistant", ...)   # Memory Service 저장

# v2 (통합): 헤더 추가만 하면 됨
headers["x-session-id"] = session_id        # ExtProc이 나머지 전담
messages = [{"role": "user", "content": user_input}]  # 현재 메시지만
```

### 6.5 최종 클러스터 상태 (통합 후)

```
NAMESPACE               POD                                        STATUS
default                 memory-extproc-xxx                         Running  ← NEW
default                 memory-service-xxx                         Running
envoy-ai-gateway-system ai-gateway-controller-xxx                  Running
envoy-gateway-system    envoy-default-ai-memory-poc-xxx            Running  (3/3)
envoy-gateway-system    envoy-gateway-xxx                          Running
envoy-gateway-system    envoy-ratelimit-xxx                        Running
redis-system            redis-xxx                                  Running
```

---

## 7. 운영 체크리스트

### 프로덕션 전환 전 확인 사항

**v0.5 마이그레이션 공통**
- [ ] CRD 설치 (`ai-gateway-crds-helm`) 배포 파이프라인에 포함 여부 확인
- [ ] 모든 AI Gateway 리소스 `apiVersion`이 `v1alpha1`인지 검증
- [ ] Redis 배포가 Envoy Gateway 설치보다 먼저 실행되는 순서 보장
- [ ] `AIServiceBackend`에 `spec.timeouts` 필드가 없는지 확인
- [ ] `bodyMutation.set` 값 중 JSON 타입 문자열이 올바른지 확인
  - `"false"` (boolean) vs `'"false"'` (string)
  - `"1024"` (number) vs `'"1024"'` (string)

**ExtProc (통합 아키텍처 추가)**
- [ ] `memory-extproc` 이미지 빌드 — 최초 빌드 시 proto 컴파일로 수분 소요 (CI 타임아웃 여유분 확인)
- [ ] `EnvoyExtensionPolicy` 타겟이 올바른 Gateway 이름을 가리키는지 확인
- [ ] ExtProc 장애 시 fail-degraded 동작 검증: `memory-extproc` Pod 강제 종료 후 요청 통과 확인
- [ ] SSE(`stream: true`) 응답이 필요한 경우 ExtProc 스트리밍 지원 구현 검토 (현재 PoC 한계)
- [ ] `x-session-id` 헤더 누락 시 400 반환 — 클라이언트에 문서화 또는 헤더 자동 생성 정책 결정
- [ ] Redis 키 형식 (`memory:session:{id}`) 변경 시 Memory Service와 동시 업데이트 필요
- [ ] ExtProc replicas 스케일아웃 시 Redis 공유 세션 일관성 확인 (현재 stateless, 문제없음)

**레이트 리밋 + 보안**
- [ ] `x-tenant-id` 헤더 없는 요청에 대한 rate limit 정책 결정
- [ ] Memory Service의 `SESSION_TTL_SECONDS` 값이 서비스 SLA에 맞는지 검토
- [ ] OpenRouter 무료 모델 대신 유료 모델 또는 fallback 구성 검토
- [ ] Kind → 실제 K8s 전환 시 Envoy 서비스 타입 `LoadBalancer` 확인
- [ ] `BackendTLSPolicy` v1alpha3 deprecation 경고 → v1으로 업그레이드 예정 확인
- [ ] Redis TLS 활성화 (`REDIS_TLS_ENABLED=true`, `redis-tls-ca` Secret 마운트)

### 후속 과제

| 과제 | 우선순위 | 내용 |
|------|----------|------|
| SSE 스트리밍 지원 | High | ExtProc response_body에서 SSE 파싱 → assistant 청크 누적 저장 |
| 단위 테스트 확대 | Medium | ExtProc gRPC iterator 통합 테스트 (현재 verify-*.sh에 의존) |
| Long-term Memory | Medium | 세션 간 지속 저장, 사용자별 요약 |
| Semantic Memory | Low | Redis Vector Search 연동 |
| 성능 벤치마크 | Medium | ExtProc 레이턴시, 메모리 조회 오버헤드, 동시 요청 처리량 |
| 프로덕션 배포 가이드 | High | EKS/GKE 환경 전환, TLS 설정, ExtProc HPA |
| BackendTLSPolicy v1 마이그레이션 | Low | v1alpha3 → v1 업그레이드 |

---

*이 가이드는 실제 구현 과정에서 발생한 문제와 해결책을 기반으로 작성되었습니다.*  
*v1 (2026-04-26): Option B 단독 구현 | v2 (2026-04-27): Option A+B 통합*  
*참조 레포지토리: [envoyproxy/ai-gateway](https://github.com/envoyproxy/ai-gateway)*
