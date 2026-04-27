import os
from concurrent import futures
import json
import redis

# Envoy protobuf 모듈은 Docker 빌드 이미지에서만 확실히 존재(COPY envoy/api 포함).
# CI의 unit 테스트는 헬퍼만 검증하므로 pb2 모듈이 없어도 파일 import만 성공하면 된다.
# → ImportError 시 None으로 두고 runtime(serve/Process)에서만 필요하도록 lazy하게 사용.
#
# `_PROTOBUF_AVAILABLE=False` 상태에서 허용/금지 범위 (PR #11 리뷰 반영, 명시):
#   허용:  ① 모듈 import            ② 헬퍼 함수 호출(_truncate_history, _extract_*,
#          _redis_*, _immediate_400 중 pb2를 쓰지 않는 것)  ③ pytest unit 수집/실행
#   금지:  ① serve() 호출 — gRPC 서버 기동 불가, RuntimeError로 즉시 실패
#          ② _immediate_400(), ExtProcServicer.Process() 안의 pb2.* 참조 — AttributeError
#          ③ ExtProcServicer 인스턴스화 자체는 가능하나 gRPC에 등록되지 않음
# Docker 이미지에서는 pb2가 항상 available → 위 "금지" 항목 전부 정상 동작.
try:
    import grpc
    from envoy.service.ext_proc.v3 import external_processor_pb2 as pb2
    from envoy.service.ext_proc.v3 import external_processor_pb2_grpc as pb2_grpc
    from envoy.type.v3 import http_status_pb2
    _PROTOBUF_AVAILABLE = True
except ImportError as _e:
    grpc = None  # type: ignore
    pb2 = None  # type: ignore
    pb2_grpc = None  # type: ignore
    http_status_pb2 = None  # type: ignore
    _PROTOBUF_AVAILABLE = False
    _PROTOBUF_IMPORT_ERROR = _e


REDIS_HOST = os.getenv("REDIS_HOST", "redis-master.ai-gateway-system.svc.cluster.local")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")
REDIS_TLS_ENABLED = os.getenv("REDIS_TLS_ENABLED", "false").lower() == "true"
REDIS_TLS_CA_CERT_PATH = os.getenv("REDIS_TLS_CA_CERT_PATH", "")
REDIS_TLS_CHECK_HOSTNAME = os.getenv("REDIS_TLS_CHECK_HOSTNAME", "true").lower() == "true"
MEMORY_TTL_SECONDS = int(os.getenv("MEMORY_TTL_SECONDS", "3600"))
MAX_HISTORY_LENGTH = int(os.getenv("MAX_HISTORY_LENGTH", "20"))


def _redis_client_kwargs():
    kwargs = {
        "host": REDIS_HOST,
        "port": REDIS_PORT,
        "password": REDIS_PASSWORD,
        "decode_responses": True,
        "socket_timeout": 2,
        "socket_connect_timeout": 2,
    }
    if REDIS_TLS_ENABLED:
        kwargs["ssl"] = True
        kwargs["ssl_check_hostname"] = REDIS_TLS_CHECK_HOSTNAME
        if REDIS_TLS_CA_CERT_PATH:
            kwargs["ssl_ca_certs"] = REDIS_TLS_CA_CERT_PATH
    return kwargs


def _build_redis_client():
    return redis.Redis(**_redis_client_kwargs())


r = _build_redis_client()


def _truncate_history(msgs):
    if len(msgs) > MAX_HISTORY_LENGTH:
        return msgs[-MAX_HISTORY_LENGTH:]
    return msgs


def _history_entries_from_messages(messages):
    entries = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if not role:
            continue
        if "content" not in msg or msg.get("content") is None:
            continue
        entry = {"role": role, "content": msg.get("content")}
        if "tool_call_id" in msg:
            entry["tool_call_id"] = msg.get("tool_call_id")
        if "name" in msg:
            entry["name"] = msg.get("name")
        entries.append(entry)
    return entries


_REDIS_FAIL_COUNTER = {"get": 0, "set": 0}


def _redis_get_history(session_id):
    try:
        raw = r.get(f"chat:{session_id}")
    except redis.RedisError as e:
        _REDIS_FAIL_COUNTER["get"] += 1
        print(
            f"⚠️ redis GET failed (fail-degraded) session_id={session_id} "
            f"err={e} fail_count_get={_REDIS_FAIL_COUNTER['get']}",
            flush=True,
        )
        return None
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, list) else []
    except Exception as e:
        print(
            f"⚠️ history decode failed, treating as empty session_id={session_id} err={e}",
            flush=True,
        )
        return []


def _redis_save_history(session_id, history):
    try:
        r.setex(
            f"chat:{session_id}",
            MEMORY_TTL_SECONDS,
            json.dumps(history, ensure_ascii=False),
        )
        return True
    except redis.RedisError as e:
        _REDIS_FAIL_COUNTER["set"] += 1
        print(
            f"⚠️ redis SETEX failed (fail-degraded) session_id={session_id} "
            f"err={e} fail_count_set={_REDIS_FAIL_COUNTER['set']}",
            flush=True,
        )
        return False


