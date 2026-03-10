"""Serve zone web pages via Jinja2 templates.

Provide routes for the public homepage, invite landing page, and admin
dashboard pages. Templates live in the templates/ directory. Static
files (CSS, JS) are served from static/.

Admin pages require an authenticated admin session. The homepage shows
a public view for visitors and a dashboard view for signed-in admins.
The invite landing page detects ADMIN_TOKEN redemption and offers
browser-based setup that sets a session cookie.
"""

import os
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape

import admin
import auth
import db
import invite

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")

_TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "templates")

_env = Environment(
    loader=FileSystemLoader(_TEMPLATES_DIR),
    autoescape=select_autoescape(["html"]),
    enable_async=True,
)

# Public routes (homepage, invite landing).
public_router = APIRouter()

# Admin routes (dashboard, invites, users, settings).
admin_router = APIRouter(prefix="/admin")


def _zone_base_url(request: Request) -> str:
    """Return the zone base URL from the request."""
    scheme = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("host", request.url.hostname or "localhost")
    # Production traffic always terminates TLS at the load balancer, but
    # x-forwarded-proto may still report "http". Force HTTPS for any
    # non-localhost host to ensure freeflow:// connect URLs and WKWebView
    # page loads use the correct scheme.
    if host != "localhost" and not host.startswith("127."):
        scheme = "https"
    return f"{scheme}://{host}"


async def _render(template_name: str, **context) -> HTMLResponse:
    """Render a Jinja2 template and return an HTMLResponse."""
    template = _env.get_template(template_name)
    html = await template.render_async(**context)
    return HTMLResponse(html)


async def _get_session_user(request: Request) -> Optional[auth.AuthUser]:
    """Extract and validate a session from the request cookie or header.

    Return an AuthUser on success, None if no valid session. This does
    not raise on failure (used for pages that show different content
    based on auth state).
    """
    # Check for session cookie first (browser sessions).
    token = request.cookies.get("auth_token")

    # Fall back to Authorization header.
    if not token:
        authorization = request.headers.get("authorization", "")
        if authorization.lower().startswith("bearer "):
            token = authorization[7:]

    if not token:
        return None

    # Validate via better-auth.
    user = await auth._validate_session_token(token)
    return user


async def _require_admin_web(request: Request) -> auth.AuthUser:
    """Require an authenticated admin for web page access.

    Redirect to / if not authenticated or not an admin.
    """
    user = await _get_session_user(request)
    if user is None:
        raise HTTPException(status_code=303, headers={"Location": "/"})

    if not await admin.is_admin(user.user_id):
        raise HTTPException(status_code=303, headers={"Location": "/"})

    return user


# ------------------------------------------------------------------
# Public routes
# ------------------------------------------------------------------


@public_router.get("/account/add-email", response_class=HTMLResponse)
async def account_add_email(request: Request):
    """Add email page for Tier 2 email recovery.

    Displayed in the macOS app's WKWebView when the admin enables email
    and the user has no email on file. Single-page multi-step flow:
    enter email, receive OTP, verify. The variant query parameter
    controls the messaging: voluntary, grace, or enforced.

    Requires a valid session (the user is already signed in).
    """
    return await _render("account/add-email.html")


@public_router.get("/account/sign-in", response_class=HTMLResponse)
async def account_sign_in(request: Request):
    """Email OTP sign-in page for session recovery.

    Displayed in the macOS app's WKWebView when the user's session has
    expired and they have an email on file. Single-page multi-step flow:
    email input, OTP input, success. The email query parameter pre-fills
    the email field. The has_email query parameter controls whether to
    show the sign-in form or a fallback message.

    No session required (the user's session has expired).
    """
    return await _render("account/sign-in.html")


@public_router.get("/settings/", response_class=HTMLResponse)
async def settings_page(request: Request):
    """Settings page for the macOS app WKWebView.

    Displays sound, hotkey, language, and microphone settings. All state
    is local to the app (read/written via the native bridge), so no
    server-side auth or data is needed. The page is a UI shell that
    delegates all reads and writes to the native side.
    """
    return await _render("settings/index.html")


