# M3-2 Handoff

## 1. 현재 목표

- Envoy AI Gateway 공식 external 경로에서 `openrouter.ai/api/v1`까지 실제 `200`을 받는다.

## 2. PR 역할 분리

- 브랜치: `codex/m3-openrouter-external-readiness`
- PR #29: merged된 선행 준비 PR
  - external OpenRouter route 준비 변경 포함
  - `aiservice-backend-openrouter-external.yaml`
  - `backend-security-policy-openrouter-external.yaml`
  - `aigateway-route-openrouter-external.yaml`
- PR #30: 현재 source of truth / 실제 `200` 검증 완료 PR
  - PR #29 이후 후속 변경만 포함
  - `gatewayconfig.yaml`
  - `backend-tls-policy-openrouter-external.yaml`
  - `docs/handoff-m3-2.md`
  - `docs/migration-v04-to-v05.md`
  - `scripts/verify-step5.sh`

## 3. PR #30에서 확인한 상태

- `gatewayconfig.yaml`
  - Redis env 제거
  - 이유: built-in extproc가 `secret "redis" not found`로 깨졌음
- `backend-tls-policy-openrouter-external.yaml`
  - `openrouter.ai` 대상 `BackendTLSPolicy` 추가
- `scripts/verify-step5.sh`
  - `VERIFY_EXTERNAL_OPENROUTER=1` 기반 Phase 2-C를 실제 200 기준으로 정리
- live cluster 확인 완료
  - DNS: `openrouter.ai` resolve 성공
  - TLS handshake: 성공
  - direct OpenRouter call: `200`
  - external gateway call: TLS 전엔 `400 plain HTTP request was sent to HTTPS port`
  - `BackendTLSPolicy` 적용 후: `403 error code: 1010`
  - `Authorization: Bearer` fallback + `/v1 -> /api/v1` rewrite 후: `200`

## 4. 완료 기준과 남은 caveat

- external gateway 경로 `200` 달성 완료
- 남은 caveat
  - `BackendSecurityPolicy.spec.apiKey.header` 필드는 없음
  - v0.5 CRD 설명상 APIKey는 `Authorization` 헤더에 주입되고 Secret key는 `apiKey`여야 함
  - live 검증에서는 BackendSecurityPolicy 주입만으로 OpenRouter 인증이 upstream에 도달하지 않아 Phase 2-C에서 `Authorization: Bearer`를 명시했다
  - OpenRouter upstream path는 `/api/v1/chat/completions`여야 하지만 AI Gateway extproc는 `/v1/chat/completions`에 등록되어 있으므로, generated `HTTPRouteFilter`에 `/v1 -> /api/v1` rewrite가 필요했다
  - external 200은 통과했지만 Redis assistant 저장은 미확인이다

## 5. BackendSecurityPolicy APIKey 조사 결과

- `backendsecuritypolicy.spec.apiKey.header` 필드는 v0.5 CRD에 없으며, APIKey 방식은 `Authorization` 헤더 주입을 전제로 한다.
- `openrouter-secret`에는 `OPENROUTER_API_KEY`와 `apiKey`가 모두 있고, `apiKey`는 `Bearer` 접두사가 붙은 값으로 구성되어 있다.
- AI Gateway extproc 설정 Secret에는 `default/ai-service-openrouter-external/...` backend의 `auth.apiKey.key`가 생성되어 있어, 정책 reconciliation 자체는 성공한 상태다.
- generated `HTTPRoute`는 `openrouter-api-backend-eg`와 `HTTPRouteFilter` path rewrite를 사용하며, upstream path는 `/api/v1/chat/completions`로 전달되는 상태다.
- custom `memory-extproc` 코드에는 `Authorization` 헤더 제거 로직이 없고, 요청 mutation은 `content-length` 제거에 한정된다.
- 명시적 `Authorization: Bearer` 없이 gateway를 호출하면 OpenRouter가 `401`을 반환한다. 따라서 현재 문제는 manifest 생성 실패가 아니라 AI Gateway extproc 또는 Envoy 경로에서 정책 기반 인증 헤더가 upstream 요청에 실제 반영되지 않는 런타임 동작으로 본다.
- 결론: 원인 확정 전까지 Phase 2-C의 명시적 `Authorization: Bearer` fallback은 유지한다.

## 6. 다음에 해야 할 작업

1. generated `HTTPRouteFilter` path rewrite를 영속화할 방법 결정
2. BackendSecurityPolicy auth 주입이 OpenRouter upstream 요청에 반영되지 않는 런타임 원인 별도 추적
3. external 200 기준은 `VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh`로 재검증

