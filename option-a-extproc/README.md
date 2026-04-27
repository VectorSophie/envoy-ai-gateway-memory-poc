# memory-extproc

Envoy AI Gateway **v0.5** 기반 LLM 대화 메모리 PoC.

이 저장소는 챗봇 UI 프로젝트가 아니라, **Gateway 레이어에서 대화 메모리를 붙이는 인프라 PoC**다. 클라이언트는 `x-session-id` 헤더만 보내고, `memory-extproc`가 Redis에서 이전 대화를 조회해 요청 `messages`에 주입한 뒤 응답의 assistant 메시지를 다시 Redis에 저장한다.

프로젝트 목표와 배경은 [`Envoy AI Gateway 0.5 버전업 프로젝트 킥오프.md`](./Envoy%20AI%20Gateway%200.5%20%EB%B2%84%EC%A0%84%EC%97%85%20%ED%94%84%EB%A1%9C%EC%A0%9D%ED%8A%B8%20%ED%82%A5%EC%98%A4%ED%94%84.md)를 기준으로 한다.

## 목표 충족 상태

| 목표 | 현재 상태 | 근거 |
|------|-----------|------|
| Goal 1. v0.4 → v0.5 마이그레이션 | 충족 | `gatewayconfig.yaml`, `docs/migration-v04-to-v05.md` |
| Goal 2. 세션 기반 메모리 PoC | 충족 | `server.py`, `tests/unit/`, `scripts/verify-step4.sh`, `scripts/verify-step5.sh` |
| Goal 3. v0.5 기능 활용 방안 정리 | 부분 충족 | `AIGatewayRoute` + `AIServiceBackend` + `BackendSecurityPolicy` + `docs/architecture.md` |

단, 외부 OpenRouter 공식 경로의 **실제 200 검증**, **Redis TLS 실클러스터 적용**, **성능/확장성 벤치마크**, **long-term / semantic memory 확장**은 여전히 후속 과제다.

## 문서 읽기 순서

팀원이 저장소를 처음 볼 때는 아래 순서를 권장한다.

1. `README.md` — 프로젝트 목적, 현재 상태, 주요 리소스
2. `docs/document-guide.md` — 문서/코드 대응표, 읽기 순서, 파일 역할
3. `docs/architecture.md` — 설계 이유와 핵심 제약
4. `docs/migration-v04-to-v05.md` — v0.4 → v0.5 전환 포인트
5. `docs/ops-checklist.md` — 검증, 운영, 장애 대응

## 시스템 구조

```
Client
  └─▶ Envoy AI Gateway v0.5
        ├─▶ Custom ExtProc (memory-extproc, gRPC)
        │     └─▶ Redis (chat:<session_id>)
        └─▶ Upstream
              ├─▶ debug.local 경로: echo-backend / mock-llm / openrouter-proxy
              └─▶ 기본 경로: AIGatewayRoute → AIServiceBackend → Backend
```

### 요청/응답 흐름

1. Client가 `x-session-id`와 함께 `/v1/chat/completions` 요청을 보낸다.
2. `memory-extproc`가 session ID를 추출한다. 없으면 즉시 `400`을 반환한다.
3. Redis `chat:<session_id>`에서 history를 읽는다.
4. history + 현재 요청의 `messages`를 병합하고, Envoy body mutation으로 upstream에 전달한다.
5. 요청에 포함된 message 항목들(`system`/`user`/`assistant`/`tool`)을 Redis history에 저장한다.
6. 응답에서 assistant content를 추출해 Redis history에 추가 저장한다.

## 라우팅 구조

이 저장소는 **디버그 경로**와 **공식 v0.5 경로**를 분리해 검증한다.

| 경로 | 용도 | 리소스 |
|------|------|--------|
| `Host: debug.local` | Step 4, Mock, OpenRouter proxy, echo backend 검증 | `test-route.yaml` |
| 기본 호스트 | AI Gateway v0.5 공식 경로 검증 | `aigateway-route.yaml`, `aiservice-backend-openai.yaml`, `backend-security-policy.yaml` |

`extproc-policy.yaml`은 `test-route`와 `ai-route-openai` 둘 다 대상으로 잡아, 어느 경로를 타더라도 메모리 ExtProc가 동일하게 적용되도록 구성한다.

