# 문서/코드 가이드

> 문서만으로 코드 구조, 검증 흐름, 현재 완료 범위를 빠르게 파악할 수 있도록 정리한 인덱스다.

## 1. 이 프로젝트가 무엇인가

이 저장소는 챗봇 UI 프로젝트가 아니다. `Envoy AI Gateway v0.5` 앞단에 **세션 기반 대화 메모리**를 붙이는 인프라 PoC다.

핵심 동작은 간단하다.

1. 클라이언트가 `/v1/chat/completions` 요청과 `x-session-id`를 보낸다.
2. `memory-extproc`가 Redis에서 `chat:<session_id>` history를 읽는다.
3. history와 현재 `messages`를 합쳐 upstream으로 보낸다.
4. 응답의 assistant 메시지를 다시 Redis에 저장한다.

즉, 코드의 중심은 `server.py`이고, 나머지 YAML은 이 서버가 Gateway 경로에 붙도록 만드는 배선이다.

## 2. 권장 문서 읽기 순서

권장 순서는 아래와 같다.

1. `README.md`
   - 프로젝트 목적, 현재 범위, 주요 리소스, 검증 흐름을 가장 빠르게 파악하는 입구
2. `docs/document-guide.md`
   - 문서와 코드의 대응 관계, 어떤 파일이 어느 역할인지 한눈에 보는 안내서
3. `docs/architecture.md`
   - 왜 이런 구조를 택했는지, 어떤 제약 때문에 현재 설계가 나왔는지 설명하는 핵심 문서
4. `docs/migration-v04-to-v05.md`
   - v0.4에서 v0.5로 무엇이 바뀌었고 저장소가 그 변화를 어떻게 반영했는지 설명
5. `docs/ops-checklist.md`
   - 실제 배포/검증/운영/롤백 절차

요약:

- 구조 이해: `README.md` + `docs/document-guide.md`
- 설계 이유 이해: `docs/architecture.md`
- 버전업 맥락 이해: `docs/migration-v04-to-v05.md`
- 실행/운영 이해: `docs/ops-checklist.md`

## 3. 코드 진입점

### 3.1 런타임 핵심

- `server.py`
  - 요청 헤더에서 `x-session-id` 추출
  - Redis history 조회
  - request body mutation
  - assistant 응답 저장
  - Redis fail-degraded 처리
  - Redis TLS client 옵션 처리

코드 확인 순서는 아래를 권장한다.

1. 환경 변수 상수
2. `_redis_client_kwargs`, `_build_redis_client`
3. `_truncate_history`, `_history_entries_from_messages`
4. `_redis_get_history`, `_redis_save_history`
5. `_extract_session_id`, `_extract_assistant_content`
6. `ExtProcServicer.Process`

### 3.2 테스트 핵심

- `tests/unit/test_processor.py`
  - `server.py` 헬퍼 함수의 기대 동작을 고정한다.
  - 세션 추출, SSE 감지, Redis fail-degraded, Redis TLS kwargs를 확인한다.

## 4. YAML이 각각 무엇을 하나

### 4.1 메모리 서버 배포

- `memory-extproc.yaml`
  - `memory-extproc` Deployment/Service
  - Redis host/password/TLS env
  - Redis CA Secret mount

### 4.2 Gateway 연결

- `extproc-policy.yaml`
  - Custom ExtProc를 Gateway 경로에 연결한다.
  - `test-route`와 `ai-route-openai` 둘 다 대상으로 잡는다.

- `gatewayconfig.yaml`
  - AI Gateway built-in ExtProc 리소스 설정
  - v0.5 방식의 공식 구성 포인트

### 4.3 라우팅

- `test-route.yaml`
  - `Host: debug.local` 디버그 경로
  - echo backend / mock / OpenRouter proxy 검증용

- `aigateway-route.yaml`
  - 기본 호스트의 공식 v0.5 경로

- `aiservice-backend-openai.yaml`
  - `Backend`와 `AIServiceBackend`
  - 기본 PoC의 mock 기반 공식 경로에서 provider-compatible schema를 담당

- `aiservice-backend-openrouter-external.yaml`
  - 외부 OpenRouter 전환용 `Backend`와 `AIServiceBackend`
  - 기본 PoC가 아니라 운영 전환/리허설 시 적용

