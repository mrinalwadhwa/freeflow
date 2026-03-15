"""FreeFlow dictation service.

Expose a /dictate endpoint that accepts a WAV audio file and application
context, and returns polished text ready for injection. If polishing fails,
the raw transcription is returned as fallback.

Expose a /stream WebSocket endpoint that streams audio to the OpenAI
Realtime API for real-time transcription. The FreeFlowService manages its
own Realtime API session rather than bridging WebSocket frames. The
transcript is available the moment speech ends, then polished via LLM
before returning to the client.

Expose a /polish endpoint that accepts raw transcript text and context,
and returns polished text. This is the polish_text function exposed as
a standalone HTTP endpoint.

Serve the invite landing page via a Jinja2 template. The zone root
redirects to the project repository.
"""

import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
from autonomy import HttpServer, Model, Node
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
)
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

import admin
import auth
import context
import db
import email_config
import invite
import polish
import ratelimit
import realtime
import startup
import web
import zone_lifecycle


# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app):
    await startup.start_auth()
    await db.open_pool()
    await zone_lifecycle.check_reprovisioning()
    await invite.ensure_table()
    await admin.ensure_table()
    await email_config.ensure_table()
    yield
    await db.close_pool()
    await startup.stop_auth()


app = FastAPI(lifespan=lifespan)

# Mount web page routes (invite landing page, root redirect).
app.include_router(web.public_router)

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
    polished = await polish.polish_text(raw_text, app_context, language=language)

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
    language: Optional[str] = None


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
    polished = await polish.polish_text(request.text, app_context, language=request.language)

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


@app.post("/api/auth/redeem-invite", dependencies=[Depends(ratelimit.require_redeem_limit)])
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
        "https://github.com/build-trust/freeflow/releases/latest/download/appcast.xml",
    )
    email_caps = await email_config.get_capabilities()
    return {
        "invite": True,
        "email_otp": email_caps["email_otp"],
        "require_email": email_caps["require_email"],
        "require_email_deadline": email_caps["require_email_deadline"],
        "appcast_url": appcast_url,
    }


# ---------------------------------------------------------------------------
# /admin/api — admin endpoints for invite and user management
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# /admin/api/settings — email configuration and require-email policy
# ---------------------------------------------------------------------------


class SaveEmailConfigRequest(BaseModel):
    """Request body for saving email configuration."""
    provider: str
    api_key: str
    from_address: str


class SaveRequireEmailRequest(BaseModel):
    """Request body for the require-email policy."""
    require: bool
    grace_period_days: Optional[int] = 14


class TestEmailRequest(BaseModel):
    """Request body for sending a test email."""
    to: str


@app.post("/admin/api/settings/email")
async def admin_save_email_config(
    request: SaveEmailConfigRequest,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Save email provider configuration. Requires admin session."""
    if request.provider not in ("resend", "sendgrid"):
        raise HTTPException(status_code=400, detail="Unsupported provider. Use 'resend' or 'sendgrid'.")
    if not request.api_key:
        raise HTTPException(status_code=400, detail="API key is required.")
    if not request.from_address:
        raise HTTPException(status_code=400, detail="From address is required.")

    config = await email_config.save_config(
        provider=request.provider,
        api_key=request.api_key,
        from_address=request.from_address,
    )
    return {
        "ok": True,
        "provider": config.provider,
        "from_address": config.from_address,
        "verified": config.verified,
    }


@app.post("/admin/api/settings/email/test")
async def admin_test_email(
    request: TestEmailRequest,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Send a test email to verify the configuration. Requires admin session."""
    try:
        message = await email_config.send_test_email(request.to)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"ok": True, "message": message}