## 7. 실행 명령어

```bash
# worktree
cd /tmp/memory-extproc-m32

# 브랜치/상태 확인
git branch --show-current
git status --short

# PR 브랜치 최신 push
git push origin codex/m3-openrouter-external-readiness

# external manifest와 path rewrite 적용
bash scripts/apply-openrouter-external.sh

# 스크립트는 prod 계열 kubectl context에서 기본 중단하며, generated HTTPRouteFilter를 ownerRef 기준으로 찾아 exact match일 때만 patch를 건너뛴다.

# live external backend 확인
kubectl get aigatewayroute ai-route-openai -n default -o jsonpath='{.spec.rules[0].backendRefs[0].name}'

# BackendTLSPolicy 적용
kubectl get backendtlspolicy -n default openrouter-backend-tls -o yaml

# BackendSecurityPolicy CRD는 Secret key apiKey를 요구한다.
# 현재 Phase 2-C는 검증 요청에 Authorization: Bearer를 명시한다.
KEY=$(kubectl get secret openrouter-secret -n default -o jsonpath='{.data.OPENROUTER_API_KEY}' | base64 -d | tr -d '\n')
kubectl create secret generic openrouter-secret --from-literal=OPENROUTER_API_KEY="$KEY" --from-literal=apiKey="Bearer $KEY" -n default --dry-run=client -o yaml | kubectl apply -f -

VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh

# external 직접 호출 (gateway 경유)
kubectl exec -n ai-gateway-system deploy/memory-extproc -- python -c "exec('import json, urllib.request, urllib.error\nurl=\"http://envoy-default-ai-gateway-27dc8f39.envoy-gateway-system.svc.cluster.local/v1/chat/completions\"\ndata=json.dumps({\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}).encode()\nreq=urllib.request.Request(url, data=data, method=\"POST\", headers={\"Content-Type\":\"application/json\",\"x-session-id\":\"m32-ext-check\"})\ntry:\n    resp=urllib.request.urlopen(req, timeout=30)\n    print(\"STATUS\", resp.status)\n    print(resp.read().decode())\nexcept urllib.error.HTTPError as e:\n    print(\"HTTPError\", e.code)\n    print(e.read().decode())')"

# unit test
./.venv/bin/pytest tests/unit -v
```

## 8. PR #30 신규 변경 파일

- `/tmp/memory-extproc-m32/backend-tls-policy-openrouter-external.yaml`
- `/tmp/memory-extproc-m32/gatewayconfig.yaml`
- `/tmp/memory-extproc-m32/scripts/verify-step5.sh`
- `/tmp/memory-extproc-m32/docs/handoff-m3-2.md`
- `/tmp/memory-extproc-m32/docs/migration-v04-to-v05.md`

## 9. 주의사항 / 함정

- `main`에 직접 push 금지. 작업 브랜치는 `codex/m3-openrouter-external-readiness`
- `test-route`는 반드시 `debug.local` 전용이어야 한다
  - drift 나면 external route 대신 `echo-backend`로 빠진다
- `GatewayConfig`에 Redis env 넣지 말 것
  - built-in extproc가 `secret "redis" not found`로 깨진다
- `openrouter-secret` 값 끝의 newline 주의
  - direct header 구성 시 invalid header 값이 됨
- `BackendTLSPolicy` 없으면 `400 The plain HTTP request was sent to HTTPS port`
- direct OpenRouter call은 이미 `200`
  - 그래서 현재 문제는 DNS/egress가 아니라 gateway upstream config 쪽이다

## rate limit / 작업 중단 대응

- OpenRouter `429` 또는 세션 중단 시 먼저 direct call로 provider 상태를 분리한다
  - direct `200`이면 gateway 쪽 문제
  - direct `429`면 provider quota/rate limit 문제
- 재시도 순서
  1. direct OpenRouter call 1회
  2. gateway external call 1회
  3. envoy access log 확인
- 같은 세션에서 반복 호출하지 말고 10~30초 간격으로 재시도
- 중단되면 아래 3개만 먼저 확인하면 된다
  - `kubectl get aigatewayroute ai-route-openai -n default -o jsonpath='{.spec.rules[0].backendRefs[0].name}'`
  - `kubectl get backendtlspolicy -n default openrouter-backend-tls -o yaml`
  - `kubectl logs -n envoy-gateway-system <current-envoy-pod> --tail=120`
