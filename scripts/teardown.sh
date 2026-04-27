#!/usr/bin/env bash
# Kind 클러스터 삭제 (전체 정리)

CLUSTER_NAME="ai-gateway-memory-poc"

echo "[Teardown] 클러스터 '${CLUSTER_NAME}' 삭제 중..."
kind delete cluster --name "$CLUSTER_NAME"
echo "[Done] 정리 완료"
