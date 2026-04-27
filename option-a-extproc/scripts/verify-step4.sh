#!/usr/bin/env bash
# Step 4 검증 스크립트 — debug.local 디버그 경로 기준 Gate 1-7 자동화.
#
# 전제:
# - Envoy Gateway port-forward가 localhost:28080 으로 열려 있어야 함.
#   예: kubectl port-forward -n envoy-gateway-system \
#         svc/envoy-default-ai-gateway-<hash> 28080:80 &
# - HTTPRoute가 echo-backend로 연결돼 있어야 함 (test-route.yaml).
# - memory-extproc Pod Running, Redis Running.
#
# 실패 시 즉시 exit 1.
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:28080}"
DEBUG_HOST="${DEBUG_HOST:-debug.local}"
REDIS_NS="${REDIS_NS:-ai-gateway-system}"
REDIS_POD="${REDIS_POD:-redis-master-0}"
REDIS_CLI_TLS_ENABLED="${REDIS_CLI_TLS_ENABLED:-auto}"
REDIS_CLI_TLS_CA_CERT_PATH="${REDIS_CLI_TLS_CA_CERT_PATH:-/opt/bitnami/redis/certs/ca.crt}"
SID1="step4-$(date +%s)-A"
SID2="step4-$(date +%s)-B"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

: "${CURRENT_GATE:=unset}"
: "${VERIFY_JSON:=}"  # 비어있지 않으면 structured 결과를 이 경로에 JSON lines로 기록

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
gate() { CURRENT_GATE="$1"; echo; echo "================ $1: $2 ================"; }

redis_pass() {
  kubectl get secret -n "$REDIS_NS" redis -o jsonpath="{.data.redis-password}" | base64 -d
}

redis_cli() {
  local pw; pw="$(redis_pass)"
  local tls_enabled="$REDIS_CLI_TLS_ENABLED"
  if [[ "$tls_enabled" == "auto" ]]; then
    tls_enabled="$(
      kubectl exec -n "$REDIS_NS" "$REDIS_POD" -- printenv REDIS_TLS_ENABLED 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' | tr -d '\r'
    )"
  fi
  local tls_args=()
  if [[ "$tls_enabled" == "yes" || "$tls_enabled" == "true" || "$tls_enabled" == "1" ]]; then
    tls_args=(--tls --cacert "$REDIS_CLI_TLS_CA_CERT_PATH")
  fi
  kubectl exec -it -n "$REDIS_NS" "$REDIS_POD" -- \
    redis-cli "${tls_args[@]}" -a "$pw" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'
}

curl_chat() {
  local sid="$1"; shift
  local body="$1"; shift
  local extra_args=("$@")
  curl -sS -o /tmp/verify-step4-body.json -w "%{http_code}" \
    -X POST "$GATEWAY_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Host: $DEBUG_HOST" \
    -H "x-session-id: $sid" \
    -d "$body" \
    "${extra_args[@]}"
}

gate Gate1 "첫 요청 (저장 검증)"
HTTP_CODE="$(curl_chat "$SID1" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"안녕 나는 홍길동이야"}]}')"
[[ "$HTTP_CODE" == "200" ]] || fail "Gate1: HTTP $HTTP_CODE 수신 (200 기대)"
pass "Gate1: 첫 요청 200 OK (sid=$SID1)"

gate Gate2 "Redis 저장 확인"
VALUE="$(redis_cli GET "chat:$SID1")"
[[ -n "$VALUE" ]] || fail "Gate2: chat:$SID1 Redis key 없음"
pass "Gate2: Redis 저장됨 — value=$VALUE"

TTL="$(redis_cli TTL "chat:$SID1")"
[[ "$TTL" =~ ^[0-9]+$ ]] && (( TTL > 0 )) || fail "Gate2: TTL 비정상 ($TTL)"
pass "Gate2: TTL=$TTL (>0)"

gate Gate3 "두 번째 요청 (병합 검증)"
HTTP_CODE="$(curl_chat "$SID1" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름 뭐야?"}]}')"
[[ "$HTTP_CODE" == "200" ]] || fail "Gate3: HTTP $HTTP_CODE"
pass "Gate3: 두번째 요청 200 OK"