@app.get("/admin/api/settings/email")
async def admin_get_email_config(
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Return the current email configuration (without the API key). Requires admin session."""
    config = await email_config.get_config()
    if config is None:
        return {"configured": False}
    return {
        "configured": config.is_configured,
        "provider": config.provider,
        "from_address": config.from_address,
        "verified": config.verified,
        "require_email": config.require_email,
        "require_email_deadline": config.require_email_deadline.isoformat() if config.require_email_deadline else None,
    }


@app.post("/admin/api/settings/require-email")
async def admin_save_require_email(
    request: SaveRequireEmailRequest,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Toggle the require-email policy. Requires admin session and configured email."""
    if request.require:
        configured = await email_config.is_email_configured()
        if not configured:
            raise HTTPException(
                status_code=400,
                detail="Email must be configured and verified before requiring email.",
            )
    await email_config.save_require_email(
        require=request.require,
        grace_period_days=request.grace_period_days,
    )
    return {"ok": True, "require_email": request.require}


# ---------------------------------------------------------------------------
# /admin/api — admin endpoints for invite and user management
# ---------------------------------------------------------------------------


# Default invite expiry: 7 days. Prevents forgotten tokens from being
# redeemable indefinitely. Admins can override per-invite.
DEFAULT_INVITE_EXPIRY_HOURS = 7 * 24


class CreateInviteRequest(BaseModel):
    """Request body for creating an invite."""
    label: Optional[str] = None
    email: str
    send_email: bool = False
    max_uses: int = 1
    expires_in_hours: Optional[int] = None


@app.post("/admin/api/invites")
async def admin_create_invite(
    raw_request: Request,
    request: CreateInviteRequest,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Create a new invite token. Requires admin session.

    Invite email is required so invited users have durable server-side
    identity from the start. Email delivery remains optional: when
    send_email is true, send the invite link via the configured email
    provider. Otherwise the admin can copy and share the link manually.
    """
    email = request.email.strip().lower()
    if not email:
        raise HTTPException(status_code=400, detail="Email is required.")
    expires = request.expires_in_hours if request.expires_in_hours is not None else DEFAULT_INVITE_EXPIRY_HOURS
    token, invite_id = await invite.create_invite(
        created_by=user.user_id,
        label=request.label,
        email=email,
        max_uses=request.max_uses,
        expires_in_hours=expires,
    )

    email_sent = False
    if request.send_email:
        base_url = web._zone_base_url(raw_request)
        try:
            await invite.send_invite_email(
                token=token,
                email=email,
                base_url=base_url,
                label=request.label,
            )
            email_sent = True
        except (ValueError, RuntimeError) as e:
            # Invite was created but email failed. Return the token so
            # the admin can share the link manually.
            base_url = web._zone_base_url(raw_request)
            return {
                "id": invite_id,
                "token": token,
                "invite_url": f"{base_url}/invite/{token}",
                "email": email,
                "email_sent": False,
                "email_error": str(e),
            }

    base_url = web._zone_base_url(raw_request)
    return {
        "id": invite_id,
        "token": token,
        "invite_url": f"{base_url}/invite/{token}",
        "email": email,
        "email_sent": email_sent,
    }


@app.get("/admin/api/invites")
async def admin_list_invites(
    raw_request: Request,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """List all invite tokens. Requires admin session.

    Returns invite_url for each invite (if token is available) and a
    derived status field: 'pending', 'used', 'expired', or 'revoked'.
    """
    invites = await invite.list_invites()
    base_url = web._zone_base_url(raw_request)
    now = datetime.now(timezone.utc)

    result = []
    for inv in invites:
        # Derive status from invite state.
        if inv.revoked:
            status = "revoked"
        elif inv.use_count >= inv.max_uses:
            status = "used"
        elif inv.expires_at is not None and now >= inv.expires_at:
            status = "expired"
        else:
            status = "pending"

        # Build invite_url if token is available.
        invite_url = f"{base_url}/invite/{inv.token}" if inv.token else None

        result.append({
            "id": inv.id,
            "label": inv.label,
            "email": inv.email,
            "invite_url": invite_url,
            "status": status,
            "created_at": inv.created_at.isoformat(),
            "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
            "max_uses": inv.max_uses,
            "use_count": inv.use_count,
            "revoked": inv.revoked,
        })

    return result


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


@app.delete("/admin/api/users/{target_user_id}")
async def admin_remove_user(
    target_user_id: str,
    user: auth.AuthUser = Depends(admin.require_admin),
):
    """Remove a non-admin user from the zone. Requires admin session."""
    if target_user_id == user.user_id:
        raise HTTPException(status_code=400, detail="You cannot remove yourself")

    if await admin.is_admin(target_user_id):
        raise HTTPException(status_code=400, detail="You cannot remove another admin")

    pool = db.get_pool()
    async with pool.connection() as conn:
        session_result = await conn.execute(
            'DELETE FROM auth_session WHERE "userId" = %s',
            (target_user_id,),
        )
        account_result = await conn.execute(
            'DELETE FROM auth_account WHERE "userId" = %s',
            (target_user_id,),
        )
        user_result = await conn.execute(
            'DELETE FROM auth_user WHERE id = %s RETURNING id',
            (target_user_id,),
        )
        deleted_user = await user_result.fetchone()

    if deleted_user is None:
        raise HTTPException(status_code=404, detail="User not found")

    return {
        "ok": True,
        "user_id": target_user_id,
        "sessions_deleted": session_result.rowcount,
        "accounts_deleted": account_result.rowcount,
    }


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
        is_placeholder = email and email.endswith("@placeholder.freeflow.local")
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


# ---------------------------------------------------------------------------
# /api/auth/* — proxy unmatched auth routes to better-auth (Node.js)
# ---------------------------------------------------------------------------

_AUTH_PROXY_BASE = "http://localhost:3456"


@app.api_route(
    "/api/auth/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    dependencies=[Depends(ratelimit.require_auth_limit)],
)
async def auth_proxy(request: Request, path: str):
    """Forward unmatched /api/auth/* requests to the Node.js auth service.

    Routes defined above (redeem-invite, capabilities) take priority.
    This catch-all proxies everything else, including better-auth's
    email-otp, change-email, sign-in, and session endpoints.
    """
    target_url = f"{_AUTH_PROXY_BASE}/api/auth/{path}"

    # Forward query string if present.
    if request.url.query:
        target_url = f"{target_url}?{request.url.query}"

    body = await request.body()

    # Forward relevant headers (content-type, authorization, cookies).
    forward_headers = {}
    if "content-type" in request.headers:
        forward_headers["content-type"] = request.headers["content-type"]
    if "authorization" in request.headers:
        forward_headers["authorization"] = request.headers["authorization"]
    if "cookie" in request.headers:
        forward_headers["cookie"] = request.headers["cookie"]

    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.request(
            method=request.method,
            url=target_url,
            content=body,
            headers=forward_headers,
        )

    # Forward the response, including headers the client may need
    # (set-auth-token, set-cookie, etc.).
    excluded = {"transfer-encoding", "content-encoding", "content-length"}
    response_headers = {
        k: v
        for k, v in resp.headers.items()
        if k.lower() not in excluded
    }

    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=response_headers,
    )


Node.start(http_server=HttpServer(app=app))
