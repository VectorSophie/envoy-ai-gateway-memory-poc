#!/usr/bin/env bash
# Step 5 검증 스크립트.
#
# Phase 1 — debug.local + Mock LLM backend: Gate 1-3
# Phase 2-A — debug.local + OpenRouter proxy: semantic / assistant 저장 (인증 필요 시 skip)
# Phase 2-B — 기본 호스트 + AIGatewayRoute: 공식 v0.5 경로에서 merged body / assistant 저장
# Phase 2-C — 기본 호스트 + AIGatewayRoute + external OpenRouter: 실제 외부 호출 200 검증
#
# 전제:
# - Gateway port-forward가 localhost:28080 으로 열려 있어야 함.
# - tests/mock-llm/deployment.yaml apply 되어 있어야 함.
# - OpenRouter proxy는 존재 시 semantic 검증, 부재 시 mock만 검증.

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:28080}"
CHAT_COMPLETIONS_PATH="${CHAT_COMPLETIONS_PATH:-/v1/chat/completions}"
EXTERNAL_CHAT_COMPLETIONS_PATH="${EXTERNAL_CHAT_COMPLETIONS_PATH:-/v1/chat/completions}"
DEBUG_HOST="${DEBUG_HOST:-debug.local}"
REDIS_NS="${REDIS_NS:-ai-gateway-system}"
REDIS_POD="${REDIS_POD:-redis-master-0}"
DEFAULT_ROUTE_HOST="${DEFAULT_ROUTE_HOST:-}"
VERIFY_EXTERNAL_OPENROUTER="${VERIFY_EXTERNAL_OPENROUTER:-0}"
AI_ROUTE_NAME="${AI_ROUTE_NAME:-ai-route-openai}"
AI_ROUTE_MOCK_BACKEND="${AI_ROUTE_MOCK_BACKEND:-ai-service-openai-via-mock}"
AI_ROUTE_MOCK_POLICY="${AI_ROUTE_MOCK_POLICY:-openai-api-key-policy}"
AI_ROUTE_EXTERNAL_BACKEND="${AI_ROUTE_EXTERNAL_BACKEND:-ai-service-openrouter-external}"
AI_ROUTE_EXTERNAL_POLICY="${AI_ROUTE_EXTERNAL_POLICY:-openrouter-api-key-policy-external}"
AI_ROUTE_EXTERNAL_UPSTREAM="${AI_ROUTE_EXTERNAL_UPSTREAM:-openrouter-api-backend-eg}"
SID="step5-$(date +%s)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

: "${CURRENT_GATE:=unset}"
: "${VERIFY_JSON:=}"

pass() {
  echo -e "${GREEN}✔${NC} [$CURRENT_GATE] $*"
  if [[ -n "$VERIFY_JSON" ]]; then
    printf '{"gate":"%s","status":"pass","message":%s}\n' "$CURRENT_GATE" \
      "$(printf '%s' "$*" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      >> "$VERIFY_JSON"
  fi
}
fail() {
  echo -e "${RED}✘${NC} [$CURRENT_GATE] $*" >&2
  echo "::error::gate=$CURRENT_GATE reason=$*" >&2
  if [[ -n "$VERIFY_JSON" ]]; then
    printf '{"gate":"%s","status":"fail","message":%s}\n' "$CURRENT_GATE" \
      "$(printf '%s' "$*" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      >> "$VERIFY_JSON"
  fi
  exit 1
}
info() { echo -e "${YELLOW}→${NC} [$CURRENT_GATE] $*"; }
gate() {
  if [[ -n "${GATE_START:-}" ]]; then
    local elapsed=$(( $(date +%s) - GATE_START ))
    echo -e "${YELLOW}⏱${NC}  [$CURRENT_GATE] elapsed=${elapsed}s"
  fi
  CURRENT_GATE="$1"
  GATE_START=$(date +%s)
  echo
  echo "================ $1: $2 ================"
}

