# AI Gateway Memory PoC — 아키텍처 다이어그램

> Envoy AI Gateway v0.5 + ExtProc 메모리 + BodyMutation + 멀티테넌트 토큰 제어  
> 각 다이어그램은 독립적으로 읽을 수 있습니다.

---

## 1. 시스템 컴포넌트 다이어그램

전체 구성 요소와 역할, 네임스페이스 경계를 보여줍니다.

```mermaid
graph TB
    subgraph Clients["클라이언트 앱"]
        KB[카카오뱅크]
        KM[카카오모빌리티]
        KC[카카오커머스]
        KE[카카오엔터]
    end

    subgraph Kind["Kubernetes Cluster  ─  Kind (ai-gateway-memory-poc)"]

        subgraph EG_NS["envoy-gateway-system"]
            EG_CTRL[Envoy Gateway Controller]
        end

        subgraph AIEG_NS["envoy-ai-gateway-system"]
            AIEG_CTRL[AI Gateway Controller]
        end

        subgraph Default_NS["default namespace"]
            subgraph Proxy["Envoy Proxy Pod  (owning-gateway: ai-memory-poc)"]
                direction TB
                EEP["EnvoyExtensionPolicy\n↕ ExtProc gRPC 연결"]
                BM["AIServiceBackend\nBodyMutation\n(stream: false, max_tokens)"]
                RL["BackendTrafficPolicy\n토큰 레이트 리밋\n(x-tenant-id Distinct)"]
                ROUTE["AIGatewayRoute\n헤더 기반 백엔드 선택\n(x-ai-eg-model)"]
            end

            EP["memory-extproc\n:50051 gRPC\n(Python + Redis)"]
            MS["memory-service\n:8080 REST\n(FastAPI)"]
        end

        subgraph Redis_NS["redis-system"]
            RD[("Redis\n:6379\nkey: memory:session:{id}")]
        end

        subgraph Ollama_NS["ollama  (옵션)"]
            OL["Ollama\n:11434"]
        end
    end

    subgraph Cloud["외부 LLM"]
        OR["OpenRouter API\ngoogle/gemma-3-4b-it:free"]
    end

    KB & KM & KC & KE -->|"POST /v1/chat/completions\nx-session-id / x-tenant-id"| Proxy
    EEP <-->|gRPC ProcessingRequest/Response| EP
    EP <-->|GET / SETEX| RD
    MS <-->|GET / SET / DEL| RD
    ROUTE -->|"ollama/* 모델"| OL
    ROUTE -->|"google/* 모델"| OR

    EG_CTRL -.->|"GatewayClass / EnvoyProxy 관리"| Proxy
    AIEG_CTRL -.->|"AIGatewayRoute / AIServiceBackend 변환"| Proxy

    style Clients fill:#fff3cd,stroke:#ffc107
    style Kind fill:#e8f4f8,stroke:#2196F3
    style Cloud fill:#f3e5f5,stroke:#9c27b0
```

---

## 2. 요청 처리 시퀀스 다이어그램

카카오뱅크 사용자의 대출 상담 2턴 예시 — 메모리가 작동하는 전체 흐름입니다.