- `backend-security-policy.yaml`
  - mock 기반 공식 경로의 API key Secret 연결

- `backend-security-policy-openrouter-external.yaml`
  - 외부 OpenRouter 경로용 API key Secret 연결

### 4.4 보안

- `networkpolicy-redis.yaml`
  - Redis ingress 제한
  - `memory-extproc`와 Redis pod 상호 통신만 허용

## 5. 요청 흐름

### 5.1 Step 4 디버그 경로

`Client -> Gateway(debug.local) -> ExtProc -> Redis -> echo/mock/OpenRouter proxy`

이 경로는 메모리 로직이 정상적으로 연결됐는지 가장 단순하게 검증하는 용도다.

확인 포인트:

- request body에 history가 합쳐졌는가
- Redis key가 증가하는가
- 세션별로 분리되는가

### 5.2 Step 5 공식 경로

`Client -> Gateway(default host) -> AIGatewayRoute -> AIServiceBackend -> Backend`

이 경로는 v0.5 공식 리소스 위에서도 메모리 로직이 동작하는지 확인하는 용도다.

확인 포인트:

- 경로가 `Accepted=True`인가
- 공식 경로 요청이 200인가
- merged messages가 provider까지 전달되는가
- assistant 저장이 되는가

## 6. 문서와 코드의 대응표

| 알고 싶은 것 | 먼저 볼 문서 | 바로 이어서 볼 코드 |
|--------------|--------------|----------------------|
| 프로젝트가 뭘 하는가 | `README.md` | `server.py` |
| 왜 이런 구조를 택했는가 | `docs/architecture.md` | `extproc-policy.yaml`, `aigateway-route.yaml` |
| v0.5에서 뭐가 달라졌는가 | `docs/migration-v04-to-v05.md` | `gatewayconfig.yaml`, `memory-extproc.yaml` |
| 운영 전에 뭘 확인해야 하나 | `docs/ops-checklist.md` | `scripts/verify-step4.sh`, `scripts/verify-step5.sh` |
| Redis TLS가 어디 반영됐나 | `README.md`, `docs/ops-checklist.md` | `server.py`, `memory-extproc.yaml` |
| NetworkPolicy 범위가 뭔가 | `docs/architecture.md`, `docs/ops-checklist.md` | `networkpolicy-redis.yaml` |

## 7. 현재 기준으로 “어디까지 됐는가”

현재 저장소 기준 상태는 이렇다.

- Goal 1. v0.4 → v0.5 마이그레이션: 거의 완료
  - `gatewayconfig.yaml`, `aigateway-route.yaml`, `docs/migration-v04-to-v05.md`까지 정리돼 있다.
  - 다만 운영 기준 재검증과 최종 롤백/배포 절차 polish는 남아 있다.
- Goal 2. 세션 기반 메모리 PoC: 완료에 가깝다
  - `server.py`, `tests/unit/test_processor.py`, `scripts/verify-step4.sh`, `scripts/verify-step5.sh`로 short-term memory PoC는 닫혀 있다.
  - OpenRouter semantic 검증용 runtime도 `tests/openrouter-proxy/`에 반영돼 있다.
- Goal 3. v0.5 기능 활용 방안 정리: 부분 완료
  - mock 기반 공식 경로와 외부 OpenRouter 전환 초안은 문서/매니페스트까지 정리됐다.
  - 하지만 외부 OpenRouter 공식 경로의 `/api/v1`, TLS, DNS/egress, pre-prod 200 검증은 아직 남아 있다.

남은 핵심 과제는 아래다.

- Redis TLS 실클러스터 활성화 검증
- Redis NetworkPolicy enforcement 재검증
- 외부 OpenRouter 공식 경로 실연동 검증
- 성능/확장성 벤치마크
- long-term / semantic memory 확장

## 8. 권장 공유 문서 묶음

기본 공유 묶음은 아래 4개다.

- `README.md`
- `docs/document-guide.md`
- `docs/architecture.md`
- `docs/ops-checklist.md`

버전업 변경 맥락이 필요하면 아래 문서를 추가한다.

- `docs/migration-v04-to-v05.md`