def _extract_session_id(header_map):
    for h in header_map.headers:
        if h.key.lower() == "x-session-id":
            if getattr(h, "raw_value", None):
                try:
                    return h.raw_value.decode("utf-8")
                except Exception:
                    return str(h.raw_value)
            if getattr(h, "value", None):
                return h.value
    return None


def _extract_content_type(header_map):
    for h in header_map.headers:
        if h.key.lower() == "content-type":
            if getattr(h, "raw_value", None):
                try:
                    return h.raw_value.decode("utf-8")
                except Exception:
                    return str(h.raw_value)
            if getattr(h, "value", None):
                return h.value
    return ""


def _extract_assistant_content(raw_bytes, session_id):
    """OpenAI chat.completions(stream:false) 응답에서 첫 assistant content 추출.

    리뷰 피드백 반영:
    - `choices[0]` 하드코딩 방어: choices가 비어있거나 role이 assistant가 아닌 경우 스킵.
    - content null-safe: `message.content`가 None/빈 문자열이면 저장하지 않음.
    실패 시 원인·session_id 로그로 추적 가능하게 함.
    """
    try:
        text = raw_bytes.decode("utf-8")
    except Exception as e:
        print(f"⚠️ response_body decode failed session_id={session_id} err={e}", flush=True)
        return None
    try:
        parsed = json.loads(text)
    except Exception as e:
        preview = text[:64] if isinstance(text, str) else ""
        print(
            f"⚠️ response_body json parse failed session_id={session_id} "
            f"err={e} len={len(text)} preview={preview!r}",
            flush=True,
        )
        return None

    choices = parsed.get("choices")
    if not isinstance(choices, list) or not choices:
        print(f"⚠️ assistant save skipped — no choices session_id={session_id}", flush=True)
        return None

    for idx, choice in enumerate(choices):
        if not isinstance(choice, dict):
            continue
        msg = choice.get("message")
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if content is None or content == "":
            print(
                f"⚠️ assistant save skipped — empty content session_id={session_id} "
                f"choice_index={idx} finish_reason={choice.get('finish_reason')}",
                flush=True,
            )
            return None
        return content

    print(
        f"⚠️ assistant save skipped — no assistant-role choice session_id={session_id} "
        f"choices_count={len(choices)}",
        flush=True,
    )
    return None


def _immediate_400(message):
    return pb2.ProcessingResponse(
        immediate_response=pb2.ImmediateResponse(
            status=http_status_pb2.HttpStatus(code=400),
            body=message.encode("utf-8"),
        )
    )


_SERVICER_BASE = pb2_grpc.ExternalProcessorServicer if _PROTOBUF_AVAILABLE else object


