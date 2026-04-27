#!/usr/bin/env bash
# AI Gateway Memory PoC - 전체 환경 구성 스크립트
#
# 실행 전 필요:
#   1. Docker Desktop 실행 중
#   2. kind, helm 설치 (scripts/install-tools.ps1 실행)
#   3. OPENROUTER_API_KEY 환경 변수 설정
#
# 사용:
#   OPENROUTER_API_KEY=sk-or-... bash scripts/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(dirname "$SCRIPT_DIR")"
AI_GW_REPO="$(dirname "$POC_DIR")/ai-gateway"

# .env 파일 자동 로드 (gateway/ 또는 memory-poc/ 에 있으면 읽음)
for env_file in "$POC_DIR/../.env" "$POC_DIR/.env"; do
    if [[ -f "$env_file" ]]; then
        # export KEY=VALUE 형식으로 안전하게 로드 (주석, 빈 줄 제외)
        set -a
        # shellcheck disable=SC1090
        source <(grep -v '^\s*#' "$env_file" | grep -v '^\s*$')
        set +a
        echo "[Info] .env 로드: $env_file"
        break
    fi
done

# ── 버전 핀 ──────────────────────────────────────────────────────────────────
EG_VERSION="v1.6.2"          # Envoy Gateway
AI_GW_VERSION="v0.5.0"       # AI Gateway (v0.5 마이그레이션 대상)
CLUSTER_NAME="ai-gateway-memory-poc"
AI_GW_NAMESPACE="envoy-ai-gateway-system"
EG_NAMESPACE="envoy-gateway-system"

