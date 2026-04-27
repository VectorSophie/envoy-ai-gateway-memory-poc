#!/usr/bin/env python3
"""
AI Gateway Memory PoC - 인터랙티브 데모 클라이언트
통합 아키텍처 (Option A + B)

흐름:
  1. AI Gateway로 POST (x-session-id 헤더 포함, 현재 메시지만)
  2. Gateway 내 ExtProc이 Redis에서 히스토리 조회 → 자동 병합 (투명)
  3. AI Gateway BodyMutation: stream=false, max_tokens 강제 적용
  4. ExtProc이 assistant 응답을 Redis에 자동 저장

  * Memory Service REST API는 /clear, /history, /system 관리 명령어에만 사용
  * 클라이언트는 히스토리를 직접 관리하지 않음

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

# .env 파일 자동 로드
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
        "model": "google/gemma-3-4b-it:free",
        "display": "OpenRouter (google/gemma-3-4b-it:free)",
    },
    "ollama": {
        # "ollama/" 접두사 → AIServiceBackend BodyMutation이 제거
        "model": "ollama/llama3.2",
        "display": "Ollama 로컬 (llama3.2)",
    },
}


# ─── Memory Service 헬퍼 (관리 명령어 전용) ───────────────────────────────────

def fetch_history(session_id: str) -> list[dict]:
    """히스토리 조회 (/history 슬래시 명령어용)."""
    try:
        r = httpx.get(f"{MEMORY_URL}/sessions/{session_id}", timeout=5)
        r.raise_for_status()
        return r.json()["messages"]
    except Exception as e:
        print(f"  ⚠ [Memory] 히스토리 조회 실패: {e}")
        return []


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

    # Gateway ExtProc이 x-session-id 기반으로 Redis 히스토리를 자동 주입
    # 클라이언트는 현재 메시지만 전송
    payload = {"model": model, "messages": [{"role": "user", "content": user_input}]}
    headers = {
        "x-ai-eg-model": model,       # 라우팅 결정
        "x-session-id": session_id,   # ExtProc이 메모리 키로 사용
        "x-tenant-id": tenant_id,     # 토큰 레이트 리밋 버짓 키
        "Content-Type": "application/json",
    }

    print(f"\n  → [ExtProc] 세션 {session_id[:8]}... 히스토리 자동 주입 (Gateway 내부)")
    print(f"  → [Gateway] 전송 (backend: {backend})")

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

    # 저장은 ExtProc이 자동으로 처리 (클라이언트 불필요)
    print(f"  ✓ [ExtProc] 저장 완료 (Gateway 내부 자동 처리)")

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
    print("  AI Gateway Memory PoC — 통합 (Option A + B)")
    print("  ExtProc 서버사이드 메모리 + Body Mutation + 토큰 레이트 리밋")
    print("=" * 65)
    print(f"  백엔드  : {BACKENDS[backend]['display']}")
    print(f"  세션 ID : {session_id}")
    print(f"  테넌트  : {tenant_id}")
    print(f"  Gateway : {GATEWAY_URL}")
    print(f"  Memory  : {MEMORY_URL}  (관리 명령어 전용)")
    print()
    print("  명령어: /clear  /history  /system <prompt>  /session  /quit")
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

        response = chat(session_id, user_input, backend, tenant_id)
        print(f"\nAssistant: {response}")


if __name__ == "__main__":
    main()