class ExtProcServicer(_SERVICER_BASE):  # type: ignore[misc]
    def Process(self, request_iterator, context):
        session_id = None
        history_snapshot = []
        response_buffer = bytearray()
        response_is_sse = False

        for req in request_iterator:
            # 1) request_headers — extract session_id, enforce presence
            if req.HasField("request_headers"):
                try:
                    session_id = _extract_session_id(req.request_headers.headers)
                    if not session_id:
                        print("❌ missing x-session-id header → 400", flush=True)
                        yield _immediate_400("x-session-id header required")
                        return
                    print(f"📌 session_id: {session_id}", flush=True)
                    # Content-Length는 request_body mutation 후 body 길이가 달라지므로 제거.
                    # Envoy는 이를 transfer-encoding: chunked로 재작성한다.
                    yield pb2.ProcessingResponse(
                        request_headers=pb2.HeadersResponse(
                            response=pb2.CommonResponse(
                                header_mutation=pb2.HeaderMutation(
                                    remove_headers=["content-length"]
                                )
                            )
                        )
                    )
                except Exception as e:
                    print(f"❌ request_headers error: {e}", flush=True)
                    raise

            # 2) request_body — merge history + current, CONTINUE_AND_REPLACE, save user msg
            elif req.HasField("request_body"):
                try:
                    try:
                        body = req.request_body.body.decode("utf-8")
                    except Exception:
                        body = str(req.request_body.body)
                    print(f"📨 original request body: {body}", flush=True)

                    try:
                        parsed = json.loads(body)
                    except Exception as e:
                        # 운영 전환 시 민감정보 노출 최소화를 위해 preview는 64자로 제한.
                        # 본격적인 PII 마스킹은 `docs/architecture.md` 결정 5 후속 검토 참고.
                        body_preview = body[:64] if isinstance(body, str) else repr(body)[:64]
                        print(
                            f"⚠️ request_body json parse failed (fail-open): "
                            f"session_id={session_id} err={e} len={len(body) if body else 0} "
                            f"preview={body_preview!r}",
                            flush=True,
                        )
                        yield pb2.ProcessingResponse(
                            request_body=pb2.BodyResponse(response=pb2.CommonResponse())
                        )
                        continue

                    current_messages = parsed.get("messages", [])
                    if not isinstance(current_messages, list):
                        current_messages = []

                    history_snapshot = _redis_get_history(session_id) or []
                    merged = _truncate_history(history_snapshot + current_messages)

                    new_payload = {**parsed, "messages": merged}
                    new_body = json.dumps(new_payload, ensure_ascii=False).encode("utf-8")
                    print(
                        f"🔁 merged messages count: {len(merged)} "
                        f"(history {len(history_snapshot)} + current {len(current_messages)})",
                        flush=True,
                    )
                    print(f"🔁 mutated request body: {new_body.decode('utf-8')}", flush=True)

                    new_history_entries = _history_entries_from_messages(current_messages)
                    if new_history_entries:
                        updated = _truncate_history(history_snapshot + new_history_entries)
                        if _redis_save_history(session_id, updated):
                            history_snapshot = updated
                            print(
                                f"✅ request messages saved (added={len(new_history_entries)} len={len(updated)}) "
                                f"for session {session_id}",
                                flush=True,
                            )

                    yield pb2.ProcessingResponse(
                        request_body=pb2.BodyResponse(
                            response=pb2.CommonResponse(
                                status=pb2.CommonResponse.CONTINUE_AND_REPLACE,
                                body_mutation=pb2.BodyMutation(body=new_body),
                            )
                        )
                    )
                except Exception as e:
                    print(f"❌ request_body error: {e}", flush=True)
                    raise

            # 3) response_headers — detect SSE via content-type
            elif req.HasField("response_headers"):
                try:
                    ctype = _extract_content_type(req.response_headers.headers)
                    if "text/event-stream" in ctype.lower():
                        response_is_sse = True
                        print(f"⚠️ SSE/stream response detected (content-type={ctype}); assistant save skipped (PoC scope)", flush=True)
                    yield pb2.ProcessingResponse(response_headers=pb2.HeadersResponse())
                except Exception as e:
                    print(f"❌ response_headers error: {e}", flush=True)
                    raise

            # 4) response_body — accumulate chunks, on end_of_stream extract assistant and save
            elif req.HasField("response_body"):
                try:
                    chunk = req.response_body.body or b""
                    # SSE 감지 — 2단계(첫 chunk prefix + late-chunk 재감지):
                    # Envoy Gateway EnvoyExtensionPolicy CRD는 response.headers 전달을 노출하지
                    # 않아(body-level fallback), `docs/architecture.md` 결정 4 참조.
                    if not response_is_sse:
                        is_first_chunk = len(response_buffer) == 0
                        if is_first_chunk and (
                            chunk.startswith(b"data:")
                            or chunk.startswith(b"event:")
                            or chunk.startswith(b"id:")
                        ):
                            response_is_sse = True
                            print(
                                f"⚠️ SSE/stream response detected by first-chunk prefix "
                                f"session_id={session_id}; assistant save skipped (PoC scope)",
                                flush=True,
                            )
                        elif not is_first_chunk and b"\ndata:" in chunk:
                            # JSON 응답처럼 보이다가 중간에 SSE event line이 등장하는 드문 케이스.
                            # false positive 가능성 낮지만, 확실하지 않으므로 assistant 저장만
                            # 스킵(누적은 계속)하여 보수적으로 처리.
                            response_is_sse = True
                            print(
                                f"⚠️ SSE pattern detected mid-stream session_id={session_id}; "
                                f"assistant save skipped (late detection)",
                                flush=True,
                            )

                    if not response_is_sse:
                        response_buffer.extend(chunk)
                    end = req.response_body.end_of_stream

                    if end and not response_is_sse and session_id:
                        content = _extract_assistant_content(bytes(response_buffer), session_id)
                        if content is not None:
                            updated = _truncate_history(
                                history_snapshot + [{"role": "assistant", "content": content}]
                            )
                            if _redis_save_history(session_id, updated):
                                history_snapshot = updated
                                print(
                                    f"✅ assistant message saved (len={len(updated)}) for session {session_id}",
                                    flush=True,
                                )

                    yield pb2.ProcessingResponse(response_body=pb2.BodyResponse())
                except Exception as e:
                    print(f"❌ response_body error: {e}", flush=True)
                    raise

            else:
                print("ℹ️ other event received", flush=True)


def serve():
    if not _PROTOBUF_AVAILABLE:
        raise RuntimeError(
            f"Envoy protobuf modules unavailable — cannot start gRPC server. "
            f"Ensure envoy/api is on PYTHONPATH with compiled _pb2.py files. "
            f"(import error: {_PROTOBUF_IMPORT_ERROR})"
        )
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    pb2_grpc.add_ExternalProcessorServicer_to_server(ExtProcServicer(), server)
    server.add_insecure_port("[::]:50051")
    server.start()
    print("🚀 ExtProc server running on :50051", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
