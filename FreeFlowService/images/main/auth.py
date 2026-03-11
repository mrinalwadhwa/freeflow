"""Request authentication via better-auth session tokens.

Session tokens are validated by calling the Node.js better-auth
process internally.
"""

import os
from dataclasses import dataclass
from typing import Optional

import httpx
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

AUTH_SESSION_URL = "http://localhost:3456/api/auth/get-session"

_security = HTTPBearer(auto_error=False)

# Reusable async client for internal auth calls. Created once per
# process and reused across requests to avoid connection overhead.
_http_client: Optional[httpx.AsyncClient] = None


def _get_client() -> httpx.AsyncClient:
    """Return the shared httpx client, creating it on first use."""
    global _http_client
    if _http_client is None:
        _http_client = httpx.AsyncClient(timeout=5.0)
    return _http_client


@dataclass
class AuthUser:
    """Authenticated user context attached to each request."""

    user_id: str


async def _validate_session_token(token: str) -> Optional[AuthUser]:
    """Validate a session token via the better-auth service.

    Call GET http://localhost:3456/api/auth/get-session with the token
    forwarded in the Authorization header. Return an AuthUser on
    success, None on failure.
    """
    client = _get_client()
    try:
        resp = await client.get(
            AUTH_SESSION_URL,
            headers={"Authorization": f"Bearer {token}"},
        )
    except httpx.RequestError as e:
        print(f"[auth] Session validation request failed: {e}")
        return None

    if resp.status_code != 200:
        return None

    try:
        data = resp.json()
    except Exception:
        return None

    if not isinstance(data, dict):
        return None

    # better-auth returns { session: {...}, user: { id, email, ... } }
    user = data.get("user")
    if not user or not user.get("id"):
        return None

    return AuthUser(user_id=user["id"])


async def require_auth(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_security),
) -> AuthUser:
    """FastAPI dependency that authenticates via session token.

    Check order:
    1. If a Bearer token is present, validate as a better-auth session
       token.
    2. If no Bearer token, check for an auth_token cookie (web
       dashboard sessions).
    3. If all fail, raise 401.
    """
    token = None
    if credentials is not None:
        token = credentials.credentials
    else:
        # Fall back to session cookie for browser-based admin pages.
        token = request.cookies.get("auth_token")

    if not token:
        raise HTTPException(status_code=401, detail="Missing authentication")

    # Session token validation via better-auth.
    user = await _validate_session_token(token)
    if user is not None:
        return user

    raise HTTPException(status_code=401, detail="Invalid or expired token")


async def verify_ws_auth(authorization: Optional[str]) -> Optional[AuthUser]:
    """Validate a WebSocket Authorization value.

    Accept "Bearer <token>" format or a bare token. Return an AuthUser
    on success, None on failure. Used by the /stream endpoint to
    authenticate the connection before accepting audio.
    """
    if not authorization:
        return None

    # Extract token from "Bearer <token>" format.
    token = authorization
    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        token = parts[1]

    # Session token validation.
    return await _validate_session_token(token)


async def check_auth_health() -> bool:
    """Return True if the better-auth service is reachable."""
    client = _get_client()
    try:
        resp = await client.get("http://localhost:3456/api/auth/ok", timeout=2.0)
        return resp.status_code == 200
    except Exception:
        return False
