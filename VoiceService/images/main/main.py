"""Voice dictation service.

Expose a /dictate endpoint that accepts a WAV audio file and application
context, and returns polished text ready for injection. If cleanup fails,
the raw transcription is returned as fallback.

Expose a /stream WebSocket endpoint that streams audio to the OpenAI
Realtime API for real-time transcription. The VoiceService manages its
own Realtime API session (like voice.py's VoiceSession) rather than
bridging WebSocket frames. The transcript is available the moment speech
ends, then cleaned up via LLM before returning to the client.

Expose a /cleanup endpoint that accepts raw transcript text and context,
and returns polished text. This is the compose_text function exposed as
a standalone HTTP endpoint.
"""

import asyncio
import base64
import json
import os
import struct
import time
import traceback

from dataclasses import dataclass
from typing import Optional

from autonomy import HttpServer, Model, Node
from autonomy.models.clients.gateway_config import (
    get_gateway_url,
    get_gateway_api_key,
    get_client_metadata_headers,
    clear_token_cache,
)
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

try:
    import websockets
except ImportError:
    websockets = None

app = FastAPI()
security = HTTPBearer()

API_KEY = os.environ.get("API_KEY", "")


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Verify the bearer token matches the configured API key."""
    if not API_KEY:
        raise HTTPException(status_code=500, detail="Server API key not configured")
    if credentials.credentials != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return credentials


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

STT_MODEL = "gpt-4o-mini-transcribe"
REALTIME_MODEL = "gpt-4o-realtime-preview"
COMPOSE_MODEL = "gpt-4.1-nano"


# ---------------------------------------------------------------------------
# Composition prompt
# ---------------------------------------------------------------------------


COMPOSE_SYSTEM_PROMPT = """\
You are a voice-to-text cleanup assistant. The user dictated text and a \
speech-to-text engine transcribed it. Your job is to clean up the \
transcription into polished written text.

Speech-to-text engines produce messy output. Fix these problems:

1. Filler words and false starts: remove "um", "uh", "like", "you know", \
"I mean", and similar verbal fillers.
2. Repetitions: "I think I think we should" becomes "I think we should".
3. Mid-sentence corrections: when the speaker restarts or says "no wait", \
"actually", "I mean", or "sorry", keep only the corrected version. \
For example "send it to John no wait send it to Sarah" becomes \
"send it to Sarah".
4. Punctuation and capitalization: add proper sentence punctuation, \
capitalize sentence starts, and fix obvious capitalization (proper \
nouns, "I", etc.).
5. Lists: when the speaker dictates items in sequence ("first X second Y \
third Z" or "one X two Y three Z"), format as a list.
6. Numbers and formatting: "twenty three point five percent" becomes \
"23.5%", "twelve dollars" becomes "$12", etc.
7. Dictated punctuation: "period", "comma", "question mark", \
"exclamation point", "new line", "new paragraph" should be converted \
to the actual punctuation or whitespace.

Preserve the user's meaning exactly. Do not add content, opinions, or \
rephrase beyond cleanup. If the transcription is already clean, return \
it unchanged.

Do not wrap your output in quotes or add any preamble. Return only the \
cleaned text.

Keep the same language as the transcription. Do not translate.