@public_router.get("/onboarding/", response_class=HTMLResponse)
async def onboarding(request: Request):
    """Single-page onboarding flow for the macOS app WKWebView.

    All 6 screens are rendered in one HTML document. JavaScript manages
    step transitions without page refreshes. The token query parameter
    is passed through for invite redemption on screen 1.

    No authentication required. The onboarding page is a UI shell that
    delegates sensitive operations (token redemption, Keychain writes,
    permission grants) to the native bridge.
    """
    base_url = _zone_base_url(request)

    # Check if the visitor has an admin session (used to show the
    # "Share with your team" section on the done screen).
    is_admin_user = False
    user = await _get_session_user(request)
    if user is not None:
        is_admin_user = await admin.is_admin(user.user_id)

    return await _render(
        "onboarding/index.html",
        base_url=base_url,
        is_admin=is_admin_user,
    )


@public_router.get("/", response_class=HTMLResponse)
async def homepage(request: Request):
    """Zone homepage.

    Show a public page for visitors (download link, invite prompt).
    Show an admin dashboard when signed in with an admin session.
    """
    user = await _get_session_user(request)
    admin_user = None

    if user is not None and await admin.is_admin(user.user_id):
        admin_user = user

        # Gather stats for the admin dashboard view.
        try:
            invite_list = await invite.list_invites()
            active_invites = [
                i for i in invite_list
                if not i.revoked and i.use_count < i.max_uses
            ]
        except Exception:
            invite_list = []
            active_invites = []

        try:
            pool = db.get_pool()
            async with pool.connection() as conn:
                result = await conn.execute(
                    'SELECT COUNT(*) FROM auth_user'
                )
                row = await result.fetchone()
                user_count = row[0] if row else 0
        except Exception:
            user_count = 0

        return await _render(
            "index.html",
            admin_user=admin_user,
            user_count=user_count,
            invite_count=len(active_invites),
            total_invites=len(invite_list),
            base_url=_zone_base_url(request),
        )

    return await _render(
        "index.html",
        admin_user=None,
        base_url=_zone_base_url(request),
    )


@public_router.get("/invite/{token}", response_class=HTMLResponse)
async def invite_landing(request: Request, token: str):
    """Invite landing page.

    Show a page that attempts to open the app via URL scheme. If the
    app is not installed, show download instructions.

    When the token is the ADMIN_TOKEN, show a browser-based redemption
    flow that creates the admin user, sets a session cookie, and
    redirects to the dashboard.
    """
    base_url = _zone_base_url(request)
    connect_url = f"freeflow://connect?url={base_url}&token={token}"

    # Detect whether this is the ADMIN_TOKEN for browser-based admin
    # setup. The admin redeems in the browser to get a session cookie
    # for the dashboard.
    is_admin_token = bool(ADMIN_TOKEN) and token == ADMIN_TOKEN

    # Check if the token is valid (show error if expired/revoked).
    # ADMIN_TOKEN is not stored in the database, so skip validation.
    token_valid = True
    token_error = None
    if not is_admin_token:
        try:
            await invite._validate_token(token)
        except ValueError as e:
            token_valid = False
            token_error = str(e)

    # Check if the visitor is already a signed-in admin.
    user = await _get_session_user(request)
    is_admin_user = user is not None and await admin.is_admin(user.user_id)

    return await _render(
        "invite.html",
        token=token,
        token_valid=token_valid,
        token_error=token_error,
        connect_url=connect_url,
        base_url=base_url,
        admin_user=is_admin_user,
        is_admin_token=is_admin_token,
    )


