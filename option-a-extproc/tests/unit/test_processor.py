"""Unit tests for server.py refactoring (Day 3-4).

Focus: pure helpers and JSON handling. gRPC iterator 통합 테스트는 Day 7 verify-*.sh에서 커버.

Run (WSL):
    cd /home/bonjour/memory-extproc
    ./.venv/bin/pytest tests/unit -v
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

# MAX_HISTORY_LENGTH 기본값 사용
import server  # noqa: E402


def test_truncate_history_preserves_when_within_limit():
    msgs = [{"role": "user", "content": f"m{i}"} for i in range(5)]
    assert server._truncate_history(msgs) == msgs


def test_truncate_history_keeps_tail_when_over_limit():
    limit = server.MAX_HISTORY_LENGTH
    msgs = [{"role": "user", "content": f"m{i}"} for i in range(limit + 3)]
    truncated = server._truncate_history(msgs)
    assert len(truncated) == limit
    assert truncated[0]["content"] == "m3"
    assert truncated[-1]["content"] == f"m{limit + 2}"


def test_history_entries_from_messages_keeps_supported_fields():
    entries = server._history_entries_from_messages([
        {"role": "system", "content": "rules"},
        {"role": "user", "content": "hello", "name": "alice"},
        {"role": "tool", "content": "{\"ok\":true}", "tool_call_id": "call-1"},
    ])
    assert entries == [
        {"role": "system", "content": "rules"},
        {"role": "user", "content": "hello", "name": "alice"},
        {"role": "tool", "content": "{\"ok\":true}", "tool_call_id": "call-1"},
    ]


def test_history_entries_from_messages_skips_invalid_items():
    entries = server._history_entries_from_messages([
        None,
        {"role": "assistant"},
        {"content": "missing role"},
        {"role": "user", "content": None},
        {"role": "assistant", "content": "ok"},
    ])
    assert entries == [{"role": "assistant", "content": "ok"}]


def test_redis_client_kwargs_defaults_to_plaintext(monkeypatch):
    monkeypatch.setattr(server, "REDIS_HOST", "redis.local")
    monkeypatch.setattr(server, "REDIS_PORT", 6379)
    monkeypatch.setattr(server, "REDIS_PASSWORD", "pw")
    monkeypatch.setattr(server, "REDIS_TLS_ENABLED", False)
    monkeypatch.setattr(server, "REDIS_TLS_CA_CERT_PATH", "")
    monkeypatch.setattr(server, "REDIS_TLS_CHECK_HOSTNAME", True)

    kwargs = server._redis_client_kwargs()

    assert kwargs["host"] == "redis.local"
    assert kwargs["port"] == 6379
    assert kwargs["password"] == "pw"
    assert kwargs["decode_responses"] is True
    assert "ssl" not in kwargs
    assert "ssl_ca_certs" not in kwargs


def test_redis_client_kwargs_enables_tls(monkeypatch):
    monkeypatch.setattr(server, "REDIS_TLS_ENABLED", True)
    monkeypatch.setattr(server, "REDIS_TLS_CA_CERT_PATH", "/etc/redis-tls/ca.crt")
    monkeypatch.setattr(server, "REDIS_TLS_CHECK_HOSTNAME", False)

    kwargs = server._redis_client_kwargs()

    assert kwargs["ssl"] is True
    assert kwargs["ssl_ca_certs"] == "/etc/redis-tls/ca.crt"
    assert kwargs["ssl_check_hostname"] is False


def test_build_redis_client_uses_computed_kwargs(monkeypatch):
    captured = {}

    def fake_redis(**kwargs):
        captured.update(kwargs)
        return "redis-client"

    monkeypatch.setattr(server, "_redis_client_kwargs", lambda: {"host": "redis.local", "ssl": True})
    monkeypatch.setattr(server.redis, "Redis", fake_redis)

    client = server._build_redis_client()

    assert client == "redis-client"
    assert captured == {"host": "redis.local", "ssl": True}


def test_extract_content_type_detects_sse(monkeypatch):
    class H:
        def __init__(self, k, v):
            self.key = k
            self.raw_value = v.encode("utf-8")
            self.value = ""

    class HeaderMap:
        def __init__(self, headers):
            self.headers = headers

    headers = HeaderMap([H("Content-Type", "text/event-stream; charset=utf-8")])
    ctype = server._extract_content_type(headers)
    assert "text/event-stream" in ctype.lower()


def test_extract_session_id_case_insensitive():
    class H:
        def __init__(self, k, v):
            self.key = k
            self.raw_value = v.encode("utf-8")
            self.value = ""

    class HeaderMap:
        def __init__(self, headers):
            self.headers = headers

    headers = HeaderMap([H("X-Session-ID", "abc-123")])
    assert server._extract_session_id(headers) == "abc-123"


def test_extract_session_id_missing_returns_none():
    class HeaderMap:
        headers = []

    assert server._extract_session_id(HeaderMap()) is None


def test_redis_get_history_fail_degraded(monkeypatch):
    class BrokenRedis:
        def get(self, _key):
            import redis as _r
            raise _r.RedisError("connection refused")

    monkeypatch.setattr(server, "r", BrokenRedis())
    result = server._redis_get_history("any")
    assert result is None  # fail-degraded signal


def test_redis_save_history_fail_degraded(monkeypatch):
    class BrokenRedis:
        def setex(self, *_a, **_kw):
            import redis as _r
            raise _r.RedisError("connection refused")

    monkeypatch.setattr(server, "r", BrokenRedis())
    assert server._redis_save_history("any", [{"role": "user", "content": "x"}]) is False


def test_extract_assistant_content_happy_path():
    raw = json.dumps({
        "choices": [{"message": {"role": "assistant", "content": "hi"}}]
    }).encode("utf-8")
    assert server._extract_assistant_content(raw, "sid") == "hi"


def test_extract_assistant_content_empty_choices_returns_none():
    raw = json.dumps({"choices": []}).encode("utf-8")
    assert server._extract_assistant_content(raw, "sid") is None


def test_extract_assistant_content_non_assistant_role_returns_none():
    raw = json.dumps({
        "choices": [{"message": {"role": "tool", "content": "x"}}]
    }).encode("utf-8")
    assert server._extract_assistant_content(raw, "sid") is None


def test_extract_assistant_content_null_content_returns_none():
    raw = json.dumps({
        "choices": [{"message": {"role": "assistant", "content": None}}]
    }).encode("utf-8")
    assert server._extract_assistant_content(raw, "sid") is None


def test_extract_assistant_content_picks_assistant_when_mixed():
    raw = json.dumps({
        "choices": [
            {"message": {"role": "tool", "content": "skip"}},
            {"message": {"role": "assistant", "content": "take"}},
        ]
    }).encode("utf-8")
    assert server._extract_assistant_content(raw, "sid") == "take"


def test_extract_assistant_content_invalid_json_returns_none():
    assert server._extract_assistant_content(b"not json", "sid") is None


@pytest.mark.parametrize(
    "first_bytes,should_detect_sse",
    [
        (b"data: {\"choices\":[]}\n\n", True),
        (b"event: message\n", True),
        (b"id: 1\n", True),
        (b"{\"choices\":[]}", False),
        (b"", False),
    ],
)
def test_sse_body_prefix_detection(first_bytes, should_detect_sse):
    """response_body 첫 chunk의 prefix 기반 SSE 감지 로직을 고정."""
    detected = any(
        first_bytes.startswith(p) for p in (b"data:", b"event:", b"id:")
    )
    assert detected is should_detect_sse


def test_redis_fail_counter_increments(monkeypatch):
    server._REDIS_FAIL_COUNTER["get"] = 0
    server._REDIS_FAIL_COUNTER["set"] = 0

    class BrokenRedis:
        def get(self, _k):
            import redis as _r
            raise _r.RedisError("boom")

        def setex(self, *_a, **_kw):
            import redis as _r
            raise _r.RedisError("boom")

    monkeypatch.setattr(server, "r", BrokenRedis())
    server._redis_get_history("s1")
    server._redis_get_history("s2")
    server._redis_save_history("s1", [])
    assert server._REDIS_FAIL_COUNTER["get"] == 2
    assert server._REDIS_FAIL_COUNTER["set"] == 1


def test_redis_save_history_serializes_non_ascii(monkeypatch):
    captured = {}

    class RecordingRedis:
        def setex(self, key, ttl, value):
            captured["key"] = key
            captured["ttl"] = ttl
            captured["value"] = value

    monkeypatch.setattr(server, "r", RecordingRedis())
    assert server._redis_save_history("sid", [{"role": "user", "content": "홍길동"}]) is True
    assert captured["key"] == "chat:sid"
    parsed = json.loads(captured["value"])
    assert parsed[0]["content"] == "홍길동"
