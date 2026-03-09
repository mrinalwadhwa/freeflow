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

Serve zone web pages (homepage, invite landing, admin dashboard) via
Jinja2 templates and static files.
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
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import admin
import auth
import context
import db
import invite
import polish
import realtime
import startup
import web


# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app):
    await startup.start_auth()
    await db.open_pool()
    await invite.ensure_table()
    await admin.ensure_table()
    yield
    await db.close_pool()
    await startup.stop_auth()


app = FastAPI(lifespan=lifespan)

# Mount web page routes and static files.
app.include_router(web.admin_router)
app.include_router(web.public_router)
_static_dir = os.path.join(os.path.dirname(__file__), "static")
app.mount("/static", StaticFiles(directory=_static_dir), name="static")

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
# /admin/api — admin endpoints for invite and user management
# ---------------------------------------------------------------------------


class CreateInviteRequest(BaseModel):
    """Request body for creating an invite."""
    label: Optional[str] = None
    email: Optional[str] = None
    max_uses: int = 1
    expires_in_hours: Optional[int] = None


@app.post("/admin/api/invites")
async def admin_create_invite(
    request: CreateInviteRequest,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Create a new invite token. Requires admin session."""
    token, invite_id = await invite.create_invite(
        created_by=user.user_id,
        label=request.label,
        email=request.email,
        max_uses=request.max_uses,
        expires_in_hours=request.expires_in_hours,
    )
    return {
        "id": invite_id,
        "token": token,
    }


@app.get("/admin/api/invites")
async def admin_list_invites(
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """List all invite tokens. Requires admin session."""
    invites = await invite.list_invites()
    return [
        {
            "id": inv.id,
            "label": inv.label,
            "email": inv.email,
            "created_at": inv.created_at.isoformat(),
            "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
            "max_uses": inv.max_uses,
            "use_count": inv.use_count,
            "revoked": inv.revoked,
        }
        for inv in invites
    ]


@app.delete("/admin/api/invites/{invite_id}")
async def admin_revoke_invite(
    invite_id: int,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Revoke an invite token. Requires admin session."""
    try:
        await invite.revoke(invite_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return {"ok": True}


@app.get("/admin/api/users")
async def admin_list_users(
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """List all users with email status. Requires admin session."""
    users = await _list_users_from_auth()
    return users


@app.post("/admin/api/users/{target_user_id}/revoke")
async def admin_revoke_user(
    target_user_id: str,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Revoke a user by deleting their sessions. Requires admin session."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            'DELETE FROM auth_session WHERE "userId" = %s',
            (target_user_id,),
        )
        deleted = result.rowcount
    if deleted == 0:
        raise HTTPException(status_code=404, detail="User not found or has no sessions")
    return {"ok": True, "sessions_deleted": deleted}


@app.get("/admin/api/users/email-status")
async def admin_email_status(
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Summary of user email status. Requires admin session."""
    users = await _list_users_from_auth()
    with_email = [u for u in users if u["has_email"]]
    without_email = [u for u in users if not u["has_email"]]
    return {
        "total": len(users),
        "with_email": len(with_email),
        "without_email": len(without_email),
        "users_without_email": [
            {
                "id": u["id"],
                "name": u["name"],
                "created_at": u["created_at"],
            }
            for u in without_email
        ],
    }


async def _list_users_from_auth() -> list[dict]:
    """Fetch all users from better-auth's user table.

    Read directly from the database rather than calling better-auth's
    API, which has no list-users endpoint. The auth_user table is
    managed by better-auth with known column names.
    """
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            """
            SELECT id, name, email, "emailVerified", "createdAt"
            FROM auth_user
            ORDER BY "createdAt" DESC
            """
        )
        rows = await result.fetchall()

    users = []
    for row in rows:
        user_id, name, email, email_verified, created_at = row
        is_placeholder = email and email.endswith("@placeholder.voice.local")
        is_admin_user = await admin.is_admin(user_id)
        users.append({
            "id": user_id,
            "name": name,
            "email": email if not is_placeholder else None,
            "has_email": not is_placeholder and bool(email_verified),
            "is_admin": is_admin_user,
            "created_at": created_at.isoformat() if created_at else None,
        })
    return users


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