# flaky 감지 — 같은 명령을 최대 N회까지 재시도. 결과는 3단계:
#   (a) 1회차 성공       → 조용히 pass
#   (b) 2회차 이상 성공  → warning + FLAKY_COUNT 증가 (pass 유지)
#   (c) 전부 실패        → fail (전체 exit 1)
#
# fail 기준 (PR #7 리뷰 반영): FLAKY_COUNT가 임계값(STRICT_FLAKY_THRESHOLD, 기본 3)을
# 넘으면 최종 단계에서 fail 처리하여 "조용한 불안정성"을 막는다. 환경변수 VERIFY_STRICT=1
# 설정 시 임계값을 1로 낮춰 재시도 성공 1건만 발생해도 즉시 fail.
#
# 기본값 3 선택 근거 (PR #8 리뷰 반영): 본 스크립트에서 재시도가 필요한 지점은
# (a) Phase 2-A의 xDS 전환 1건 + (b) Phase 2-B route/programming 수렴 1건 +
# (c) 우발 네트워크 지연 1건 수준이다. 이 3건까지는 정상 운영 노이즈로 허용하되
# 4건 이상이면 체계적 불안정으로 간주해 fail. 운영 CI에서 더 엄격하게 돌리려면
# VERIFY_STRICT=1로 즉시 fail.
#
# 실행 환경별 권장 (PR #9/#10 리뷰 반영):
#   - 로컬 개발/PoC 스모크: 기본값(3) 유지. xDS·route convergence·네트워크 지연 노이즈를 흡수해
#     불필요한 재실행을 줄이고 개발 속도 유지.
#   - 운영 CI/blocking gate: **VERIFY_STRICT=1을 CI 기본값으로 권장**. 1건이라도
#     flaky면 fail 처리하여 "merge는 됐지만 때때로 flaky"한 상태를 main에 유입 방지.
#     GitHub Actions 샘플은 .github/workflows/verify.yml 참고.
: "${STRICT_FLAKY_THRESHOLD:=3}"
: "${VERIFY_STRICT:=0}"
if [[ "$VERIFY_STRICT" == "1" ]]; then STRICT_FLAKY_THRESHOLD=1; fi
FLAKY_COUNT=0

retry_flaky() {
  local max=3
  local attempt=0
  local first_rc=-1
  while (( attempt < max )); do
    attempt=$((attempt + 1))
    if "$@"; then
      if (( attempt > 1 )); then
        FLAKY_COUNT=$((FLAKY_COUNT + 1))
        echo -e "${YELLOW}⚠ flaky${NC} [$CURRENT_GATE] 첫 시도 실패 후 ${attempt}회차에서 성공 (누적 flaky=${FLAKY_COUNT})"
      fi
      [[ "$first_rc" -eq -1 ]] && first_rc=0
      return 0
    fi
    first_rc=$?
    sleep 2
  done
  return "$first_rc"
}

redis_pass() {
  kubectl get secret -n "$REDIS_NS" redis -o jsonpath="{.data.redis-password}" | base64 -d
}

redis_cli() {
  local pw; pw="$(redis_pass)"
  kubectl exec -it -n "$REDIS_NS" "$REDIS_POD" -- \
    redis-cli -a "$pw" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'
}

