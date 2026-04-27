FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .
COPY envoy/api /app/envoy/api

ENV PYTHONPATH=/app/envoy/api
ENV PYTHONUNBUFFERED=1

EXPOSE 50051

CMD ["python", "server.py"]