# ── Stage 1: Envoy ExtProc proto 컴파일 ─────────────────────────────────────
FROM python:3.12-slim AS proto-builder

RUN apt-get update && apt-get install -y git --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir grpcio-tools==1.80.0 protobuf==6.33.6

# Envoy API protos (sparse clone)
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/envoyproxy/envoy.git /envoy && \
    cd /envoy && git sparse-checkout set api

# udpa annotations (cncf/xds)
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/cncf/xds.git /xds && \
    cd /xds && git sparse-checkout set udpa xds

# validate protos (bufbuild/protoc-gen-validate)
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/bufbuild/protoc-gen-validate.git /pgv && \
    cd /pgv && git sparse-checkout set validate

# 전체 proto 컴파일 (transitive deps 포함)
RUN mkdir -p /pb && \
    find /envoy/api /xds/udpa /pgv/validate -name "*.proto" 2>/dev/null | \
    xargs python -m grpc_tools.protoc \
        -I /envoy/api \
        -I /xds \
        -I /pgv \
        --python_out=/pb \
        --grpc_python_out=/pb 2>/dev/null; \
    echo "Proto compilation complete"

# ── Stage 2: 런타임 ───────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --from=proto-builder /pb/ /app/proto/
COPY server.py .

ENV PYTHONPATH=/app/proto
ENV PYTHONUNBUFFERED=1

EXPOSE 50051

CMD ["python", "server.py"]