## 주요 파일

| 파일 | 역할 |
|------|------|
| `server.py` | ExtProc gRPC 서버. history 병합, assistant 저장, fail-degraded 처리, Redis TLS client 옵션 |
| `memory-extproc.yaml` | Custom ExtProc Deployment/Service, Redis TLS CA mount/env |
| `gatewayconfig.yaml` | v0.5 `GatewayConfig` 및 `Gateway` annotation 연결 |
| `extproc-policy.yaml` | `test-route`와 `ai-route-openai`에 ExtProc 연결 |
| `test-route.yaml` | `debug.local` 전용 디버그 `HTTPRoute` |
| `aigateway-route.yaml` | v0.5 공식 `AIGatewayRoute` |
| `aiservice-backend-openai.yaml` | 기본 PoC용 `Backend` + `AIServiceBackend` (mock 경로) |
| `aiservice-backend-openrouter-external.yaml` | 운영 전환용 외부 OpenRouter `Backend` + `AIServiceBackend` |
| `backend-security-policy.yaml` | 기본 PoC용 `BackendSecurityPolicy` (mock 경로) |
| `backend-security-policy-openrouter-external.yaml` | 외부 OpenRouter 경로용 `BackendSecurityPolicy` |
| `networkpolicy-redis.yaml` | Redis 접근 제한 |
| `docs/architecture.md` | 아키텍처 결정, 제약, 검증 전략 |
| `docs/migration-v04-to-v05.md` | v0.4 → v0.5 전환 가이드 |
| `docs/ops-checklist.md` | 운영 체크리스트, 스모크, 롤백 |

## 사전 요구사항

| 컴포넌트 | 버전 |
|----------|------|
| Kubernetes | v1.32+ |
| Envoy Gateway | v1.6.x |
| Envoy AI Gateway | v0.5.x |
| Python | 3.12+ |
| Redis | bitnami/redis 등 |

## envoy API 준비

Docker 이미지 빌드 시 protobuf 정의가 필요하므로 `envoy/`를 별도 클론한다.

```bash
git clone https://github.com/envoyproxy/envoy.git envoy
cd envoy
git checkout v1.36.4
cd ..
```

## 배포 순서

### 1. 이미지 빌드

```bash
docker build -t memory-extproc:latest .
kind load docker-image memory-extproc:latest --name ai-gateway-poc
```

### 2. 클러스터/기반 서비스 준비

```bash
kind create cluster --name ai-gateway-poc --image kindest/node:v1.32.0

helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.0 -n envoy-gateway-system --create-namespace

helm install aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v0.5.0 -n ai-gateway-system --create-namespace

helm install redis bitnami/redis -n ai-gateway-system
```

Redis TLS를 켤 때는 Helm values에서 `tls.enabled=true`와 CA Secret 배포를 함께 적용해야 한다. 현재 매니페스트는 `REDIS_TLS_ENABLED`, `REDIS_TLS_CA_CERT_PATH`, `REDIS_TLS_CHECK_HOSTNAME` env와 `/etc/redis-tls/ca.crt` mount 경로를 미리 잡아둔 상태다.

### Redis TLS 활성화 조건

`REDIS_TLS_ENABLED=true`로 배포하려면 아래 3개가 동시에 맞아야 한다.

- `REDIS_TLS_CA_CERT_PATH=/etc/redis-tls/ca.crt`
- `REDIS_TLS_CHECK_HOSTNAME=true`를 유지할 수 있는 서버 인증서 CN/SAN
- `redis-tls-ca` Secret이 `ai-gateway-system` 네임스페이스에 배포되어 있고 `memory-extproc` Pod에 mount됨

위 조건이 하나라도 빠지면 운영 배포에서는 TLS를 켠 상태로 진행하지 않는다. PoC/로컬 재현에서만 `REDIS_TLS_ENABLED=false` 평문 경로를 허용한다.

### 3. 매니페스트 적용

```bash
kubectl apply -f gatewayconfig.yaml
kubectl apply -f memory-extproc.yaml
kubectl apply -f extproc-policy.yaml
kubectl apply -f networkpolicy-redis.yaml

# 디버그 경로
kubectl apply -f echo-backend.yaml
kubectl apply -f test-route.yaml

# v0.5 공식 경로
kubectl apply -f aiservice-backend-openai.yaml
kubectl apply -f backend-security-policy.yaml
kubectl apply -f aigateway-route.yaml
```

