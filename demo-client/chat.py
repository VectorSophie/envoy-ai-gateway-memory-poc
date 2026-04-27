#!/usr/bin/env python3
"""
AI Gateway Memory PoC - 인터랙티브 데모 클라이언트
Option B: 클라이언트 사이드 메모리 관리

흐름:
  1. Memory Service에서 세션 히스토리 조회
  2. 히스토리 + 새 메시지 → 전체 messages 배열 구성
  3. AI Gateway로 POST (Body Mutation이 stream=false, max_tokens 강제 적용)
  4. 응답을 Memory Service에 저장

사용:
  python chat.py                           # 기본 (OpenRouter)
  python chat.py --backend ollama          # 로컬 Ollama
  python chat.py --session my-session      # 기존 세션 재개
  GATEWAY_URL=http://... python chat.py    # 커스텀 주소
"""

import argparse
import json
import os
import sys
import uuid
from pathlib import Path

try:
    import httpx
except ImportError:
    print("[Error] httpx가 없습니다. 설치: pip install httpx")
    sys.exit(1)

# .env 파일 자동 로드 (demo-client/../.. 또는 직접 경로)
def _load_env():
    candidates = [
        Path(__file__).parent.parent.parent / ".env",  # gateway/.env
        Path(__file__).parent.parent / ".env",          # memory-poc/.env
    ]
    for p in candidates:
        if p.exists():
            for line in p.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    os.environ.setdefault(k.strip(), v.strip())
            break

_load_env()

GATEWAY_URL = os.getenv("GATEWAY_URL", "http://localhost:8080")
MEMORY_URL = os.getenv("MEMORY_URL", "http://localhost:8081")

BACKENDS = {
    "openrouter": {
        # x-ai-eg-model 헤더 값 (라우팅 + OpenRouter body model 필드로 전달)
        "model": "google/gemma-3-4b-it:free",
        "display": "OpenRouter (google/gemma-3-4b-it:free)",
    },
    "ollama": {
        # "ollama/" 접두사 → AIServiceBackend BodyMutation이 제거
        "model": "ollama/llama3.2",
        "display": "Ollama 로컬 (llama3.2)",
    },
}


# ─── Memory Service 헬퍼 ──────────────────────────────────────────────────────

def fetch_history(session_id: str) -> list[dict]:
    try:
        r = httpx.get(f"{MEMORY_URL}/sessions/{session_id}", timeout=5)
        r.raise_for_status()
        return r.json()["messages"]
    except Exception as e:
        print(f"  ⚠ [Memory] 히스토리 조회 실패: {e}")
        return []


def save_message(session_id: str, role: str, content: str) -> None:
    try:
        r = httpx.post(
            f"{MEMORY_URL}/sessions/{session_id}/messages",
            json={"role": role, "content": content},
            timeout=5,
        )
        r.raise_for_status()
    except Exception as e:
        print(f"  ⚠ [Memory] 저장 실패: {e}")


def clear_session(session_id: str) -> None:
    try:
        httpx.delete(f"{MEMORY_URL}/sessions/{session_id}", timeout=5)
    except Exception as e:
        print(f"  ⚠ [Memory] 삭제 실패: {e}")


def set_system_prompt(session_id: str, prompt: str) -> None:
    try:
        r = httpx.post(
            f"{MEMORY_URL}/sessions/{session_id}/reset",
            json={"role": "system", "content": prompt},
            timeout=5,
        )
        r.raise_for_status()
        print(f"  ✓ [Memory] 시스템 프롬프트 설정됨")
    except Exception as e:
        print(f"  ⚠ [Memory] 시스템 프롬프트 설정 실패: {e}")


# ─── AI Gateway 호출 ──────────────────────────────────────────────────────────

