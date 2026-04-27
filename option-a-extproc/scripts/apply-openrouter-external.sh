#!/usr/bin/env bash
# External OpenRouter 경로 전환용 적용 스크립트.
# AI Gateway extproc 입력 경로는 /v1을 유지하고, upstream OpenRouter에는 /api/v1로 전달한다.

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
AI_ROUTE_NAME="${AI_ROUTE_NAME:-ai-route-openai}"
FILTER_NAME="${FILTER_NAME:-}"
ALLOW_PROD_CONTEXT="${ALLOW_PROD_CONTEXT:-0}"
BLOCKED_CONTEXT_REGEX="${BLOCKED_CONTEXT_REGEX:-prod|production}"
REWRITE_PATTERN='^/v1/(.*)$'
REWRITE_SUBSTITUTION='/api/v1/\1'

log() {
  echo "[apply-openrouter] $*"
}

current_context="$(kubectl config current-context)"
if [[ "$ALLOW_PROD_CONTEXT" != "1" && "$current_context" =~ $BLOCKED_CONTEXT_REGEX ]]; then
  echo "[apply-openrouter] 중단: 현재 kubectl context '$current_context'가 차단 패턴 '$BLOCKED_CONTEXT_REGEX'와 일치합니다." >&2
  echo "[apply-openrouter] 계속하려면 ALLOW_PROD_CONTEXT=1을 명시하세요." >&2
  exit 1
fi
log "kubectl context: $current_context"

kubectl apply -f aiservice-backend-openrouter-external.yaml
kubectl apply -f backend-security-policy-openrouter-external.yaml
kubectl apply -f backend-tls-policy-openrouter-external.yaml
kubectl apply set-last-applied -f aigateway-route-openrouter-external.yaml --create-annotation=true >/dev/null
kubectl apply -f aigateway-route-openrouter-external.yaml

if [[ -z "$FILTER_NAME" ]]; then
  FILTER_NAME="$(
    kubectl get httproutefilter -n "$NAMESPACE" -o json \
      | python3 -c '
import json, sys

data = json.load(sys.stdin)
route_name = sys.argv[1]
matches = []
for item in data.get("items", []):
    owner_refs = item.get("metadata", {}).get("ownerReferences", [])
    owned_by_route = any(
        ref.get("kind") == "AIGatewayRoute" and ref.get("name") == route_name
        for ref in owner_refs
    )
    if owned_by_route and "urlRewrite" in item.get("spec", {}):
        matches.append(item.get("metadata", {}).get("name", ""))

matches = [name for name in matches if name]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one generated host rewrite HTTPRouteFilter for {route_name}, found {matches}")
print(matches[0])
' "$AI_ROUTE_NAME"
  )"
fi
log "대상 HTTPRouteFilter: $FILTER_NAME"

set +e
rewrite_state="$(
  kubectl get httproutefilter "$FILTER_NAME" -n "$NAMESPACE" -o json \
    | python3 -c '
import json, sys

item = json.load(sys.stdin)
rewrite = item.get("spec", {}).get("urlRewrite", {})
path = rewrite.get("path", {})
regex = path.get("replaceRegexMatch", {})

expected = {
    "host_type": "Backend",
    "path_type": "ReplaceRegexMatch",
    "pattern": sys.argv[1],
    "substitution": sys.argv[2],
}
actual = {
    "host_type": rewrite.get("hostname", {}).get("type", ""),
    "path_type": path.get("type", ""),
    "pattern": regex.get("pattern", ""),
    "substitution": regex.get("substitution", ""),
}

print(
    "host={host_type} path_type={path_type} pattern={pattern} substitution={substitution}".format(
        **actual
    )
)
if actual == expected:
    raise SystemExit(0)
raise SystemExit(1)
' "$REWRITE_PATTERN" "$REWRITE_SUBSTITUTION"
)"
rewrite_rc=$?
set -e

if [[ "$rewrite_rc" -eq 0 ]]; then
  log "path rewrite already configured on $FILTER_NAME; skip ($rewrite_state)"
  exit 0
fi
log "path rewrite needs patch on $FILTER_NAME; current state: $rewrite_state"

kubectl patch httproutefilter "$FILTER_NAME" -n "$NAMESPACE" --type merge -p \
  '{"spec":{"urlRewrite":{"hostname":{"type":"Backend"},"path":{"type":"ReplaceRegexMatch","replaceRegexMatch":{"pattern":"^/v1/(.*)$","substitution":"/api/v1/\\1"}}}}}'

log "path rewrite configured on $FILTER_NAME"
