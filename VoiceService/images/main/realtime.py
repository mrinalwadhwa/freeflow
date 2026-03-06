"""Realtime API streaming for voice dictation.

Manages WebSocket connections to the OpenAI Realtime API through the
Autonomy gateway. Handles audio resampling (16kHz→24kHz), session
configuration, and the full bidirectional streaming protocol between
the Swift client and the Realtime API.

The VoiceService acts as a proper Realtime API client (not a frame
bridge). It receives PCM chunks from the Swift client, resamples and
forwards them, listens for transcription events, and returns polished
text after LLM cleanup.

The client WebSocket is persistent across dictation sessions. Each
"start" message begins a new dictation cycle: a fresh Realtime API
connection is opened concurrently with receiving audio (early chunks
are buffered until the connection is ready), "stop" triggers commit
and transcription, polished text is returned via "transcript_done",
and the Realtime API connection is closed. The client WebSocket
stays open for the next dictation.
"""

import asyncio
import base64
import json
import struct
import time
import traceback
from typing import Optional

from autonomy.models.clients.gateway_config import (
    get_gateway_url,
    get_gateway_api_key,
    get_client_metadata_headers,
    clear_token_cache,
)
from fastapi import WebSocket, WebSocketDisconnect

try:
    import websockets
except ImportError:
    websockets = None

from context import AppContext, parse_dict
from polish import polish_text


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

STT_MODEL = "gpt-4o-mini-transcribe"
REALTIME_MODEL = "gpt-4o-realtime-preview"


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
# Gateway connection helpers
# ---------------------------------------------------------------------------


def _get_ws_url(model: str) -> str:
    """Build the WebSocket URL for the Realtime API via the gateway."""
    gateway_url = get_gateway_url()
    ws_url = gateway_url.replace("https://", "wss://").replace("http://", "ws://")
    return f"{ws_url}/v1/realtime?model={model}"


def _get_headers() -> dict:
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


async def connect(model: str, retry_on_auth_error: bool = True):
    """Open a WebSocket to the Realtime API via the gateway.

    Disable the library's built-in keepalive pings. The Realtime API
    connection only lives for the duration of a single dictation session
    (a few seconds). Keepalive pings are unnecessary and caused
    ConnectionClosedError noise when sessions were close together
    because the keepalive task outlived the session and fired during
    the next one.

    Set close_timeout=0 so that abort()/close() returns immediately
    without waiting for the server's close frame. This prevents the
    websockets library's background close_connection task from
    lingering and producing 'keepalive ping timeout' errors in the
    asyncio event loop after the session ends.
    """
    url = _get_ws_url(model)
    headers = _get_headers()

    try:
        ws = await websockets.connect(
            url,
            additional_headers=headers,
            ping_interval=None,
            ping_timeout=None,
            close_timeout=0,
        )
        return ws
    except Exception as e:
        error_str = str(e)
        if retry_on_auth_error and (
            "401" in error_str or "Unauthorized" in error_str
        ):
            print("[stream] Auth error, retrying with fresh token")
            clear_token_cache()
            return await connect(model, retry_on_auth_error=False)
        raise


async def configure_session(
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


# ---------------------------------------------------------------------------
# Stream handler
# ---------------------------------------------------------------------------


def verify_ws_token(authorization: Optional[str], api_key: str) -> bool:
    """Check that a WebSocket Authorization value contains a valid token."""
    if not api_key:
        return False
    if not authorization:
        return False
    # Accept "Bearer <token>" format.
    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1] == api_key
    # Also accept bare token.
    return authorization == api_key