def chat(session_id: str, user_input: str, backend: str, tenant_id: str) -> str:
    model = BACKENDS[backend]["model"]

    # Step 1: 히스토리 조회
    print(f"\n  → [Memory] 세션 {session_id[:8]}... 히스토리 조회 중...")
    history = fetch_history(session_id)
    print(f"     {len(history)}개 메시지 로드됨")

    # Step 2: 전체 messages 배열 구성 (Option B 핵심)
    messages = history + [{"role": "user", "content": user_input}]

    # Step 3: AI Gateway 호출
    # Gateway가 BodyMutation으로 stream=false, max_tokens 강제 적용
    print(f"  → [Gateway] {len(messages)}개 메시지 전송 (backend: {backend})")
    payload = {"model": model, "messages": messages}
    headers = {
        "x-ai-eg-model": model,       # 라우팅 결정에 사용
        "x-session-id": session_id,   # 로깅/추적용
        "x-tenant-id": tenant_id,     # 토큰 레이트 리밋 버짓 키
        "Content-Type": "application/json",
    }

    try:
        resp = httpx.post(
            f"{GATEWAY_URL}/v1/chat/completions",
            json=payload,
            headers=headers,
            timeout=120,
        )
        resp.raise_for_status()
    except httpx.HTTPStatusError as e:
        return f"[Error {e.response.status_code}] {e.response.text[:300]}"
    except httpx.TimeoutException:
        return "[Error] 요청 타임아웃 (120초 초과)"
    except Exception as e:
        return f"[Error] {e}"

    data = resp.json()
    assistant_content = data["choices"][0]["message"]["content"]

    # Step 4: 양쪽 메시지 저장
    save_message(session_id, "user", user_input)
    save_message(session_id, "assistant", assistant_content)
    print(f"  ✓ [Memory] 저장 완료 (총 {len(messages) + 1}개)")

    # 토큰 사용량 출력 (있을 경우)
    usage = data.get("usage", {})
    if usage:
        print(f"  ℹ [Tokens] in={usage.get('prompt_tokens',0)} "
              f"out={usage.get('completion_tokens',0)} "
              f"total={usage.get('total_tokens',0)}")

    return assistant_content


# ─── CLI ─────────────────────────────────────────────────────────────────────

def print_banner(backend: str, session_id: str, tenant_id: str):
    print()
    print("=" * 65)
    print("  AI Gateway Memory PoC — Option B")
    print("  Body Mutation + External Memory Service")
    print("=" * 65)
    print(f"  백엔드  : {BACKENDS[backend]['display']}")
    print(f"  세션 ID : {session_id}")
    print(f"  테넌트  : {tenant_id}")
    print(f"  Gateway : {GATEWAY_URL}")
    print(f"  Memory  : {MEMORY_URL}")
    print()
    print("  명령어: /clear  /history  /system <prompt>  /quit")
    print("-" * 65)


def show_history(session_id: str):
    history = fetch_history(session_id)
    if not history:
        print("  (히스토리 없음)")
        return
    print(f"\n  ── 히스토리 ({len(history)}개) ──")
    for i, msg in enumerate(history, 1):
        preview = msg["content"][:100].replace("\n", " ")
        print(f"  {i}. [{msg['role']:9s}] {preview}{'...' if len(msg['content']) > 100 else ''}")


def main():
    parser = argparse.ArgumentParser(description="AI Gateway Memory PoC 데모 클라이언트")
    parser.add_argument(
        "--backend", choices=["openrouter", "ollama"], default="openrouter",
        help="사용할 백엔드 (기본: openrouter)"
    )
    parser.add_argument(
        "--session", default=None,
        help="세션 ID (기본: 새 UUID 생성)"
    )
    parser.add_argument(
        "--tenant", default="demo",
        help="테넌트 ID for 레이트 리밋 (기본: demo)"
    )
    args = parser.parse_args()

    backend = args.backend
    session_id = args.session or str(uuid.uuid4())
    tenant_id = args.tenant

    print_banner(backend, session_id, tenant_id)

    while True:
        try:
            user_input = input("\nYou: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n\n안녕히 가세요!")
            break

        if not user_input:
            continue

        # 슬래시 명령어 처리
        if user_input == "/quit":
            print("안녕히 가세요!")
            break

        if user_input == "/clear":
            clear_session(session_id)
            print(f"  ✓ [Memory] 세션 초기화 완료")
            continue

        if user_input == "/history":
            show_history(session_id)
            continue

        if user_input.startswith("/system "):
            prompt = user_input[8:].strip()
            if prompt:
                set_system_prompt(session_id, prompt)
            continue

        if user_input == "/session":
            print(f"  세션 ID: {session_id}")
            continue

        # 일반 채팅
        response = chat(session_id, user_input, backend, tenant_id)
        print(f"\nAssistant: {response}")


if __name__ == "__main__":
    main()