```mermaid
sequenceDiagram
    actor User as 사용자<br/>(카카오뱅크 앱)
    participant GW as Envoy Proxy<br/>(AI Gateway)
    participant RL as BackendTrafficPolicy<br/>토큰 레이트 리밋
    participant EP as memory-extproc<br/>:50051 gRPC
    participant BM as BodyMutation<br/>(AIServiceBackend)
    participant LLM as 사내 LLM<br/>(Ollama)
    participant Redis as Redis<br/>memory:session:{id}
    participant MS as memory-service<br/>REST API

    Note over User,MS: ── 1턴: 첫 메시지 ──

    User->>GW: POST /v1/chat/completions<br/>x-session-id: kakaobank-user-kim<br/>x-tenant-id: kakaobank<br/>messages: [{role:user, content:"대출 알아보고 있어요..."}]

    GW->>RL: 토큰 예산 확인 (kakaobank, 50K/h)
    RL-->>GW: 200 OK

    GW->>EP: ProcessingRequest phase=request_headers
    EP-->>GW: HeadersResponse CONTINUE

    GW->>EP: ProcessingRequest phase=request_body
    EP->>Redis: GET memory:session:kakaobank-user-kim
    Redis-->>EP: (nil) 새 세션
    EP->>EP: 히스토리 없음 → 현재 메시지만 유지
    EP-->>GW: BodyResponse CONTINUE_AND_REPLACE<br/>body: {messages: [{user: "대출 알아보고 있어요..."}]}

    GW->>BM: BodyMutation 적용
    BM-->>GW: + stream:false, max_tokens:2048

    GW->>LLM: POST /v1/chat/completions<br/>{messages: [...], stream:false, max_tokens:2048}
    LLM-->>GW: {choices:[{message:{role:assistant, content:"연소득을 알려주세요"}}]}

    GW->>EP: ProcessingRequest phase=response_headers
    EP-->>GW: HeadersResponse CONTINUE

    GW->>EP: ProcessingRequest phase=response_body
    EP->>EP: assistant content 추출: "연소득을 알려주세요"
    EP->>Redis: SETEX memory:session:kakaobank-user-kim 3600<br/>[{user:"대출..."}, {assistant:"연소득을..."}]
    Redis-->>EP: OK
    EP-->>GW: BodyResponse CONTINUE

    GW-->>User: "연소득을 알려주세요"

    Note over User,MS: ── 30분 후 2턴: 재접속 ──

    User->>GW: POST /v1/chat/completions<br/>x-session-id: kakaobank-user-kim<br/>messages: [{role:user, content:"연소득 5천만원, 직장인이에요"}]

    GW->>EP: ProcessingRequest phase=request_body
    EP->>Redis: GET memory:session:kakaobank-user-kim
    Redis-->>EP: [{user:"대출..."}, {assistant:"연소득을..."}]
    EP->>EP: 히스토리(2개) + 현재 메시지 병합
    EP-->>GW: BodyResponse CONTINUE_AND_REPLACE<br/>body: {messages: [기존2개 + 현재]}

    GW->>LLM: POST /v1/chat/completions {messages: [3개]}
    LLM-->>GW: "김민준님, 신용대출 최대 2,500만원..."

    GW->>EP: ProcessingRequest phase=response_body
    EP->>Redis: SETEX ... [3개 히스토리 + 새 응답]
    EP-->>GW: CONTINUE

    GW-->>User: "김민준님, 신용대출 최대 2,500만원..."

    Note over User,MS: ── 슬래시 명령어: /clear ──
    User->>MS: DELETE /sessions/kakaobank-user-kim
    MS->>Redis: DEL memory:session:kakaobank-user-kim
    Redis-->>MS: 1
    MS-->>User: 204 No Content
```

---

## 3. ExtProc 처리 플로우차트

`memory-extproc`이 각 phase에서 내리는 결정과 에러 처리 전략입니다.

```mermaid
flowchart TD
    START([ProcessingRequest 수신]) --> PHASE{Phase?}

    PHASE -->|request_headers| RH_EXTRACT[x-session-id 헤더 추출]
    RH_EXTRACT --> RH_CHECK{세션 ID 있음?}
    RH_CHECK -->|없음| RH_FAIL[즉시 응답\n400 Bad Request\nfail-closed]
    RH_CHECK -->|있음| RH_STORE[세션 ID 저장\nContent-Type 저장]
    RH_STORE --> RH_CONT([CONTINUE])

    PHASE -->|request_body| RB_PARSE[JSON body 파싱]
    RB_PARSE --> RB_CHECK{파싱 성공?}
    RB_CHECK -->|실패| RB_PASS([원본 body 통과\nfail-open])
    RB_CHECK -->|성공| RB_REDIS[Redis 히스토리 조회\nGET memory:session:{id}]
    RB_REDIS --> RB_REDIS_CHK{Redis 응답?}
    RB_REDIS_CHK -->|RedisError| RB_DEGRADE[히스토리 없이 계속\nfail-degraded\n카운터 증가]
    RB_REDIS_CHK -->|nil 새 세션| RB_EMPTY[빈 히스토리]
    RB_REDIS_CHK -->|JSON 데이터| RB_DECODE[히스토리 파싱\n유효성 검증]
    RB_DECODE --> RB_MERGE
    RB_EMPTY --> RB_MERGE
    RB_DEGRADE --> RB_MERGE
    RB_MERGE[히스토리 + 현재 메시지 병합] --> RB_TRIM[MAX_HISTORY_LENGTH 트리밍\n최신 N개 유지]
    RB_TRIM --> RB_REPLACE([body 교체\nCONTINUE_AND_REPLACE])

    PHASE -->|response_headers| RSP_HDR[Content-Type 저장\nSSE 여부 플래그]
    RSP_HDR --> RSP_CONT([CONTINUE])

    PHASE -->|response_body| RSP_SSE{Content-Type 또는\nbody prefix가 SSE?}
    RSP_SSE -->|data: / event: / id:| SSE_SKIP([스트리밍 pass-through\n저장 스킵])
    RSP_SSE -->|아니오| RSP_PARSE[JSON 파싱]
    RSP_PARSE --> RSP_EXTRACT[choices 순회\nassistant role 추출]
    RSP_EXTRACT --> RSP_FOUND{assistant content\n있음?}
    RSP_FOUND -->|없음| RSP_SKIP([저장 스킵 CONTINUE])
    RSP_FOUND -->|있음| RSP_APPEND[히스토리에 assistant 메시지 추가]
    RSP_APPEND --> RSP_SAVE[Redis SETEX\nTTL: 3600s]
    RSP_SAVE --> RSP_REDIS_CHK{저장 성공?}
    RSP_REDIS_CHK -->|실패| RSP_WARN[경고 로그\n카운터 증가]
    RSP_REDIS_CHK -->|성공| RSP_OK
    RSP_WARN --> RSP_OK([CONTINUE])

    style RH_FAIL fill:#ffcdd2,stroke:#f44336
    style RB_PASS fill:#fff9c4,stroke:#fbc02d
    style RB_DEGRADE fill:#fff9c4,stroke:#fbc02d
    style SSE_SKIP fill:#e8eaf6,stroke:#5c6bc0
```

