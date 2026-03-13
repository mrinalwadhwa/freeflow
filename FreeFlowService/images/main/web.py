"""Serve zone web pages via Jinja2 templates.

Provide routes for the invite landing page and a redirect from the
zone root to the project repository.
"""

import os
from typing import Optional

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape

import admin
import auth
import invite



_TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "templates")

_env = Environment(
    loader=FileSystemLoader(_TEMPLATES_DIR),
    autoescape=select_autoescape(["html"]),
    enable_async=True,
)

# Public routes (redirect, invite landing).
public_router = APIRouter()


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


# ------------------------------------------------------------------
# Public routes
# ------------------------------------------------------------------


@public_router.get("/")
async def homepage():
    """Redirect the zone root to the project repository."""
    return RedirectResponse(
        url="https://github.com/build-trust/freeflow",
        status_code=302,
    )


@public_router.get("/invite/{token}", response_class=HTMLResponse)
async def invite_landing(request: Request, token: str):
    """Invite landing page.

    Show a page that attempts to open the app via URL scheme. If the
    app is not installed, show download instructions.
    """
    base_url = _zone_base_url(request)
    connect_url = f"freeflow://connect?url={base_url}&token={token}"

    # Check if the token is valid (show error if expired/revoked).
    token_valid = True
    token_error = None
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
    )