async def handle_stream(ws: WebSocket, api_key: str):
    """Handle a persistent WebSocket that may carry multiple dictation sessions.

    The client keeps a single WebSocket open across dictations. Each
    dictation cycle is:

        1. Client sends {"type":"start","context":{...},"language":"en"}
        2. Server opens a fresh Realtime API connection
        3. Client sends {"type":"audio","audio":"<base64>"} (repeated)
        4. Client sends {"type":"stop"}
        5. Server commits the audio buffer, collects the transcript,
           runs LLM polishing, sends {"type":"transcript_done",...}
        6. Server closes the Realtime API connection

    The client WebSocket stays open for the next cycle. A "ping"
    message from the client is answered with a "pong" to keep the
    connection alive during idle periods.
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
    if not (verify_ws_token(token_param, api_key)
            or verify_ws_token(auth_header, api_key)):
        await ws.close(code=4001, reason="Unauthorized")
        return

    await ws.accept()
    print("[stream] Client connected (persistent session)")

    session_count = 0

    try:
        while True:
            # Wait for a "start" message (or client disconnect).
            msg = await _wait_for_start(ws)
            if msg is None:
                # Client disconnected cleanly.
                break

            session_count += 1
            session_id = session_count
            print(f"[stream] Session {session_id} starting")

            await _run_dictation_session(ws, msg, session_id)

    except WebSocketDisconnect:
        print(
            f"[stream] Client disconnected "
            f"(completed {session_count} sessions)"
        )
    except Exception as e:
        print(f"[stream] Unexpected error: {e}")
        traceback.print_exc()
        try:
            await ws.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        try:
            await ws.close()
        except Exception:
            pass


async def _wait_for_start(ws: WebSocket) -> Optional[dict]:
    """Block until the client sends a "start" message.

    Handle "ping" keepalives while waiting. Return the parsed start
    message dict, or None if the client disconnects.
    """
    while True:
        try:
            raw = await ws.receive_text()
        except WebSocketDisconnect:
            return None

        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type", "")

        if msg_type == "start":
            return msg
        elif msg_type == "ping":
            try:
                await ws.send_json({"type": "pong"})
            except Exception:
                return None
        # Ignore unexpected messages between sessions.


async def _run_dictation_session(
    ws: WebSocket, start_msg: dict, session_id: int
):
    """Run a single dictation cycle within a persistent WebSocket.

    Open a Realtime API connection concurrently with receiving audio
    from the client. Early audio chunks that arrive before the
    Realtime API connection is ready are buffered and flushed once
    connected. This overlaps the 0.5-1s connection cost with the
    start of the user's speech.
    """
    app_context = parse_dict(start_msg.get("context"))
    language = start_msg.get("language")
    t_start = time.monotonic()

    # Accumulate transcript segments.
    completed_transcripts: list[str] = []

    # Track whether the client has sent "stop".
    stopped = asyncio.Event()

    # Track whether the transcription has completed.
    transcription_done = asyncio.Event()

    # Audio stats.
    chunks_received = 0
    chunks_forwarded = 0
    bytes_received = 0

    # The Realtime API connection is opened concurrently. Audio chunks
    # that arrive before it is ready are buffered here. Once connected,
    # the buffer is flushed and subsequent chunks are forwarded directly.
    realtime_ws = None
    realtime_ready = asyncio.Event()
    realtime_failed = False
    audio_buffer: list[bytes] = []  # resampled 24kHz PCM chunks

    async def open_realtime_connection():
        """Open and configure the Realtime API connection."""
        nonlocal realtime_ws, realtime_failed

        try:
            realtime_ws = await connect(REALTIME_MODEL)
            await configure_session(realtime_ws, STT_MODEL, language)
            t_connected = time.monotonic()
            buffered = len(audio_buffer)
            print(
                f"[stream] Session {session_id}: Realtime API opened "
                f"in {t_connected - t_start:.2f}s "
                f"(model={REALTIME_MODEL}, stt={STT_MODEL}, "
                f"buffered={buffered} chunks)"
            )
        except Exception as e:
            print(
                f"[stream] Session {session_id}: "
                f"Failed to connect to Realtime API: {e}"
            )
            traceback.print_exc()
            realtime_failed = True
            try:
                await ws.send_json({
                    "type": "error",
                    "error": f"Failed to connect: {e}",
                })
            except Exception:
                pass
        finally:
            # Always signal ready so the client handler unblocks,
            # even on failure.
            realtime_ready.set()

    # --- Nested coroutines for concurrent message handling ---

    # Flag to signal that the client disconnected during this session.
    client_disconnected = False

    async def handle_client_messages():
        """Receive audio and stop messages from the Swift client.

        Audio chunks that arrive before the Realtime API connection is
        ready are resampled and buffered. Once the connection is live,
        buffered chunks are flushed and subsequent chunks are forwarded
        directly.
        """
        nonlocal chunks_received, chunks_forwarded, bytes_received
        nonlocal client_disconnected

        async def _forward_chunk(pcm_24k: bytes):
            """Send a resampled chunk to the Realtime API."""
            nonlocal chunks_forwarded
            audio_out = base64.b64encode(pcm_24k).decode("utf-8")
            await realtime_ws.send(json.dumps({
                "type": "input_audio_buffer.append",
                "audio": audio_out,
            }))
            chunks_forwarded += 1

        async def _flush_buffer():
            """Send all buffered chunks to the Realtime API."""
            nonlocal chunks_forwarded
            for pcm_24k in audio_buffer:
                await _forward_chunk(pcm_24k)
            audio_buffer.clear()

        session_start = time.monotonic()
        SESSION_TIMEOUT = 120  # seconds — absolute limit for a single session

        try:
            while not stopped.is_set():
                # Guard against silent connection death: if the session
                # has been running longer than the absolute limit, bail.
                if time.monotonic() - session_start > SESSION_TIMEOUT:
                    print(
                        f"[stream] Session {session_id}: "
                        f"Session timeout ({SESSION_TIMEOUT}s), "
                        f"treating as client disconnect"
                    )
                    stopped.set()
                    client_disconnected = True
                    return

                try:
                    raw = await asyncio.wait_for(
                        ws.receive_text(), timeout=0.5
                    )
                except asyncio.TimeoutError:
                    continue
                except WebSocketDisconnect:
                    stopped.set()
                    client_disconnected = True
                    return

                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "audio":
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

                    if realtime_ready.is_set():
                        if realtime_failed:
                            # Connection failed; drop audio silently.
                            # The error was already sent to the client.
                            continue
                        try:
                            # Flush any chunks buffered while the
                            # connection was being established.
                            if audio_buffer:
                                await _flush_buffer()
                            await _forward_chunk(pcm_24k)
                        except Exception as e:
                            print(
                                f"[stream] Session {session_id}: "
                                f"Error sending audio: {e}"
                            )
                            traceback.print_exc()
                    else:
                        # Buffer until the Realtime API is ready.
                        audio_buffer.append(pcm_24k)

                elif msg_type == "stop":
                    # If the Realtime API is not ready yet, wait for it
                    # before processing stop so buffered audio can be
                    # flushed.
                    if not realtime_ready.is_set():
                        print(
                            f"[stream] Session {session_id}: "
                            f"Stop received, waiting for Realtime API "
                            f"({len(audio_buffer)} chunks buffered)"
                        )
                        await realtime_ready.wait()

                    # Flush any remaining buffered audio.
                    if audio_buffer and not realtime_failed:
                        try:
                            await _flush_buffer()
                        except Exception as e:
                            print(
                                f"[stream] Session {session_id}: "
                                f"Error flushing buffer: {e}"
                            )
                            traceback.print_exc()

                    print(
                        f"[stream] Session {session_id}: Stop received "
                        f"(received={chunks_received}, "
                        f"forwarded={chunks_forwarded}, "
                        f"bytes={bytes_received})"
                    )
                    stopped.set()
                    return

                elif msg_type == "ping":
                    try:
                        await ws.send_json({"type": "pong"})
                    except Exception:
                        stopped.set()
                        client_disconnected = True
                        return

                # A "start" during an active session is a protocol error;
                # ignore it.

        except Exception as e:
            print(
                f"[stream] Session {session_id}: "
                f"Error in handle_client_messages: {e}"
            )
            traceback.print_exc()
            stopped.set()

    async def handle_realtime_events():
        """Receive events from the Realtime API and collect transcripts."""
        # Wait for the connection to be established.
        await realtime_ready.wait()
        if realtime_failed or realtime_ws is None:
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
                    print(
                        f"[stream] Session {session_id}: "
                        f"Realtime event: {event_type} -> {summary}"
                    )

                if event_type == "conversation.item.input_audio_transcription.completed":
                    transcript = event.get("transcript", "")
                    if transcript and transcript.strip():
                        completed_transcripts.append(transcript.strip())
                        print(
                            f"[stream] Session {session_id}: "
                            f"Transcript completed: "
                            f"{transcript.strip()[:80]}..."
                        )
                    else:
                        print(
                            f"[stream] Session {session_id}: "
                            f"Transcript completed (empty)"
                        )
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
                        f"[stream] Session {session_id}: "
                        f"Realtime API error: {error_code}: {error_msg}"
                    )
                    try:
                        await ws.send_json({
                            "type": "error",
                            "error": error_msg,
                        })
                    except Exception:
                        pass

                # If stop received AND transcription done, stop listening.
                if stopped.is_set() and transcription_done.is_set():
                    break

        except Exception as e:
            if not stopped.is_set():
                print(
                    f"[stream] Session {session_id}: "
                    f"Error receiving from Realtime API: {e}"
                )
                traceback.print_exc()

    # --- Run the session ---

    try:
        # Open the Realtime API connection concurrently with receiving
        # audio from the client. Early audio chunks are buffered until
        # the connection is ready.
        connect_task = asyncio.create_task(open_realtime_connection())
        client_task = asyncio.create_task(handle_client_messages())
        realtime_task = asyncio.create_task(handle_realtime_events())

        # Wait for the client handler to finish (stop or disconnect).
        await client_task

        # Ensure the connection task has completed (it should have by
        # now since handle_client_messages waits for realtime_ready
        # before processing stop).
        await connect_task

        if realtime_failed:
            # Connection never succeeded. Cannot commit or transcribe.
            realtime_task.cancel()
            return

        # After "stop", commit the audio buffer.
        if realtime_ws is not None:
            try:
                await realtime_ws.send(json.dumps({
                    "type": "input_audio_buffer.commit",
                }))
                print(
                    f"[stream] Session {session_id}: "
                    f"Audio buffer committed"
                )
            except Exception as e:
                print(
                    f"[stream] Session {session_id}: "
                    f"Error committing audio buffer: {e}"
                )

            try:
                await asyncio.wait_for(realtime_task, timeout=10.0)
            except asyncio.TimeoutError:
                print(
                    f"[stream] Session {session_id}: "
                    f"Timed out waiting for transcript"
                )
                realtime_task.cancel()
        else:
            realtime_task.cancel()

        t_stt = time.monotonic()

        # Combine transcript segments.
        raw_text = " ".join(completed_transcripts)

        if not raw_text.strip():
            print(
                f"[stream] Session {session_id}: "
                f"Timing: stream={t_stt - t_start:.2f}s "
                f"cleanup=0.00s total={t_stt - t_start:.2f}s "
                f"chunks={chunks_forwarded} (empty)"
            )
            if not client_disconnected:
                await ws.send_json({
                    "type": "transcript_done",
                    "text": "",
                    "raw": "",
                })
        else:
            polished = await polish_text(raw_text, app_context)

            t_polish = time.monotonic()
            print(
                f"[stream] Session {session_id}: "
                f"Timing: stream={t_stt - t_start:.2f}s "
                f"polish={t_polish - t_stt:.2f}s "
                f"total={t_polish - t_start:.2f}s "
                f"chunks={chunks_forwarded} "
                f"bytes={bytes_received}"
            )

            if not client_disconnected:
                await ws.send_json({
                    "type": "transcript_done",
                    "text": polished,
                    "raw": raw_text,
                })

    except WebSocketDisconnect:
        # Client disconnected during this session. Propagate so the
        # outer loop in handle_stream exits.
        raise
    except Exception as e:
        print(
            f"[stream] Session {session_id}: Unexpected error: {e}"
        )
        traceback.print_exc()
        try:
            await ws.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        # Always close the Realtime API connection at session end.
        # Use abort() for an immediate TCP-level close instead of the
        # graceful close handshake. This prevents the websockets
        # library's background tasks from lingering and producing
        # ConnectionClosedError noise that delays the next session.
        if realtime_ws is not None:
            try:
                realtime_ws.abort()
            except Exception:
                try:
                    await realtime_ws.close()
                except Exception:
                    pass
            print(
                f"[stream] Session {session_id}: "
                f"Realtime API connection closed"
            )

    # If the client disconnected during the session, raise so the
    # outer loop terminates.
    if client_disconnected:
        raise WebSocketDisconnect(code=1000)