---

## 4. 멀티테넌트 라우팅 다이어그램

테넌트별 토큰 예산, LLM 선택, BodyMutation 파라미터 적용 흐름입니다.

```mermaid
flowchart LR
    subgraph Apps["계열사 앱"]
        KB_APP["카카오뱅크\nx-tenant-id: kakaobank\nx-ai-eg-model: ollama/llama3.2"]
        KM_APP["카카오맵\nx-tenant-id: kakaomap\nx-ai-eg-model: google/gemma-3-4b-it:free"]
        KE_APP["카카오엔터\nx-tenant-id: kakaoent\nx-ai-eg-model: google/gemma-3-4b-it:free"]
    end

    subgraph Gateway["AI Gateway"]
        ROUTER{"AIGatewayRoute\n헤더 기반 라우팅\n(x-ai-eg-model prefix)"}

        subgraph Budgets["BackendTrafficPolicy (토큰 예산/시간)"]
            RL_KB["kakaobank\n50,000 tokens/h"]
            RL_KM["kakaomap\n30,000 tokens/h"]
            RL_KE["kakaoent\n20,000 tokens/h"]
        end

        subgraph Mutations["AIServiceBackend BodyMutation"]
            BM_KB["kakaobank\nstream: false\nmax_tokens: 2048\nmodel: llama3.2"]
            BM_OR["openrouter\nstream: false\nmax_tokens: 1024\nmodel: gemma-3-4b-it:free"]
        end
    end

    subgraph Backends["LLM 백엔드"]
        OLLAMA["사내 LLM\nOllama :11434\n(금융 데이터 외부 미전송)"]
        OPENROUTER["OpenRouter\ngoogle/gemma-3-4b-it:free"]
    end

    ERR429["429 Too Many Requests\n'상담 한도 초과,\n잠시 후 이용해주세요'"]

    KB_APP --> RL_KB
    KM_APP --> RL_KM
    KE_APP --> RL_KE

    RL_KB -->|한도 내| ROUTER
    RL_KM -->|한도 내| ROUTER
    RL_KE -->|한도 내| ROUTER

    RL_KB -->|한도 초과| ERR429
    RL_KM -->|한도 초과| ERR429
    RL_KE -->|한도 초과| ERR429

    ROUTER -->|"ollama/*"| BM_KB --> OLLAMA
    ROUTER -->|"google/*"| BM_OR --> OPENROUTER

    style ERR429 fill:#ffcdd2,stroke:#f44336
    style OLLAMA fill:#e8f5e9,stroke:#4caf50
    style OPENROUTER fill:#e3f2fd,stroke:#2196f3
```

---

## 5. K8s 배포 다이어그램

Kind 클러스터 내 실제 Pod 배치와 네트워크 연결입니다.

