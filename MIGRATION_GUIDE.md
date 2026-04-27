# Envoy AI Gateway v0.4 → v0.5 마이그레이션 가이드
## + LLM 대화 메모리 PoC (Option B) 구현

> **작성일:** 2026-04-26  
> **검증 환경:** Windows 11 Pro, Docker Desktop (WSL2), Kind v1.32  
> **구현 방식:** Option B — Body Mutation + External Memory Service

---

## 목차

1. [의존성 변경사항](#1-의존성-변경사항)
2. [Breaking Changes 요약](#2-breaking-changes-요약)
3. [환경 구성 단계별 절차](#3-환경-구성-단계별-절차)
4. [실제 겪은 문제와 해결책](#4-실제-겪은-문제와-해결책)
5. [메모리 PoC 아키텍처 및 구현](#5-메모리-poc-아키텍처-및-구현)
6. [동작 검증 결과](#6-동작-검증-결과)
7. [운영 체크리스트](#7-운영-체크리스트)

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

> ⚠️ **v0.5.0 실제 확인**: 문서에는 `v1beta1`으로 기술되어 있으나,  
> **실제 배포된 Helm 차트의 모든 AI Gateway CRD는 `v1alpha1`입니다.**

```yaml
# ❌ 잘못된 표기 (문서 기준)
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute

# ✅ 실제 동작하는 표기 (v0.5.0 Helm 기준)
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
# ❌ v0.4 방식 (CRD가 메인 차트에 포함)
helm install aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v0.4.x

# ✅ v0.5 방식 (CRD 차트 선설치 필수)
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
# ❌ v0.4 방식 (DEPRECATED, v0.6에서 제거 예정)
spec:
  filterConfig:
    externalProcessor:
      resources:
        limits:
          memory: "512Mi"

# ✅ v0.5 방식
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
# ❌ v0.4 방식
spec:
  schema:
    name: OpenAI
    version: "api/v1"   # version 필드 오용

# ✅ v0.5 방식
spec:
  schema:
    name: OpenAI
    prefix: "api/v1"    # /api/v1/chat/completions 로 라우팅
```

기본값: `prefix` 미설정 시 `"v1"` → `/v1/chat/completions`

### 2.5 AIServiceBackend에서 제거된 필드

```yaml
# ❌ v1alpha1에서 동작하지 않음 (strict decoding error)
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
spec:
  timeouts:          # ← 제거됨
    request: 120s

# ✅ timeouts는 AIGatewayRoute rule 레벨에서만 지정
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

> ⚠️ **순서 중요**: Envoy Gateway의 rate limit 서비스가 Redis에 의존하므로  
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

### 문제 1: Docker Desktop WSL2 통합 오류

**증상**
```
WSL integration with distro 'Ubuntu' unexpectedly stopped.
execvpe(/mnt/wsl/docker-desktop/docker-desktop-user-distro) failed: Permission denied
```

**원인**  
WSL2 업데이트 또는 재시작 후 Docker Desktop의 WSL 마운트 권한이 초기화되는 버그.

**해결**
```powershell
# 관리자 PowerShell
wsl --shutdown
# 이후 Docker Desktop 트레이 우클릭 → Restart Docker Desktop
```

**예방**  
Docker Desktop 재시작 순서: 반드시 WSL 종료(`wsl --shutdown`) → Docker Desktop 시작.

---

### 문제 2: Git Bash에서 Docker 파이프 연결 실패

**증상**
```
failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine
```

**원인**  
Docker Desktop이 `desktop-linux` 컨텍스트(WSL2 백엔드)를 기본으로 사용할 때,  
Git Bash(MinGW)에서 Windows 명명 파이프 경로 해석이 PowerShell과 다름.

**해결**  
PowerShell에서 docker 명령 실행하거나, WSL 재시작 후 컨텍스트 재설정:
```bash
docker context use desktop-linux
# 또는 PowerShell에서 실행
powershell.exe -Command "docker ps"
```

---

### 문제 3: AI Gateway CRDs 미설치로 CrashLoopBackOff

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

### 문제 4: GatewayConfig apiVersion 불일치

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

### 문제 5: AIServiceBackend의 spec.timeouts 필드 오류

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
# ❌ 오류
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
spec:
  timeouts:
    request: 120s

# ✅ 올바른 위치
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

### 문제 6: OpenRouter 무료 모델 404 오류

**증상**
```json
{"error": {"message": "No endpoints found for meta-llama/llama-3.3-8b-instruct:free.", "code": 404}}
```

**원인**  
계획한 모델(`meta-llama/llama-3.3-8b-instruct:free`)이 OpenRouter에서 제공 종료됨.

**해결**  
사용 가능한 무료 모델로 교체. 검증된 모델:

| 모델 | 상태 | 비고 |
|------|------|------|
| `google/gemma-3-4b-it:free` | ✅ 동작 | 권장 |
| `meta-llama/llama-3.2-3b-instruct:free` | ⚠️ Rate limit | 업스트림 제한 |
| `meta-llama/llama-3.3-8b-instruct:free` | ❌ 404 | 서비스 종료 |

> **교훈**: 무료 모델은 가용성이 수시로 변경됩니다.  
> 프로덕션에서는 특정 모델에 의존하지 말고 fallback 구성(`provider_fallback` 예제 참고)을 권장.

---

### 문제 7: Redis 배포 순서 오류

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

## 5. 메모리 PoC 아키텍처 및 구현

### 5.1 선택 방식: Option B

클라이언트 사이드 메모리 관리 방식을 선택했습니다.

**선택 이유:**
- ExtProc(gRPC) 개발 없이 Python REST API로 구현 가능
- `AIServiceBackend.bodyMutation`으로 게이트웨이 레벨 파라미터 강제 적용 가능
- 백엔드별 독립적인 정책 설정이 명확함

**흐름:**
```
1. 클라이언트 → Memory Service: GET /sessions/{id}  (히스토리 조회)
2. 클라이언트가 history + new_message 로 messages 배열 구성
3. 클라이언트 → AI Gateway: POST /v1/chat/completions
      Header: x-ai-eg-model, x-session-id, x-tenant-id
4. AI Gateway: BodyMutation 적용 (stream=false, max_tokens 강제)
5. AI Gateway → LLM Backend (OpenRouter 또는 Ollama)
6. 클라이언트 → Memory Service: POST /sessions/{id}/messages  (저장)
```

### 5.2 v0.5 신규 기능 활용 지점

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

### 5.3 Memory Service (Python FastAPI)

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

### 6.4 메모리 연속 대화 검증

```
Turn 1  히스토리 주입: 0개  →  "My name is Hong Gildong."
        LLM 응답: "Okay, Hong Gildong. I've got it!"

Turn 2  히스토리 주입: 2개  →  "What did I tell you my name was?"
        LLM 응답: "You told me your name was Hong Gildong."  ✅ 기억 성공

Redis 저장: 4개 메시지 (user+assistant × 2턴)
```

### 6.5 최종 클러스터 상태

```
NAMESPACE               POD                                        STATUS
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

- [ ] CRD 설치 (`ai-gateway-crds-helm`) 배포 파이프라인에 포함 여부 확인
- [ ] 모든 AI Gateway 리소스 `apiVersion`이 `v1alpha1`인지 검증
- [ ] Redis 배포가 Envoy Gateway 설치보다 먼저 실행되는 순서 보장
- [ ] `AIServiceBackend`에 `spec.timeouts` 필드가 없는지 확인
- [ ] OpenRouter 무료 모델 대신 유료 모델 또는 fallback 구성 검토
- [ ] `bodyMutation.set` 값 중 JSON 타입 문자열이 올바른지 확인
  - `"false"` (boolean) vs `'"false"'` (string)
  - `"1024"` (number) vs `'"1024"'` (string)
- [ ] `x-tenant-id` 헤더 없는 요청에 대한 rate limit 정책 결정
- [ ] Memory Service의 `SESSION_TTL_SECONDS` 값이 서비스 SLA에 맞는지 검토
- [ ] Kind → 실제 K8s 전환 시 Envoy 서비스 타입 `LoadBalancer` 확인
- [ ] `BackendTLSPolicy` v1alpha3 deprecation 경고 → v1으로 업그레이드 예정 확인

### 후속 과제

| 과제 | 우선순위 | 내용 |
|------|----------|------|
| Long-term Memory | Medium | 세션 간 지속 저장, 사용자별 요약 |
| Semantic Memory | Low | Redis Vector Search 연동 |
| 성능 벤치마크 | Medium | 메모리 조회 레이턴시, 동시 요청 처리량 |
| 프로덕션 배포 가이드 | High | EKS/GKE 환경 전환, TLS 설정 |
| BackendTLSPolicy v1 마이그레이션 | Low | v1alpha3 → v1 업그레이드 |

---

*이 가이드는 실제 구현 과정에서 발생한 문제와 해결책을 기반으로 작성되었습니다.*  
*참조 레포지토리: [envoyproxy/ai-gateway](https://github.com/envoyproxy/ai-gateway)*
