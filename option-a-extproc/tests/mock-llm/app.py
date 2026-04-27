"""Mock LLM backend — Step 5 Phase 1에서 assistant 응답 패턴을 고정 검증하기 위한 목.

OpenAI chat.completions 형식의 JSON 응답을 반환한다. assistant content는
ExtProc로부터 전달된 messages 개수와 마지막 user content를 echo 하여 memory
파이프라인이 실제로 upstream까지 merged messages를 넘겼는지 확인할 수 있게 한다.
"""

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()


@app.post("/v1/chat/completions")
async def chat(req: Request):
    body = await req.json()
    messages = body.get("messages", [])
    last_user = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_user = m.get("content", "")
            break

    print("=== MOCK LLM RECEIVED BODY ===", flush=True)
    print(body, flush=True)

    return JSONResponse(
        {
            "id": "mock-cmpl-1",
            "object": "chat.completion",
            "model": body.get("model", "mock-llm"),
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": f"received_messages_count={len(messages)}; last_user={last_user}",
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
    )


@app.get("/healthz")
async def health():
    return {"status": "ok"}