```mermaid
graph TB
    subgraph Host["로컬 머신 (Windows 11 / Docker Desktop / WSL2)"]
        PF1["port-forward :8080 → Gateway"]
        PF2["port-forward :8081 → Memory Service"]
        DEMO["demo-client/chat.py\n또는 curl"]
    end

    subgraph Kind["Kind Cluster: ai-gateway-memory-poc"]

        subgraph EG_NS["envoy-gateway-system"]
            EG[Envoy Gateway Controller Pod]
        end

        subgraph AIEG_NS["envoy-ai-gateway-system"]
            AIEG[AI Gateway Controller Pod]
        end

        subgraph Default["default namespace"]
            GW_SVC["Service: ai-memory-poc-*\nClusterIP :80"]
            GW_POD["Envoy Proxy Pod\nimage: envoyproxy/envoy\nimagePullPolicy: IfNotPresent"]

            EP_SVC["Service: memory-extproc\nClusterIP :50051"]
            EP_POD["memory-extproc Pod\nimage: memory-extproc:latest\nimagePullPolicy: Never\n(Kind 로컬 이미지)"]

            MS_SVC["Service: memory-service\nClusterIP :8080"]
            MS_POD["memory-service Pod\nimage: ai-gateway-memory-service:latest\nimagePullPolicy: Never"]
        end

        subgraph Redis_NS["redis-system"]
            RD_SVC["Service: redis\nClusterIP :6379"]
            RD_POD[("Redis Pod\nimage: redis:7-alpine")]
        end

        subgraph Ollama_NS["ollama  (옵션)"]
            OL_SVC["Service: ollama\nClusterIP :11434"]
            OL_POD["Ollama Pod\nimage: ollama/ollama"]
        end
    end

    subgraph External["외부"]
        OR_API["OpenRouter API\nhttps://openrouter.ai"]
    end

    DEMO -->|":8080"| PF1 -->|NodePort| GW_SVC --> GW_POD
    DEMO -->|":8081"| PF2 -->|NodePort| MS_SVC --> MS_POD

    GW_POD <-->|gRPC :50051| EP_SVC --> EP_POD
    GW_POD -->|"ollama/* → :11434"| OL_SVC --> OL_POD
    GW_POD -->|"google/* → HTTPS"| OR_API

    EP_POD <-->|":6379"| RD_SVC --> RD_POD
    MS_POD <-->|":6379"| RD_SVC

    EG -.->|"GatewayClass 감시\nEnvoy Proxy 생성"| GW_POD
    AIEG -.->|"AIGatewayRoute → xDS\nBodyMutation 변환"| GW_POD

    style Kind fill:#e8f4f8,stroke:#2196F3
    style Host fill:#fff8e1,stroke:#ff8f00
    style External fill:#f3e5f5,stroke:#9c27b0
```

---

## 6. 세션 생명주기 상태 다이어그램

하나의 대화 세션이 생성되어 소멸될 때까지의 상태 변화입니다.

```mermaid
stateDiagram-v2
    [*] --> 신규세션 : x-session-id 첫 요청\n(Redis 키 없음)

    state 신규세션 {
        [*] --> 빈_히스토리 : ExtProc GET → nil
        빈_히스토리 --> [*] : 현재 메시지만 LLM 전달
    }

    신규세션 --> 활성 : 첫 응답 저장\nREDIS SETEX TTL:3600

    state 활성 {
        [*] --> 요청수신
        요청수신 --> Redis조회 : ExtProc request_body
        Redis조회 --> 히스토리병합 : 이전 대화 복원
        히스토리병합 --> LLM전달 : 전체 컨텍스트
        LLM전달 --> Redis저장 : ExtProc response_body\nSETEX (TTL 갱신)
        Redis저장 --> [*] : 응답 반환
    }

    활성 --> 트리밍필요 : 히스토리 길이 >\nMAX_HISTORY_LENGTH (20)
    트리밍필요 --> 활성 : 최신 N개만 유지\n(오래된 메시지 제거)

    활성 --> 만료 : TTL 3600s 경과\n(비활성 1시간)
    활성 --> 초기화됨 : /clear 명령어\nDELETE /sessions/{id}
    활성 --> Redis장애 : RedisError

    Redis장애 --> 활성 : fail-degraded\n히스토리 없이 계속\n(서비스 중단 없음)

    만료 --> [*] : Redis 자동 삭제
    초기화됨 --> [*] : 상담 종료

    note right of 활성
        매 요청마다 TTL 갱신
        → 활성 대화는 만료되지 않음
    end note

    note right of Redis장애
        카운터(_REDIS_FAIL_COUNTER)
        증가 후 계속 서비스
    end note
```