외부 OpenRouter로 전환할 때는 위 기본 mock 경로 대신 아래 조합을 사용한다.

```bash
kubectl apply -f aiservice-backend-openrouter-external.yaml
kubectl apply -f backend-security-policy-openrouter-external.yaml
kubectl apply -f aigateway-route-openrouter-external.yaml
```

전환은 아래 조건이 모두 충족된 뒤에만 수행한다.

- Redis TLS 활성화 검증 완료
- Redis NetworkPolicy enforcement 재검증 완료
- `openrouter-secret` 준비 완료
- 클러스터 DNS와 egress 443이 `openrouter.ai`에 대해 허용됨
- pre-prod에서 외부 경로 200 응답 확인

외부 경로를 `verify-step5.sh`로 검증할 때는 아래처럼 실행한다.

```bash
VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh
```

## 검증 방법

### 1. 단위 테스트

로컬/CI에서 `server.py`의 helper와 SSE 감지 로직을 검증한다.

```bash
./.venv/bin/pytest tests/unit -v
```

### 2. Step 4: 데이터 파이프라인

`debug.local` 경로를 사용해 echo backend 기준으로 body mutation, Redis 저장, 세션 격리를 확인한다.

```bash
kubectl port-forward -n envoy-gateway-system svc/envoy-default-ai-gateway-<hash> 28080:80
bash scripts/verify-step4.sh
```

### 3. Step 5: 모델/공식 경로 검증

- Phase 1: `debug.local` + mock backend
- Phase 2-A: `debug.local` + OpenRouter proxy
- Phase 2-B: 기본 호스트 + `AIGatewayRoute`

```bash
bash scripts/verify-step5.sh
```

## 현재 범위와 제한

- Streaming 응답(`stream: true`)은 assistant 저장 대상에서 제외한다.
- Redis TLS는 코드/매니페스트상 준비돼 있지만, 실제 활성화는 Redis chart의 `tls.enabled=true`와 `redis-tls-ca` Secret 배포가 선행돼야 한다.
- Redis TLS 활성화 실패는 현재 코드에서 fail-open으로 자동 평문 전환되지 않는다. TLS를 켠 배포에서 연결이 실패하면 Redis access가 실패하고, ExtProc는 기존 fail-degraded 정책에 따라 history 없이 요청을 통과시킨다.
- 외부 OpenRouter 공식 경로는 route 전환용 매니페스트와 verify 단계까지는 준비됐지만, `BackendTLSPolicy` 적용 여부, DNS/egress, 실클러스터 200 검증은 후속 단계다.
- 외부 provider 오류(timeout, DNS 실패, 5xx)는 공식 경로에서 **fail-closed**로 취급한다. 운영 경로에서 mock으로 자동 fallback하지 않는다.
- 성능/확장성 벤치마크는 후속 과제다.
- Long-term / semantic memory 확장은 이번 PoC 범위 밖이다.

## 로컬 전용 파일

외부 공유와 PR 대상에서 제외해야 하는 로컬 파일은 `.gitignore`로 관리한다. 특히 `backup-*`는 로컬 복구용 백업이며 원격 저장소에 올리지 않는다.

- `private_docs/`
- `.codex/`
- `.tools/`
- `backup-*.tar.gz`
- `backup-*.bundle`

## 문서

- [docs/document-guide.md](./docs/document-guide.md)
- [docs/architecture.md](./docs/architecture.md)
- [docs/migration-v04-to-v05.md](./docs/migration-v04-to-v05.md)
- [docs/ops-checklist.md](./docs/ops-checklist.md)
- GitHub Release: [`v0.5.0-poc`](https://github.com/Chopper-Tony/envoy-aigw-memory-extproc/releases/tag/v0.5.0-poc)

> **런타임 경계:** `server.py`는 Envoy protobuf를 optional import 처리한다. Docker 이미지에서는 전체 기능 정상, CI(unit-only)에서는 `serve()` 및 `pb2.*` 참조 금지. 상세는 `server.py` 상단 주석과 Release 노트 참고.