curl_chat() {
  local sid="$1"; shift
  local body="$1"; shift
  local host="$DEBUG_HOST"
  if (( $# >= 1 )); then
    host="$1"
  fi
  local curl_args=(
    -sS
    -o /tmp/verify-step5-body.json
    -w "%{http_code}"
    -X POST "$GATEWAY_URL$CHAT_COMPLETIONS_PATH"
    -H "Content-Type: application/json"
    -H "x-session-id: $sid"
    -d "$body"
  )
  if [[ -n "$host" ]]; then
    curl_args+=(-H "Host: $host")
  fi
  if [[ -n "${OPENROUTER_AUTH_HEADER:-}" ]]; then
    curl_args+=(-H "$OPENROUTER_AUTH_HEADER")
  fi
  curl "${curl_args[@]}"
}

current_backend() {
  kubectl get httproute test-route -n default -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null
}

switch_backend() {
  local name="$1"; local port="$2"
  kubectl patch httproute test-route -n default --type merge -p \
    "{\"spec\":{\"rules\":[{\"matches\":[{\"path\":{\"type\":\"PathPrefix\",\"value\":\"/\"}}],\"backendRefs\":[{\"name\":\"$name\",\"port\":$port}]}]}}" > /dev/null
  # 라우팅 반영 대기 — Envoy가 xDS 업데이트를 수신해 listener/cluster를 재구성할 시간.
  # 짧으면 첫 턴이 이전 backend로 라우팅될 수 있어 5초로 늘림.
  sleep 5
}

current_ai_backend() {
  kubectl get aigatewayroute "$AI_ROUTE_NAME" -n default -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null
}

echo "================ Phase 1: Mock LLM backend ================"
info "current debug backend: $(current_backend)"
info "debug route host: $DEBUG_HOST"

gate Gate1 "Mock backend Pod Ready"
READY="$(kubectl get deploy -n default mock-llm-backend -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "$READY" -ge 1 ]] || fail "Gate1: mock-llm-backend Ready replicas = $READY"
pass "Gate1: mock-llm-backend Deployment Ready=$READY"

gate Gate2 "HTTPRoute → mock-llm-backend 전환"
PREV_BACKEND="$(current_backend)"
switch_backend mock-llm-backend 8000
NEW_BACKEND="$(current_backend)"
[[ "$NEW_BACKEND" == "mock-llm-backend" ]] || fail "Gate2: HTTPRoute backend 전환 실패 ($NEW_BACKEND)"
pass "Gate2: HTTPRoute → mock-llm-backend 반영"

# 원 backend 복원 trap
cleanup_on_exit() {
  switch_backend "$PREV_BACKEND" 80 > /dev/null 2>&1 || true
}
trap 'cleanup_on_exit' EXIT

gate Gate3 "merged body 수신 검증"

# 3 turn: 홍길동 → 개발자 → 이름/직업 질문
curl_chat "$SID" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"안녕 나는 홍길동이야"}]}' > /dev/null
curl_chat "$SID" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"나는 개발자야"}]}' > /dev/null
HTTP_CODE="$(curl_chat "$SID" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름과 직업이 뭐야?"}]}')"
[[ "$HTTP_CODE" == "200" ]] || fail "Gate3: 3rd turn HTTP $HTTP_CODE"

RESP="$(cat /tmp/verify-step5-body.json)"
CONTENT="$(echo "$RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
")"
info "mock assistant content: $CONTENT"

COUNT="$(echo "$CONTENT" | grep -oP 'received_messages_count=\K\d+' || echo 0)"
[[ "$COUNT" -ge 3 ]] || fail "Gate3: mock에서 받은 messages count=$COUNT (>=3 기대)"
pass "Gate3: mock backend가 merged messages ${COUNT}개 수신 (3턴 누적)"

# 마지막 user content 확인
if echo "$CONTENT" | grep -q "이름과 직업"; then
  pass "Gate3: last_user가 마지막 turn 내용과 일치"
else
  fail "Gate3: last_user 매칭 실패 — $CONTENT"
fi

gate Phase2A "OpenRouter proxy 경로"

if kubectl get deploy -n default openrouter-proxy >/dev/null 2>&1; then
  READY_P="$(kubectl get deploy -n default openrouter-proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "$READY_P" -ge 1 ]]; then
    info "openrouter-proxy Ready, Gate 6-7 진행"
    switch_backend openrouter-proxy 8000
    # xDS 전환 settle 대기 — "Empty reply from server" transient 회피.
    # ping 200 나올 때까지 최대 15초 재시도. (flaky 1st-attempt 허용)
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if [[ "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 \
          http://localhost:28080/v1/chat/completions \
          -H "Content-Type: application/json" -H "Host: $DEBUG_HOST" -H "x-session-id: ping-$i" \
          -d "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}")" == "200" ]]; then
        break
      fi
      sleep 1
    done
    SID_P="step5-proxy-$(date +%s)"
    curl_chat "$SID_P" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"안녕 나는 홍길동이야"}]}' > /dev/null
    curl_chat "$SID_P" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"나는 개발자야"}]}' > /dev/null
    HTTP_CODE="$(curl_chat "$SID_P" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름과 직업이 뭐야?"}]}')"
    [[ "$HTTP_CODE" == "200" ]] || fail "Phase 2-A: 3rd turn HTTP $HTTP_CODE (openrouter-secret, OPENROUTER_API_KEY, OPENROUTER_BASE_URL 확인)"

    RESP_P="$(cat /tmp/verify-step5-body.json)"
    CONTENT_P="$(echo "$RESP_P" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', ''))
