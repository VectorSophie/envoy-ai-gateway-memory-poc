#!/usr/bin/env bash
# port-forward 재시작 스크립트 (setup.sh 실행 후 터미널 재시작 시 사용)

set -euo pipefail

CLUSTER_NAME="ai-gateway-memory-poc"

kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || true

# AI Gateway 서비스 이름 자동 탐색
GW_SVC=$(kubectl get svc -n default \
    -l "gateway.envoyproxy.io/owning-gateway-name=ai-memory-poc" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$GW_SVC" ]]; then
    echo "[Error] Gateway 서비스를 찾지 못했습니다."
    echo "  kubectl get svc -n default 로 서비스 목록 확인 후 수동 실행:"
    echo "  kubectl port-forward -n default svc/<gateway-svc> 8080:80"
    exit 1
fi

echo "[Info] Gateway 서비스: $GW_SVC"
echo "[Info] port-forward 시작 (Ctrl+C로 종료)"
echo ""
echo "  AI Gateway  : http://localhost:8080"
echo "  Memory Svc  : http://localhost:8081"
echo "  API Docs    : http://localhost:8081/docs"
echo ""

# 백그라운드에서 양쪽 포트 포워딩
kubectl port-forward -n default "svc/${GW_SVC}" 8080:80 &
kubectl port-forward -n default svc/memory-service 8081:8080 &

# 두 프로세스 유지
wait