VALUE="$(redis_cli GET "chat:$SID1")"
if echo "$VALUE" | grep -q "홍길동" && echo "$VALUE" | grep -q "내 이름 뭐야"; then
  pass "Gate3: 두 메시지 모두 history에 존재"
else
  fail "Gate3: history에 기대 메시지 누락 — $VALUE"
fi

gate Gate4 "Upstream 전달 검증 (echo backend)"
# echo-server는 응답 body에 원 request body를 그대로 반사한다.
# ExtProc가 merged messages로 body를 교체했는지 curl 응답으로 확인.
RESP="$(cat /tmp/verify-step4-body.json)"
# ealen/echo-server는 request body를 response.request.body에 반사한다.
MESSAGES_COUNT="$(echo "$RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
body = data.get('request', {}).get('body', {})
if isinstance(body, str):
    body = json.loads(body)
messages = body.get('messages', [])
print(len(messages))
")"
[[ "$MESSAGES_COUNT" -ge 2 ]] || fail "Gate4: backend가 받은 messages 수 $MESSAGES_COUNT (>=2 기대)"
pass "Gate4: echo backend가 merged messages 수신 — count=$MESSAGES_COUNT"

gate Gate5 "세션 분리 검증"
curl_chat "$SID2" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"완전 다른 세션이야"}]}' > /dev/null
VALUE_A="$(redis_cli GET "chat:$SID1")"
VALUE_B="$(redis_cli GET "chat:$SID2")"
if echo "$VALUE_B" | grep -q "다른 세션" && ! echo "$VALUE_B" | grep -q "홍길동"; then
  pass "Gate5: $SID1 ↔ $SID2 세션 격리 확인"
else
  fail "Gate5: 세션 교차 오염 — SID2 value=$VALUE_B"
fi

gate Gate6 "multi-turn 누적"
curl_chat "$SID1" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"나는 개발자야"}]}' > /dev/null
curl_chat "$SID1" '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"내 이름과 직업은?"}]}' > /dev/null
VALUE="$(redis_cli GET "chat:$SID1")"
LEN="$(echo "$VALUE" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
[[ "$LEN" -ge 4 ]] || fail "Gate6: multi-turn history 길이 $LEN (>=4 기대)"
pass "Gate6: multi-turn 누적 — length=$LEN"

gate Gate7 "비정상 케이스"
HTTP_NO_HEADER="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$GATEWAY_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Host: $DEBUG_HOST" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"no header"}]}')"
[[ "$HTTP_NO_HEADER" == "400" ]] || fail "Gate7: 헤더 누락 시 $HTTP_NO_HEADER (400 기대)"
pass "Gate7a: x-session-id 누락 시 400 반환"

# Gate 7b: ExtProc가 잘못된 JSON에서 mutation을 생략(fail-open)하고 upstream에 body를 그대로
# 전달하는지 검증. echo-backend가 JSON 아닌 body에 400을 돌려주는 건 별개 문제.
# 따라서 "ExtProc 로그에 fail-open 경고가 남는가"로 검증 기준을 고정한다.
BROKEN_SID="step4-broken-$(date +%s)"
curl -sS -o /dev/null \
  -X POST "$GATEWAY_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Host: $DEBUG_HOST" \
  -H "x-session-id: $BROKEN_SID" \
  -d 'not a json' > /dev/null 2>&1 || true
sleep 1
if kubectl logs -n ai-gateway-system -l app=memory-extproc --tail=20 2>/dev/null \
  | grep -q "fail-open.*session_id=$BROKEN_SID"; then
  pass "Gate7b: 잘못된 JSON에서 ExtProc fail-open 동작 확인"
else
  fail "Gate7b: ExtProc 로그에서 fail-open 메시지 미발견 (session=$BROKEN_SID)"
fi

echo
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✔ Step 4 Gate 1-7 전체 통과${NC}"
echo -e "${GREEN}==================================================${NC}"

# Cleanup
redis_cli DEL "chat:$SID1" > /dev/null || true
redis_cli DEL "chat:$SID2" > /dev/null || true