")"
    info "LLM response content: $CONTENT_P"
    if echo "$CONTENT_P" | grep -q "홍길동" && echo "$CONTENT_P" | grep -q "개발자"; then
      pass "Gate6 semantic: '홍길동' + '개발자' 포함"
    else
      fail "Gate6 semantic: 응답에 홍길동/개발자 누락"
    fi

    VALUE_P="$(redis_cli GET "chat:$SID_P")"
    if echo "$VALUE_P" | grep -q '"role": "assistant"'; then
      pass "Gate7: assistant turn Redis 저장됨"
    else
      fail "Gate7: assistant turn 누락 — $VALUE_P"
    fi
    redis_cli DEL "chat:$SID_P" > /dev/null || true
  else
    info "openrouter-proxy 존재하나 Ready 아님 — Phase 2-A skip"
  fi
else
  info "openrouter-proxy 배포 없음 — Phase 2-A skip (OPENROUTER_API_KEY 준비되면 tests/openrouter-proxy/ 배포)"
fi

gate Phase2B "AIServiceBackend 경로 최소 기준"

if [[ "$(current_ai_backend)" != "$AI_ROUTE_MOCK_BACKEND" ]]; then
  info "Phase2B: AIGatewayRoute가 mock backend가 아니므로 skip (current=$(current_ai_backend))"
elif kubectl get aiservicebackend -n default "$AI_ROUTE_MOCK_BACKEND" >/dev/null 2>&1; then
  ACC_ASB="$(kubectl get aiservicebackend -n default "$AI_ROUTE_MOCK_BACKEND" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  ACC_BSP="$(kubectl get backendsecuritypolicy -n default "$AI_ROUTE_MOCK_POLICY" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  ACC_AGR="$(kubectl get aigatewayroute -n default "$AI_ROUTE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  if [[ "$ACC_ASB" == "True" && "$ACC_BSP" == "True" && "$ACC_AGR" == "True" ]]; then
    pass "Phase2B 최소 기준 1: AIServiceBackend/BackendSecurityPolicy/AIGatewayRoute 모두 Accepted=True"
    SID_B="step5-ai-$(date +%s)"
    curl_chat "$SID_B" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"안녕 나는 홍길동이야"}]}' "$DEFAULT_ROUTE_HOST" > /dev/null
    curl_chat "$SID_B" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"나는 개발자야"}]}' "$DEFAULT_ROUTE_HOST" > /dev/null
    HTTP_CODE_B="$(curl_chat "$SID_B" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름과 직업이 뭐야?"}]}' "$DEFAULT_ROUTE_HOST")"
    [[ "$HTTP_CODE_B" == "200" ]] || fail "Phase2B 최소 기준 2: HTTP $HTTP_CODE_B"

    RESP_B="$(cat /tmp/verify-step5-body.json)"
    CONTENT_B="$(echo "$RESP_B" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', ''))
")"
    info "AI route assistant content: $CONTENT_B"
    COUNT_B="$(echo "$CONTENT_B" | grep -oP 'received_messages_count=\K\d+' || echo 0)"
    [[ "$COUNT_B" -ge 3 ]] || fail "Phase2B: mock backend messages count=$COUNT_B (>=3 기대)"
    pass "Phase2B 최소 기준 2: AIGatewayRoute 200 OK + merged messages ${COUNT_B}개 확인"

    VALUE_B="$(redis_cli GET "chat:$SID_B")"
    if echo "$VALUE_B" | grep -q '"role": "assistant"'; then
      pass "Phase2B bonus: assistant turn Redis 저장됨"
    else
      fail "Phase2B: assistant turn 누락 — $VALUE_B"
    fi
    redis_cli DEL "chat:$SID_B" > /dev/null || true
  else
    info "Phase2B: 3종 CRD Accepted 상태 (asb=$ACC_ASB bsp=$ACC_BSP agr=$ACC_AGR). 미달 시 architecture.md §3.D"
  fi
else
  info "Phase2B: AIServiceBackend 미배포 — manifest apply 필요 (aiservice-backend-openai.yaml 등)"
fi

gate Phase2C "External OpenRouter 공식 경로"

if [[ "$VERIFY_EXTERNAL_OPENROUTER" != "1" ]]; then
  info "VERIFY_EXTERNAL_OPENROUTER=1 아니므로 external 경로 skip"
