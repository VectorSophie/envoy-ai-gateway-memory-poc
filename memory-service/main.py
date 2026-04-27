"""
AI Gateway Memory Service
Option B: 외부 메모리 서비스 (클라이언트가 히스토리 조회 → Gateway 호출)

Redis 키 구조:
  memory:session:<session_id>  → JSON 직렬화된 messages 배열
"""

import json
import os
from contextlib import asynccontextmanager
from typing import Optional

import redis.asyncio as aioredis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel


REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
MAX_HISTORY = int(os.getenv("MAX_HISTORY_LENGTH", "20"))
SESSION_TTL = int(os.getenv("SESSION_TTL_SECONDS", "3600"))

redis_client: Optional[aioredis.Redis] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client
    redis_client = aioredis.from_url(REDIS_URL, decode_responses=True)
    yield
    await redis_client.aclose()


app = FastAPI(
    title="AI Gateway Memory Service",
    description="Session-based conversation history for LLM requests (Option B)",
    version="0.1.0",
    lifespan=lifespan,
)


class Message(BaseModel):
    role: str   # "user" | "assistant" | "system"
    content: str


def _session_key(session_id: str) -> str:
    return f"memory:session:{session_id}"


@app.get("/health")
async def health():
    try:
        await redis_client.ping()
        return {"status": "ok", "redis": "connected"}
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {exc}")


@app.get("/sessions")
async def list_sessions():
    """등록된 모든 세션 목록 반환."""
    keys = await redis_client.keys("memory:session:*")
    sessions = [k.replace("memory:session:", "") for k in keys]
    return {"sessions": sessions, "count": len(sessions)}


@app.get("/sessions/{session_id}")
async def get_session(session_id: str):
    """세션의 전체 대화 히스토리 반환. 없으면 빈 배열."""
    raw = await redis_client.get(_session_key(session_id))
    messages = json.loads(raw) if raw else []
    return {
        "session_id": session_id,
        "messages": messages,
        "count": len(messages),
    }


@app.post("/sessions/{session_id}/messages", status_code=201)
async def add_message(session_id: str, message: Message):
    """세션에 메시지 추가. MAX_HISTORY 초과 시 오래된 것부터 제거."""
    key = _session_key(session_id)
    raw = await redis_client.get(key)
    messages: list = json.loads(raw) if raw else []

    messages.append({"role": message.role, "content": message.content})

    # 최대 히스토리 유지 (앞에서 제거 → 최신 N개 보존)
    if len(messages) > MAX_HISTORY:
        messages = messages[-MAX_HISTORY:]

    await redis_client.setex(key, SESSION_TTL, json.dumps(messages, ensure_ascii=False))
    return {"session_id": session_id, "message_count": len(messages)}


@app.delete("/sessions/{session_id}")
async def clear_session(session_id: str):
    """세션 대화 히스토리 삭제."""
    await redis_client.delete(_session_key(session_id))
    return {"session_id": session_id, "status": "cleared"}


@app.post("/sessions/{session_id}/reset")
async def reset_with_system(session_id: str, message: Message):
    """세션 초기화 후 시스템 프롬프트 설정."""
    if message.role != "system":
        raise HTTPException(status_code=400, detail="reset 엔드포인트는 system role만 허용")
    key = _session_key(session_id)
    messages = [{"role": "system", "content": message.content}]
    await redis_client.setex(key, SESSION_TTL, json.dumps(messages, ensure_ascii=False))
    return {"session_id": session_id, "status": "reset", "message_count": 1}


@app.get("/sessions/{session_id}/ttl")
async def get_session_ttl(session_id: str):
    """세션 TTL(남은 초) 반환."""
    ttl = await redis_client.ttl(_session_key(session_id))
    return {"session_id": session_id, "ttl_seconds": ttl}
