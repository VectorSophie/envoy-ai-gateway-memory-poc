"""OpenRouter proxy — Step 5 Phase 2-A semantic 검증용.

클러스터 내부에서 OpenAI SDK를 OpenRouter base URL로 고정해 호출한다.
ExtProc가 주입한 messages가 실제 모델 응답을 변화시키는지(semantic 검증)를 본다.
"""

import os

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from openai import OpenAI

app = FastAPI()
# `OPENROUTER_BASE_URL`을 우선 사용하고, 미지정 시 공식 OpenRouter API base를 기본값으로 둔다.
client = OpenAI(
    api_key=os.environ["OPENROUTER_API_KEY"],
    base_url=os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
)


@app.post("/v1/chat/completions")
async def chat(req: Request):
    body = await req.json()
    print("=== OPENROUTER PROXY RECEIVED BODY ===", flush=True)
    print(body, flush=True)

    body.pop("stream", None)

    try:
        resp = client.chat.completions.create(
            model=body.get("model", "gpt-4o-mini"),
            messages=body.get("messages", []),
            stream=False,
        )
    except Exception as e:
        print(f"❌ openrouter call failed: {e}", flush=True)
        return JSONResponse(status_code=502, content={"error": str(e)})

    return JSONResponse(resp.model_dump())


@app.get("/healthz")
async def health():
    return {"status": "ok"}
