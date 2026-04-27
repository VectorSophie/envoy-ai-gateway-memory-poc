# Current Status Handoff

## 1. 한 줄 요약

- Custom ExtProc가 Redis에 대화 history를 저장하고, Envoy AI Gateway 경로에서 요청 body를 병합하는 PoC다.

## 2. 현재 검증된 Redis NetworkPolicy 상태

| 항목 | 현재 기준 |
|------|-----------|
| Redis 보호 방식 | `networkpolicy-redis.yaml`의 Redis ingress allowlist |
| 허용 source | `ai-gateway-system` namespace의 `app=memory-extproc` Pod |
| 추가 허용 | Redis Pod 상호 통신 |
| 차단 기준 | 허용되지 않은 Pod의 Redis 접속 timeout |
| 검증일 | 2026-04-27 |

## 3. 필수 전제

- Redis Helm chart의 기본 NetworkPolicy는 꺼야 한다.
  - 필수 값: `networkPolicy.enabled=false`
- Redis Pod를 선택하는 NetworkPolicy는 repo의 `networkpolicy-redis.yaml`만 남아야 한다.
  - 정책 이름: `redis-allow-memory-extproc`
- Kubernetes NetworkPolicy는 union(OR) 방식이다.
  - chart의 permissive policy가 함께 있으면 repo allowlist가 있어도 Redis ingress가 열린다.

## 4. 검증 결과

| 검증 | 결과 |
|------|------|
| `memory-extproc` Pod -> Redis TLS 접속 | PASS |
| `default` namespace 임의 Pod -> Redis 접속 | timeout 차단 |
| `ai-gateway-system` namespace 임의 Pod -> Redis 접속 | timeout 차단 |
| NetworkPolicy 적용 상태의 Step 4 | PASS |

- Step 4 명령:

```bash
GATEWAY_URL=http://localhost:28082 bash scripts/verify-step4.sh
```

- 결과:
  - Gate 1-7 전체 통과
  - Redis 저장 유지
  - session 격리 유지
  - fail-open/fail-degraded 동작 유지

## 5. 실패 사례

| 증상 | 판단 |
|------|------|
| 임의 Pod의 `redis-cli`가 `NOAUTH Authentication required.` 반환 | NetworkPolicy 차단 실패. Redis까지 연결된 뒤 인증에서 실패한 상태 |
| 임의 Pod의 Redis 접속이 timeout | NetworkPolicy 차단 성공 |
| Helm chart policy와 repo policy가 동시에 Redis Pod 선택 | enforcement 실패 가능. NetworkPolicy union(OR) 때문에 permissive rule이 이김 |

## 6. 운영 체크

- [ ] `helm get values redis -n ai-gateway-system | grep networkPolicy`로 chart NetworkPolicy 비활성화 확인
- [ ] `kubectl get networkpolicy -n ai-gateway-system`에서 Redis Pod 선택 policy가 `redis-allow-memory-extproc`뿐인지 확인
- [ ] `kubectl describe networkpolicy -n ai-gateway-system redis-allow-memory-extproc`로 허용 source 확인
- [ ] 허용 source가 `app=memory-extproc`와 Redis Pod 상호 통신뿐인지 확인
- [ ] 임의 Pod에서 Redis 접속 시도 시 timeout으로 실패하는지 확인
- [ ] `scripts/verify-step4.sh`로 memory 기능이 유지되는지 확인

## 7. 남은 리스크

- Redis Helm chart upgrade 또는 values 재적용으로 `networkPolicy.enabled=true`가 되면 enforcement가 다시 무력화될 수 있다.
- `NOAUTH`는 차단 성공이 아니므로 운영 검증에서 성공으로 오인하면 안 된다.
- cluster-wide deny-by-default 정책은 현재 범위가 아니다.
