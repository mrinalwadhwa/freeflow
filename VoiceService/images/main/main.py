"""Voice dictation service.

Expose a /dictate endpoint that accepts a WAV audio file and application
context, and returns polished text ready for injection. If polishing fails,
the raw transcription is returned as fallback.

Expose a /stream WebSocket endpoint that streams audio to the OpenAI
Realtime API for real-time transcription. The VoiceService manages its
own Realtime API session (like voice.py's VoiceSession) rather than
bridging WebSocket frames. The transcript is available the moment speech
ends, then polished via LLM before returning to the client.

Expose a /polish endpoint that accepts raw transcript text and context,
and returns polished text. This is the polish_text function exposed as
a standalone HTTP endpoint.
"""

import os
import time
from contextlib import asynccontextmanager
from typing import Optional

from autonomy import HttpServer, Model, Node
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    UploadFile,
    WebSocket,
)
from fastapi.responses import JSONResponse
from pydantic import BaseModel

import auth
import context
import db
import invite
import polish
import realtime
import startup


# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app):
    await startup.start_auth()
    await db.open_pool()
    await invite.ensure_table()
    yield
    await db.close_pool()
    await startup.stop_auth()


app = FastAPI(lifespan=lifespan)

STT_MODEL = "gpt-4o-mini-transcribe"


# ---------------------------------------------------------------------------
# /dictate — STT + polishing in one call
# ---------------------------------------------------------------------------


@app.post("/dictate")
async def dictate(
    file: UploadFile = File(...),
    ctx: str = Form("{}", alias="context"),
    language: Optional[str] = Form(None),
    user: auth.AuthUser = Depends(auth.require_auth),
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
            f"[dictate] Timing: stt={t1 - t0:.2f}s polish=0.00s "
            f"total={t1 - t0:.2f}s audio={len(audio_bytes)/1024:.0f}KB "
            f"stt_model={STT_MODEL} polish_model={polish.POLISH_MODEL} "
            f"(empty)"
        )
        return {"text": "", "raw": ""}

    app_context = context.parse_json(ctx)
    polished = await polish.polish_text(raw_text, app_context)

    t2 = time.monotonic()
    audio_kb = len(audio_bytes) / 1024
    print(
        f"[dictate] Timing: stt={t1 - t0:.2f}s polish={t2 - t1:.2f}s "
        f"total={t2 - t0:.2f}s audio={audio_kb:.0f}KB "
        f"stt_model={STT_MODEL} polish_model={polish.POLISH_MODEL}"
    )

    return {"text": polished, "raw": raw_text}


# ---------------------------------------------------------------------------
# /polish — text polishing only, no STT
# ---------------------------------------------------------------------------


class PolishRequest(BaseModel):
    """Request body for the /polish endpoint."""
    text: str
    context: Optional[dict] = None


@app.post("/polish")
async def polish_endpoint(
    request: PolishRequest,
    user: auth.AuthUser = Depends(auth.require_auth),
):
    """Polish raw transcript text via the polishing pipeline.

    Accept raw transcription text and optional application context.
    Return polished text ready for injection. This endpoint runs
    only the polishing step, no STT.
    """
    t0 = time.monotonic()

    if not request.text or not request.text.strip():
        return {"text": ""}

    app_context = context.parse_dict(request.context)
    polished = await polish.polish_text(request.text, app_context)

    t1 = time.monotonic()
    print(
        f"[polish] Timing: polish={t1 - t0:.2f}s "
        f"input_len={len(request.text)} "
        f"polish_model={polish.POLISH_MODEL}"
    )

    return {"text": polished}


# Keep /cleanup as an alias for backward compatibility with existing clients
# and the test harness.
@app.post("/cleanup")
async def cleanup_endpoint(
    request: PolishRequest,
    user: auth.AuthUser = Depends(auth.require_auth),
):
    """Alias for /polish. Kept for backward compatibility."""
    return await polish_endpoint(request, user)


# ---------------------------------------------------------------------------
# /api/auth — invite redemption and capabilities
# ---------------------------------------------------------------------------


class RedeemRequest(BaseModel):
    """Request body for invite redemption."""
    token: str


@app.post("/api/auth/redeem-invite")
async def redeem_invite(request: RedeemRequest):
    """Redeem an invite token to create a user and session.

    No authentication required. The invite token is the credential.
    Return the session token via set-auth-token header and user info
    in the body.
    """
    try:
        result = await invite.redeem(request.token)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=str(e))

    response = JSONResponse(
        content={
            "user_id": result.user_id,
            "has_email": result.has_email,
        }
    )
    response.headers["set-auth-token"] = result.session_token
    return response


@app.get("/api/auth/capabilities")
async def capabilities():
    """Return server capabilities for client configuration.

    No authentication required. The client checks this on launch to
    discover feature availability and update URLs.
    """
    appcast_url = os.environ.get(
        "APPCAST_URL",
        "https://voice.autonomy.computer/appcast.xml",
    )
    return {
        "invite": True,
        "email_otp": False,
        "require_email": False,
        "require_email_deadline": None,
        "appcast_url": appcast_url,
    }


# ---------------------------------------------------------------------------
# /health — combined health check
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    """Check health of both Python and Node.js auth processes."""
    auth_ok = await auth.check_auth_health()

    if not auth_ok:
        raise HTTPException(
            status_code=503,
            detail={"status": "degraded", "auth": "unavailable"},
        )

    return {"status": "ok", "auth": "ok"}


# ---------------------------------------------------------------------------
# /stream — real-time streaming transcription
# ---------------------------------------------------------------------------


@app.websocket("/stream")
async def stream_endpoint(ws: WebSocket):
    """Stream audio for real-time transcription via the Realtime API."""
    await realtime.handle_stream(ws)


Node.start(http_server=HttpServer(app=app))