@public_router.post("/invite/{token}/redeem")
async def invite_redeem_browser(request: Request, token: str):
    """Redeem an invite token in the browser and set a session cookie.

    Called by the invite landing page JS when the admin clicks "Set up
    in browser". Redeem the token via the same invite.redeem() path,
    then set the session token as an auth_token cookie and redirect
    to the homepage (which shows the admin dashboard).
    """
    try:
        result = await invite.redeem(token)
    except ValueError as e:
        return await _render(
            "invite.html",
            token=token,
            token_valid=False,
            token_error=str(e),
            connect_url="",
            base_url=_zone_base_url(request),
            admin_user=False,
            is_admin_token=False,
        )
    except RuntimeError as e:
        return await _render(
            "invite.html",
            token=token,
            token_valid=False,
            token_error=f"Setup failed: {e}",
            connect_url="",
            base_url=_zone_base_url(request),
            admin_user=False,
            is_admin_token=False,
        )

    response = RedirectResponse(url="/", status_code=303)
    response.set_cookie(
        key="auth_token",
        value=result.session_token,
        httponly=True,
        secure=request.url.scheme == "https",
        samesite="lax",
        max_age=60 * 60 * 24 * 30,  # 30 days
    )
    return response


# ------------------------------------------------------------------
# Admin routes
# ------------------------------------------------------------------


@admin_router.get("/", response_class=HTMLResponse)
async def admin_dashboard(request: Request):
    """Admin dashboard with overview and quick links."""
    user = await _require_admin_web(request)

    try:
        invite_list = await invite.list_invites()
        active_invites = [
            i for i in invite_list
            if not i.revoked and i.use_count < i.max_uses
        ]
        used_invites = [
            i for i in invite_list
            if i.use_count >= i.max_uses and not i.revoked
        ]
        revoked_invites = [i for i in invite_list if i.revoked]
    except Exception:
        invite_list = []
        active_invites = []
        used_invites = []
        revoked_invites = []

    try:
        pool = db.get_pool()
        async with pool.connection() as conn:
            result = await conn.execute(
                'SELECT COUNT(*) FROM auth_user'
            )
            row = await result.fetchone()
            user_count = row[0] if row else 0

            result = await conn.execute(
                """SELECT COUNT(*) FROM auth_user
                   WHERE email NOT LIKE '%%@placeholder.freeflow.local'"""
            )
            row = await result.fetchone()
            with_email_count = row[0] if row else 0
    except Exception:
        user_count = 0
        with_email_count = 0

    return await _render(
        "admin/dashboard.html",
        admin_user=user,
        nav_active="dashboard",
        user_count=user_count,
        with_email_count=with_email_count,
        invite_count=len(active_invites),
        used_invite_count=len(used_invites),
        revoked_invite_count=len(revoked_invites),
        base_url=_zone_base_url(request),
    )


@admin_router.get("/invites", response_class=HTMLResponse)
async def admin_invites_page(request: Request):
    """Invite management page with generator and list."""
    user = await _require_admin_web(request)

    try:
        invite_list = await invite.list_invites()
    except Exception:
        invite_list = []

    base_url = _zone_base_url(request)

    return await _render(
        "admin/invites.html",
        admin_user=user,
        nav_active="invites",
        invites=invite_list,
        base_url=base_url,
    )


@admin_router.get("/users", response_class=HTMLResponse)
async def admin_users_page(request: Request):
    """User management page with user list and email status."""
    user = await _require_admin_web(request)

    try:
        pool = db.get_pool()
        async with pool.connection() as conn:
            result = await conn.execute(
                """SELECT id, name, email, "emailVerified", "createdAt"
                   FROM auth_user
                   ORDER BY "createdAt" DESC"""
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
                "created_at": created_at,
            })
    except Exception:
        users = []

    return await _render(
        "admin/users.html",
        admin_user=user,
        nav_active="users",
        users=users,
    )


@admin_router.get("/settings", response_class=HTMLResponse)
async def admin_settings_page(request: Request):
    """Settings page. Email configuration is a placeholder for Phase 1.6."""
    user = await _require_admin_web(request)

    return await _render(
        "admin/settings.html",
        admin_user=user,
        nav_active="settings",
    )