You may also receive context about the target application (app name, \
window title, field content). Use it as a light signal for tone: \
keep email formal, chat casual, code comments technical. But do not \
over-adapt. The cleanup rules above are the priority.
"""


@dataclass
class AppContext:
    """Application context captured at the moment of dictation."""

    bundle_id: str = ""
    app_name: str = ""
    window_title: str = ""
    browser_url: Optional[str] = None
    focused_field_content: Optional[str] = None
    selected_text: Optional[str] = None
    cursor_position: Optional[int] = None


def build_compose_prompt(text: str, context: AppContext) -> str:
    """Build the user prompt for the composition LLM call."""
    parts = [f"Transcription:\n{text}"]

    ctx_lines = []
    if context.app_name:
        ctx_lines.append(f"App: {context.app_name}")
    if context.window_title:
        ctx_lines.append(f"Window: {context.window_title}")
    if context.browser_url:
        ctx_lines.append(f"URL: {context.browser_url}")
    if context.focused_field_content is not None:
        # Show a truncated view of the field content around the cursor to
        # keep the prompt compact while giving the model enough context.
        content = context.focused_field_content
        if len(content) > 2000:
            original_len = len(content)
            pos = context.cursor_position or original_len
            start = max(0, pos - 1000)
            end = min(original_len, pos + 1000)
            content = content[start:end]
            if start > 0:
                content = "..." + content
            if end < original_len:
                content = content + "..."
        ctx_lines.append(f"Field content:\n{content}")
    if context.cursor_position is not None:
        ctx_lines.append(f"Cursor position: {context.cursor_position}")
    if context.selected_text:
        ctx_lines.append(f"Selected text: {context.selected_text}")

    if ctx_lines:
        parts.append("Context:\n" + "\n".join(ctx_lines))

    return "\n\n".join(parts)


async def compose_text(raw_text: str, context: AppContext) -> str:
    """Refine raw transcription via LLM. Return raw text on failure."""
    trimmed = raw_text.strip()
    if not trimmed:
        return raw_text

    llm = Model(COMPOSE_MODEL)
    user_prompt = build_compose_prompt(trimmed, context)
    messages = [
        {"role": "system", "content": COMPOSE_SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]

    try:
        response = await llm.complete_chat(messages, stream=False)
        if hasattr(response, "choices") and len(response.choices) > 0:
            composed = response.choices[0].message.content.strip()
            if composed:
                return composed
    except Exception as e:
        print(f"[compose] LLM composition failed, using raw transcription: {e}")

    return trimmed


# ---------------------------------------------------------------------------
# Context parsing
# ---------------------------------------------------------------------------


def parse_context(raw: str) -> AppContext:
    """Parse a JSON string into an AppContext, returning empty on failure."""
    if not raw:
        return AppContext()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return AppContext()
    if not isinstance(data, dict):
        return AppContext()
    return AppContext(
        bundle_id=data.get("bundle_id", ""),
        app_name=data.get("app_name", ""),
        window_title=data.get("window_title", ""),
        browser_url=data.get("browser_url"),
        focused_field_content=data.get("focused_field_content"),
        selected_text=data.get("selected_text"),
        cursor_position=data.get("cursor_position"),
    )


def parse_context_dict(data: Optional[dict]) -> AppContext:
    """Parse a dict into an AppContext, returning empty on failure."""
    if not data or not isinstance(data, dict):
        return AppContext()
    return AppContext(
        bundle_id=data.get("bundle_id", ""),
        app_name=data.get("app_name", ""),
        window_title=data.get("window_title", ""),
        browser_url=data.get("browser_url"),
        focused_field_content=data.get("focused_field_content"),
        selected_text=data.get("selected_text"),
        cursor_position=data.get("cursor_position"),
    )


# ---------------------------------------------------------------------------
# Dictate (STT + composition in one call)
# ---------------------------------------------------------------------------


@app.post("/dictate")
async def dictate(
    file: UploadFile = File(...),
    context: str = Form("{}"),
    language: Optional[str] = Form(None),
    _credentials=Depends(verify_token),
):
    """Convert spoken audio into clean written text.

    Accept a WAV audio file and application context. Return polished
    text ready for injection. The raw transcription is also included
    for logging.
    """
    t0 = time.monotonic()

    audio_bytes = await file.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file")

    model = Model(STT_MODEL)
    try:
        raw_text = await model.speech_to_text(
            audio_file=("recording.wav", audio_bytes),
            language=language,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Transcription failed: {e}")

    t1 = time.monotonic()

    if not raw_text or not raw_text.strip():
        print(
            f"[dictate] Timing: stt={t1 - t0:.2f}s cleanup=0.00s "
            f"total={t1 - t0:.2f}s audio={len(audio_bytes)/1024:.0f}KB "
            f"stt_model={STT_MODEL} cleanup_model={COMPOSE_MODEL} (empty)"
        )
        return {"text": "", "raw": ""}

    app_context = parse_context(context)
    composed = await compose_text(raw_text, app_context)

    t2 = time.monotonic()
    audio_kb = len(audio_bytes) / 1024
    print(
        f"[dictate] Timing: stt={t1 - t0:.2f}s cleanup={t2 - t1:.2f}s "
        f"total={t2 - t0:.2f}s audio={audio_kb:.0f}KB "
        f"stt_model={STT_MODEL} cleanup_model={COMPOSE_MODEL}"
    )

    return {"text": composed, "raw": raw_text}


# ---------------------------------------------------------------------------
# Cleanup (composition only, no STT)
# ---------------------------------------------------------------------------


class CleanupRequest(BaseModel):
    """Request body for the /cleanup endpoint."""
    text: str
    context: Optional[dict] = None


@app.post("/cleanup")
async def cleanup(
    request: CleanupRequest,
    _credentials=Depends(verify_token),
):
    """Clean up raw transcript text via LLM composition.

    Accept raw transcription text and optional application context.
    Return polished text ready for injection. This endpoint runs
    only the LLM cleanup step — no STT.
    """
    t0 = time.monotonic()

    if not request.text or not request.text.strip():
        return {"text": ""}

    app_context = parse_context_dict(request.context)
    composed = await compose_text(request.text, app_context)

    t1 = time.monotonic()
    print(
        f"[cleanup] Timing: cleanup={t1 - t0:.2f}s "
        f"input_len={len(request.text)} cleanup_model={COMPOSE_MODEL}"
    )

    return {"text": composed}


# ---------------------------------------------------------------------------
# Audio resampling
# ---------------------------------------------------------------------------


def resample_16k_to_24k(pcm16_data: bytes) -> bytes:
    """Resample 16-bit PCM from 16kHz to 24kHz using linear interpolation.

    The Realtime API requires 24kHz mono PCM16. The client captures at
    16kHz. This performs simple linear interpolation to convert between
    the two sample rates (ratio 3:2, so for every 2 input samples we
    produce 3 output samples).
    """
    if not pcm16_data:
        return b""

    # Unpack 16-bit little-endian signed samples.
    n_samples = len(pcm16_data) // 2
    if n_samples < 2:
        return pcm16_data

    samples = struct.unpack(f"<{n_samples}h", pcm16_data[:n_samples * 2])

    # Resample ratio: 24000/16000 = 3/2.
    # Output length = ceil(n_samples * 3 / 2).
    out_len = (n_samples * 3 + 1) // 2
    output = []

    for i in range(out_len):
        # Map output index back to input position.
        src = i * 2.0 / 3.0
        idx = int(src)
        frac = src - idx

        if idx >= n_samples - 1:
            output.append(samples[-1])
        else:
            # Linear interpolation between adjacent samples.
            val = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
            output.append(max(-32768, min(32767, int(round(val)))))

    return struct.pack(f"<{len(output)}h", *output)


# ---------------------------------------------------------------------------
# Realtime API connection helpers
# ---------------------------------------------------------------------------


def _get_realtime_ws_url(model: str) -> str:
    """Build the WebSocket URL for the Realtime API via the gateway."""
    gateway_url = get_gateway_url()
    ws_url = gateway_url.replace("https://", "wss://").replace("http://", "ws://")
    return f"{ws_url}/v1/realtime?model={model}"


def _get_realtime_headers() -> dict:
    """Build authentication headers for the Realtime API gateway.

    Include the ``OpenAI-Beta: realtime=v1`` header required by the
    gateway when proxying upstream to OpenAI.
    """
    api_key = get_gateway_api_key()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "OpenAI-Beta": "realtime=v1",
    }
    headers.update(get_client_metadata_headers())
    return headers


async def _connect_realtime(model: str, retry_on_auth_error: bool = True):
    """Open a WebSocket to the Realtime API via the gateway.

    Use the same connection parameters as voice.py's VoiceSession.connect:
    websockets.connect with ping_interval=20, ping_timeout=20.
    """
    url = _get_realtime_ws_url(model)
    headers = _get_realtime_headers()

    try:
        ws = await websockets.connect(
            url,
            additional_headers=headers,
            ping_interval=20,
            ping_timeout=20,
        )
        return ws
    except Exception as e:
        error_str = str(e)
        if retry_on_auth_error and (
            "401" in error_str or "Unauthorized" in error_str
        ):
            print("[stream] Auth error, retrying with fresh token")
            clear_token_cache()
            return await _connect_realtime(model, retry_on_auth_error=False)
        raise


async def _configure_transcription_session(
    ws, stt_model: str, language: Optional[str] = None
):
    """Send session.update to configure a transcription-only session.

    Use modalities ["text", "audio"] because the Realtime API requires
    audio modality to accept input_audio_buffer.append messages. Audio
    output events from the API are ignored — we only want the transcript.

    Disable turn_detection (set to None) so the server does NOT use VAD
    to auto-commit. The client controls when audio ends by sending a
    "stop" message, at which point we manually commit the buffer. This
    avoids the race between server VAD and the client's stop signal that
    caused reliability issues in the shelved implementation.
    """
    transcription_config = {
        "model": stt_model,
    }
    if language:
        transcription_config["language"] = language

    config = {
        "type": "session.update",
        "session": {
            "modalities": ["text", "audio"],
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription_config,
            "turn_detection": None,
        },
    }

    await ws.send(json.dumps(config))


def _verify_ws_token(authorization: Optional[str]) -> bool:
    """Check that a WebSocket Authorization value contains a valid token."""
    if not API_KEY:
        return False
    if not authorization:
        return False
    # Accept "Bearer <token>" format.
    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1] == API_KEY
    # Also accept bare token.
    return authorization == API_KEY


# ---------------------------------------------------------------------------
# Streaming transcription via Realtime API
# ---------------------------------------------------------------------------


@app.websocket("/stream")
async def stream_transcription(ws: WebSocket):
    """Stream audio for real-time transcription via the Realtime API.

    This endpoint manages its own Realtime API session as a proper client
    (like voice.py's VoiceSession). It is NOT a WebSocket frame bridge.

    The VoiceService:
      1. Receives PCM chunks from the Swift client
      2. Opens its own websockets.connect() to the gateway
      3. Resamples 16kHz→24kHz and sends input_audio_buffer.append
      4. Listens for transcription events and accumulates the transcript
      5. On "stop": commits the buffer, collects final transcript,
         runs LLM cleanup, returns polished text

    Protocol (client → server):
        1. {"type":"start","context":{...},"language":"en"}
        2. {"type":"audio","audio":"<base64 PCM16 16kHz mono>"}  (repeated)
        3. {"type":"stop"}

    Protocol (server → client):
        - {"type":"transcript_delta","delta":"..."}
        - {"type":"transcript_done","text":"...","raw":"..."}
        - {"type":"error","error":"..."}
    """
    if websockets is None:
        await ws.accept()
        await ws.send_json({
            "type": "error",
            "error": "websockets package not installed on server",
        })
        await ws.close()
        return

    # Authenticate via query parameter or header.
    token_param = ws.query_params.get("token", "")
    auth_header = ws.headers.get("authorization", "")
    if not (_verify_ws_token(token_param) or _verify_ws_token(auth_header)):
        await ws.close(code=4001, reason="Unauthorized")
        return

    await ws.accept()

    realtime_ws = None
    app_context = AppContext()
    t_start = time.monotonic()

    # Accumulate transcript segments. With turn_detection disabled the
    # Realtime API produces one transcript per manual commit, but we
    # keep a list for robustness.
    completed_transcripts: list[str] = []

    # Track whether the client has sent "stop".
    stopped = asyncio.Event()

    # Track whether the transcription has completed (even if empty).
    transcription_done = asyncio.Event()

    # Track audio stats.
    chunks_received = 0
    chunks_forwarded = 0
    bytes_received = 0

    async def handle_client_messages():
        """Receive messages from the Swift client and forward audio."""
        nonlocal realtime_ws, app_context, chunks_received, chunks_forwarded
        nonlocal bytes_received

        try:
            while not stopped.is_set():
                try:
                    raw = await asyncio.wait_for(ws.receive_text(), timeout=0.5)
                except asyncio.TimeoutError:
                    continue
                except WebSocketDisconnect:
                    stopped.set()
                    return

                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "start":
                    app_context = parse_context_dict(msg.get("context"))
                    language = msg.get("language")

                    try:
                        realtime_ws = await _connect_realtime(REALTIME_MODEL)
                        await _configure_transcription_session(
                            realtime_ws, STT_MODEL, language
                        )
                        print(
                            f"[stream] Realtime API session opened "
                            f"(model={REALTIME_MODEL}, stt={STT_MODEL})"
                        )
                    except Exception as e:
                        print(f"[stream] Failed to connect to Realtime API: {e}")
                        traceback.print_exc()
                        await ws.send_json({
                            "type": "error",
                            "error": f"Failed to connect: {e}",
                        })
                        stopped.set()
                        return

                elif msg_type == "audio":
                    if realtime_ws is None:
                        continue

                    audio_b64 = msg.get("audio", "")
                    if not audio_b64:
                        continue

                    try:
                        pcm_16k = base64.b64decode(audio_b64)
                    except Exception:
                        continue

                    chunks_received += 1
                    bytes_received += len(pcm_16k)

                    # Resample 16kHz → 24kHz for the Realtime API.
                    pcm_24k = resample_16k_to_24k(pcm_16k)

                    # Send the resampled audio as a single append message.
                    try:
                        audio_out = base64.b64encode(pcm_24k).decode("utf-8")
                        await realtime_ws.send(json.dumps({
                            "type": "input_audio_buffer.append",
                            "audio": audio_out,
                        }))
                        chunks_forwarded += 1
                    except Exception as e:
                        print(f"[stream] Error sending audio: {e}")
                        traceback.print_exc()

                elif msg_type == "stop":
                    print(
                        f"[stream] Stop received "
                        f"(received={chunks_received}, "
                        f"forwarded={chunks_forwarded}, "
                        f"bytes={bytes_received})"
                    )
                    stopped.set()
                    return

        except Exception as e:
            print(f"[stream] Error in handle_client_messages: {e}")
            traceback.print_exc()
            stopped.set()

    async def handle_realtime_events():
        """Receive events from the Realtime API and collect transcripts."""
        nonlocal realtime_ws

        # Wait until the Realtime API connection is established.
        while realtime_ws is None and not stopped.is_set():
            await asyncio.sleep(0.05)

        if realtime_ws is None:
            return

        try:
            async for message in realtime_ws:
                event = json.loads(message)
                event_type = event.get("type", "")

                # Log non-audio events for debugging.
                if event_type not in (
                    "response.audio.delta",
                    "response.audio_transcript.delta",
                ):
                    summary = json.dumps(event)
                    if len(summary) > 300:
                        summary = summary[:300] + "..."
                    print(f"[stream] Realtime event: {event_type} -> {summary}")

                if event_type == "conversation.item.input_audio_transcription.completed":
                    transcript = event.get("transcript", "")
                    if transcript and transcript.strip():
                        completed_transcripts.append(transcript.strip())
                        print(
                            f"[stream] Transcript completed: "
                            f"{transcript.strip()[:80]}..."
                        )
                    else:
                        print("[stream] Transcript completed (empty)")
                    transcription_done.set()

                elif event_type == "conversation.item.input_audio_transcription.delta":
                    delta = event.get("delta", "")
                    if delta:
                        try:
                            await ws.send_json({
                                "type": "transcript_delta",
                                "delta": delta,
                            })
                        except Exception:
                            pass

                elif event_type == "error":
                    error_info = event.get("error", {})
                    error_msg = error_info.get(
                        "message", "Unknown Realtime API error"
                    )
                    error_code = error_info.get("code", "")
                    print(
                        f"[stream] Realtime API error: "
                        f"{error_code}: {error_msg}"
                    )
                    try:
                        await ws.send_json({
                            "type": "error",
                            "error": error_msg,
                        })
                    except Exception:
                        pass

                # If we have received a stop signal AND transcription is
                # done (even if empty), stop listening.
                if stopped.is_set() and transcription_done.is_set():
                    break

        except Exception as e:
            if not stopped.is_set():
                print(f"[stream] Error receiving from Realtime API: {e}")
                traceback.print_exc()

    try:
        # Run client message handling and Realtime API event handling
        # concurrently.
        client_task = asyncio.create_task(handle_client_messages())
        realtime_task = asyncio.create_task(handle_realtime_events())

        # Wait for the client handler to finish (client sends "stop"
        # or disconnects).
        await client_task

        # After receiving "stop", manually commit the audio buffer.
        # With turn_detection disabled the Realtime API waits for an
        # explicit commit before transcribing.
        if realtime_ws is not None:
            try:
                await realtime_ws.send(json.dumps({
                    "type": "input_audio_buffer.commit",
                }))
                print("[stream] Audio buffer committed")
            except Exception as e:
                print(f"[stream] Error committing audio buffer: {e}")

            # Wait for the transcript to arrive. The commit triggers
            # input_audio_transcription.completed which sets
            # transcription_done. No response.create needed — we only
            # want the transcription, not an assistant response.
            try:
                await asyncio.wait_for(realtime_task, timeout=10.0)
            except asyncio.TimeoutError:
                print("[stream] Timed out waiting for transcript")
                realtime_task.cancel()
        else:
            realtime_task.cancel()

        t_stt = time.monotonic()

        # Combine all transcript segments.
        raw_text = " ".join(completed_transcripts)

        if not raw_text.strip():
            print(
                f"[stream] Timing: stream={t_stt - t_start:.2f}s "
                f"cleanup=0.00s total={t_stt - t_start:.2f}s "
                f"chunks={chunks_forwarded} (empty)"
            )
            await ws.send_json({
                "type": "transcript_done",
                "text": "",
                "raw": "",
            })
        else:
            # Run LLM cleanup on the raw transcript.
            composed = await compose_text(raw_text, app_context)

            t_cleanup = time.monotonic()
            print(
                f"[stream] Timing: stream={t_stt - t_start:.2f}s "
                f"cleanup={t_cleanup - t_stt:.2f}s "
                f"total={t_cleanup - t_start:.2f}s "
                f"chunks={chunks_forwarded} "
                f"bytes={bytes_received}"
            )

            await ws.send_json({
                "type": "transcript_done",
                "text": composed,
                "raw": raw_text,
            })

    except WebSocketDisconnect:
        print("[stream] Client disconnected")
    except Exception as e:
        print(f"[stream] Unexpected error: {e}")
        traceback.print_exc()
        try:
            await ws.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        # Clean up the Realtime API connection.
        if realtime_ws is not None:
            try:
                await realtime_ws.close()
            except Exception:
                pass
            print("[stream] Realtime API connection closed")

        try:
            await ws.close()
        except Exception:
            pass


Node.start(http_server=HttpServer(app=app))