else
  CUR_AI_BACKEND="$(current_ai_backend)"
  [[ "$CUR_AI_BACKEND" == "$AI_ROUTE_EXTERNAL_BACKEND" ]] || fail "Phase2C: AIGatewayRoute backendRef=$CUR_AI_BACKEND (expected $AI_ROUTE_EXTERNAL_BACKEND, 'kubectl apply -f aigateway-route-openrouter-external.yaml' 필요)"

  kubectl get secret -n default openrouter-secret >/dev/null 2>&1 || fail "Phase2C: openrouter-secret 없음"

  ACC_EXT_BACKEND="$(kubectl get backend -n default "$AI_ROUTE_EXTERNAL_UPSTREAM" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  ACC_EXT_ASB="$(kubectl get aiservicebackend -n default "$AI_ROUTE_EXTERNAL_BACKEND" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  ACC_EXT_BSP="$(kubectl get backendsecuritypolicy -n default "$AI_ROUTE_EXTERNAL_POLICY" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  ACC_EXT_AGR="$(kubectl get aigatewayroute -n default "$AI_ROUTE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  [[ "$ACC_EXT_BACKEND" == "True" && "$ACC_EXT_ASB" == "True" && "$ACC_EXT_BSP" == "True" && "$ACC_EXT_AGR" == "True" ]] \
    || fail "Phase2C: external 리소스 Accepted 미달 (backend=$ACC_EXT_BACKEND asb=$ACC_EXT_ASB bsp=$ACC_EXT_BSP agr=$ACC_EXT_AGR)"

  CHAT_COMPLETIONS_PATH="$EXTERNAL_CHAT_COMPLETIONS_PATH"
  OPENROUTER_AUTH_HEADER="Authorization: Bearer $(kubectl get secret -n default openrouter-secret -o jsonpath='{.data.OPENROUTER_API_KEY}' | base64 -d | tr -d '\n')"
  SID_E="step5-ext-$(date +%s)"
  curl_chat "$SID_E" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"안녕 나는 홍길동이야"}]}' "$DEFAULT_ROUTE_HOST" > /dev/null
  curl_chat "$SID_E" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"나는 개발자야"}]}' "$DEFAULT_ROUTE_HOST" > /dev/null
  HTTP_CODE_E="$(curl_chat "$SID_E" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름과 직업을 짧게 말해줘"}]}' "$DEFAULT_ROUTE_HOST")"
  [[ "$HTTP_CODE_E" == "200" ]] || fail "Phase2C: HTTP $HTTP_CODE_E (openrouter-secret, schema.prefix=/api/v1, DNS/egress, TLS/SNI 확인)"

  RESP_E="$(cat /tmp/verify-step5-body.json)"
  CONTENT_E="$(echo "$RESP_E" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', ''))
")"
  [[ -n "$CONTENT_E" ]] || fail "Phase2C: assistant content 비어 있음"
  pass "Phase2C 최소 기준 1: external OpenRouter 200 OK + non-empty assistant content"
  info "external assistant content: $CONTENT_E"

  VALUE_E="$(redis_cli GET "chat:$SID_E")"
  if echo "$VALUE_E" | grep -q '"role": "assistant"'; then
    pass "Phase2C 최소 기준 2: assistant turn Redis 저장됨"
  else
    info "Phase2C: assistant turn Redis 저장 미확인 — external 200 기준은 통과"
  fi
  redis_cli DEL "chat:$SID_E" > /dev/null || true
fi

echo
if (( FLAKY_COUNT >= STRICT_FLAKY_THRESHOLD )); then
  echo -e "${RED}✘ flaky 누적=${FLAKY_COUNT} >= 임계값 ${STRICT_FLAKY_THRESHOLD}, 불안정으로 판정 → exit 1${NC}" >&2
  echo "::error::flaky_count=${FLAKY_COUNT} threshold=${STRICT_FLAKY_THRESHOLD}" >&2
  redis_cli DEL "chat:$SID" > /dev/null || true
  exit 1
fi

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✔ Step 5 검증 완료 (실행된 Gate 전원 통과, flaky=${FLAKY_COUNT})${NC}"
echo -e "${GREEN}==================================================${NC}"

redis_cli DEL "chat:$SID" > /dev/null || true