---

## 7. 이상 사용 탐지 시나리오 다이어그램

`kakaoent` 테넌트에서 토큰 급증이 발생했을 때의 처리 흐름입니다.

```mermaid
sequenceDiagram
    participant ATK as 악성 클라이언트<br/>(무한 루프 프롬프트)
    participant GW as AI Gateway
    participant RL as BackendTrafficPolicy<br/>kakaoent: 20K tokens/h
    participant LLM as OpenRouter
    participant OTHER as 정상 사용자<br/>(kakaobank / kakaomap)
    participant OPS as 운영팀

    Note over ATK,OPS: 정상 구간 (~500 tokens/min)

    loop 정상 사용
        ATK->>GW: POST (x-tenant-id: kakaoent)
        GW->>RL: 토큰 차감
        RL-->>GW: OK (예산 잔여)
        GW->>LLM: 요청 전달
    end

    Note over ATK,OPS: 이상 급증 (~45,000 tokens/min, 90×)

    loop 루프 공격
        ATK->>GW: POST (무한 루프 프롬프트 반복)
        GW->>RL: 토큰 차감 요청
        RL-->>GW: 429 Too Many Requests
        GW-->>ATK: 429 "이 시간대 상담 한도 초과"
    end

    Note over RL: kakaoent 예산 소진<br/>다른 테넌트에는 영향 없음

    RL--)OPS: 알람 (토큰 사용량 급증 감지)

    Note over OTHER,OPS: 동시에 정상 서비스 유지

    OTHER->>GW: POST (x-tenant-id: kakaobank)
    GW->>RL: kakaobank 예산 확인 (별도 버짓)
    RL-->>GW: OK
    GW->>LLM: 정상 처리
    GW-->>OTHER: 응답 정상 반환 ✅

    Note over OPS: v0.5 이후 확장 가능
    OPS->>GW: DELETE /sessions/{악성-session-id}
    GW-->>OPS: 204 세션 강제 초기화
```

---

## 8. Option A + B 통합 전후 비교

두 구현 방식을 통합하기 전후의 아키텍처 차이입니다.

```mermaid
flowchart TB
    subgraph Before["통합 이전 — 두 방식 분리"]
        subgraph OptA["Option A (팀원: 게이트웨이 서버사이드)"]
            direction LR
            A_CLI["클라이언트\n(현재 메시지만)"] -->|"x-session-id"| A_GW["Gateway\n+ ExtProc"]
            A_GW <-->|"자동 히스토리 주입"| A_REDIS[("Redis")]
            A_GW -->|"파라미터 통제 없음"| A_LLM["LLM"]
        end

        subgraph OptB["Option B (자체: 클라이언트 사이드)"]
            direction LR
            B_CLI["클라이언트\n(히스토리 직접 관리)"] -->|"전체 messages 배열"| B_GW["Gateway\n+ BodyMutation"]
            B_CLI <-->|"GET/POST 호출"| B_MS["Memory Service\nREST API"]
            B_GW -->|"stream:false 강제"| B_LLM["LLM"]
        end
    end

    subgraph After["통합 이후 — 단일 아키텍처"]
        direction TB
        C_CLI["클라이언트\n(현재 메시지만)"] -->|"x-session-id\nx-tenant-id"| C_GW

        subgraph C_GW["AI Gateway (통합)"]
            direction TB
            C_EP["ExtProc\n(투명 히스토리 주입/저장)"]
            C_BM["BodyMutation\n(파라미터 강제)"]
            C_RL["BackendTrafficPolicy\n(토큰 예산)"]
        end

        C_GW -->|"전체 컨텍스트 + 제어 파라미터"| C_LLM["LLM"]
        C_GW <-->|"GET/SETEX\nmemory:session:{id}"| C_REDIS[("Redis")]
        C_CLI <-->|"/clear /history /system\n관리 명령어 전용"| C_MS["Memory Service\nREST API"]
        C_REDIS <--> C_MS
    end

    Before -.->|"기능 통합"| After

    style OptA fill:#e3f2fd,stroke:#1976d2
    style OptB fill:#e8f5e9,stroke:#388e3c
    style After fill:#fff3e0,stroke:#f57c00
```

---

*생성일: 2026-04-28 | 프로젝트: Envoy AI Gateway Memory PoC (v0.5)*