# ─────────────────────────────────────────────────────────────────────────────
info()    { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error()   { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }
# ─────────────────────────────────────────────────────────────────────────────

info "=== AI Gateway Memory PoC 환경 구성 ==="
echo "  Envoy Gateway : $EG_VERSION"
echo "  AI Gateway    : $AI_GW_VERSION"
echo "  클러스터명    : $CLUSTER_NAME"
echo ""

# ── 전제 조건 확인 ────────────────────────────────────────────────────────────
info "전제 조건 확인..."

command -v docker  &>/dev/null || error "docker가 없거나 Docker Desktop이 실행 중이 아닙니다"
command -v kind    &>/dev/null || error "kind가 없습니다. scripts/install-tools.ps1 실행"
command -v kubectl &>/dev/null || error "kubectl이 없습니다"
command -v helm    &>/dev/null || error "helm이 없습니다. scripts/install-tools.ps1 실행"

docker ps &>/dev/null || error "Docker Desktop이 실행 중이 아닙니다. 시작 후 재시도"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    warn "OPENROUTER_API_KEY 미설정. OpenRouter 백엔드는 동작하지 않습니다."
    warn "설정 방법: export OPENROUTER_API_KEY=sk-or-..."
    OPENROUTER_API_KEY="PLACEHOLDER_SET_YOUR_KEY"
fi

success "전제 조건 확인 완료"

# ── Step 1: Kind 클러스터 생성 ────────────────────────────────────────────────
info "Step 1: Kind 클러스터 생성 (K8s 1.32)"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "클러스터 '${CLUSTER_NAME}'이 이미 존재합니다. 건너뜀."
else
    kind create cluster \
        --name "$CLUSTER_NAME" \
        --image kindest/node:v1.32.0 \
        --config "$POC_DIR/k8s/00-kind-config.yaml"
    success "Kind 클러스터 생성 완료"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || \
    kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Step 2: Redis 먼저 배포 (Envoy Gateway rate limit이 Redis 필요) ───────────
info "Step 2: Redis 배포 (rate limit + memory store)"

kubectl apply -f "$POC_DIR/k8s/01-redis.yaml"
kubectl wait --for=condition=available deployment/redis \
    -n redis-system --timeout=120s

success "Redis 준비 완료"

# ── Step 3: Envoy Gateway 설치 (rate limiting 활성화) ────────────────────────
info "Step 3: Envoy Gateway $EG_VERSION 설치"

helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$EG_VERSION" \
    --namespace "$EG_NAMESPACE" \
    --create-namespace \
    --wait --timeout 5m \
    -f "$AI_GW_REPO/manifests/envoy-gateway-values.yaml" \
    -f "$POC_DIR/k8s/envoy-gateway-ratelimit-addon.yaml"

success "Envoy Gateway 설치 완료"

# ── Step 4: AI Gateway v0.5 설치 ─────────────────────────────────────────────
info "Step 4: AI Gateway $AI_GW_VERSION 설치"

helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
    --version "$AI_GW_VERSION" \
    --namespace "$AI_GW_NAMESPACE" \
    --create-namespace \
    --wait --timeout 5m

success "AI Gateway 설치 완료"

# ── Step 5: Docker 이미지 빌드 + Kind 로드 ───────────────────────────────────
info "Step 5: Memory Service 이미지 빌드"

docker build -t ai-gateway-memory-service:latest "$POC_DIR/memory-service/"
kind load docker-image ai-gateway-memory-service:latest --name "$CLUSTER_NAME"

success "Memory Service 이미지 Kind 클러스터에 로드 완료"

info "Step 5b: Memory ExtProc 이미지 빌드 (proto 컴파일 포함, 최초 빌드 시 수분 소요)"

docker build -t memory-extproc:latest "$POC_DIR/extproc/"
kind load docker-image memory-extproc:latest --name "$CLUSTER_NAME"

success "Memory ExtProc 이미지 Kind 클러스터에 로드 완료"

# ── Step 6: K8s 매니페스트 적용 (순서 중요) ──────────────────────────────────
info "Step 6: Gateway 매니페스트 적용"

# 6-1. Gateway 인프라 (GatewayClass, GatewayConfig, EnvoyProxy, Gateway)
kubectl apply -f "$POC_DIR/k8s/02-gateway.yaml"

# 6-2. 백엔드 정의 (Secret에 실제 API 키 주입)
sed "s/OPENROUTER_API_KEY_PLACEHOLDER/${OPENROUTER_API_KEY}/g" \
    "$POC_DIR/k8s/03-backends.yaml" | kubectl apply -f -

# 6-3. 라우팅 규칙 + 토큰 레이트 리밋
kubectl apply -f "$POC_DIR/k8s/04-routes.yaml"

# 6-4. Memory Service (REST API, 관리 명령어용)
kubectl apply -f "$POC_DIR/k8s/05-memory-service.yaml"

# 6-5. Memory ExtProc (gRPC, 게이트웨이 서버사이드 메모리)
kubectl apply -f "$POC_DIR/k8s/06-extproc.yaml"

# 6-6. EnvoyExtensionPolicy (ExtProc ↔ Gateway 바인딩)
kubectl apply -f "$POC_DIR/k8s/07-extproc-policy.yaml"

success "매니페스트 적용 완료"

# ── Step 7: 준비 대기 ─────────────────────────────────────────────────────────
info "Step 7: Pod 준비 대기..."

kubectl wait --for=condition=available deployment/memory-service \
    -n default --timeout=120s

kubectl wait --for=condition=available deployment/memory-extproc \
    -n default --timeout=120s

# Envoy Gateway가 Gateway 리소스에서 Envoy Proxy 파드를 생성할 때까지 대기
echo "  Envoy Proxy 파드 생성 대기 (최대 2분)..."
for i in $(seq 1 24); do
    if kubectl get pods -n default -l "gateway.envoyproxy.io/owning-gateway-name=ai-memory-poc" \
        --no-headers 2>/dev/null | grep -q "Running"; then
        break
    fi
    sleep 5
done

success "모든 컴포넌트 준비 완료"

# ── Step 8: port-forward 시작 ────────────────────────────────────────────────
info "Step 8: port-forward 시작 (백그라운드)"

# Envoy Gateway가 생성한 Gateway 서비스 이름 탐색
GW_SVC=""
for i in $(seq 1 12); do
    GW_SVC=$(kubectl get svc -n default \
        -l "gateway.envoyproxy.io/owning-gateway-name=ai-memory-poc" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$GW_SVC" ]] && break
    sleep 5
done

if [[ -z "$GW_SVC" ]]; then
    warn "Gateway 서비스를 찾지 못했습니다. 수동으로 port-forward를 실행하세요:"
    warn "  kubectl port-forward -n default svc/<gateway-svc> 8080:80"
else
    kubectl port-forward -n default "svc/${GW_SVC}" 8080:80 &
    PF_GW_PID=$!
    success "Gateway port-forward 시작 (PID: $PF_GW_PID)"
fi

kubectl port-forward -n default svc/memory-service 8081:8080 &
PF_MEM_PID=$!
success "Memory Service port-forward 시작 (PID: $PF_MEM_PID)"

sleep 2

# ── 완료 요약 ─────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " AI Gateway Memory PoC 환경 구성 완료!"
echo "======================================================"
echo ""
echo " 엔드포인트 (port-forward 유지 중):"
echo "   AI Gateway   : http://localhost:8080"
echo "   Memory Svc   : http://localhost:8081"
echo "   Memory API   : http://localhost:8081/docs (Swagger UI)"
echo ""
echo " 데모 실행 (새 터미널):"
echo "   cd $(dirname "$POC_DIR")/memory-poc"
echo ""
echo "   # OpenRouter (클라우드)"
echo "   python demo-client/chat.py"
echo ""
echo "   # Ollama (로컬, ollama serve가 실행 중이어야 함)"
echo "   python demo-client/chat.py --backend ollama"
echo ""
echo "   # 기존 세션 재개"
echo "   python demo-client/chat.py --session <session-id>"
echo ""
echo " port-forward 재시작 필요 시:"
echo "   bash scripts/port-forward.sh"
echo ""
echo " 정리:"
echo "   bash scripts/teardown.sh"
echo "======================================================"
echo ""
echo "⚠ 이 터미널을 유지하거나, 새 터미널에서 scripts/port-forward.sh 실행"
