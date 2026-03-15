"""Request authentication via better-auth session tokens.

Session tokens are validated by calling the Node.js better-auth
process internally.
"""

import os
from dataclasses import dataclass
from typing import Optional

import httpx
from fastapi import Depends, HTTPException
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


async def validate_session_token(token: str) -> Optional[AuthUser]:
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
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_security),
) -> AuthUser:
    """FastAPI dependency that authenticates via Bearer token.

    Requires a valid better-auth session token in the Authorization
    header.
    """
    if credentials is None:
        raise HTTPException(status_code=401, detail="Missing authentication")

    user = await validate_session_token(credentials.credentials)
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
    return await validate_session_token(token)


async def check_auth_health() -> bool:
    """Return True if the better-auth service is reachable."""
    client = _get_client()
    try:
        resp = await client.get("http://localhost:3456/api/auth/ok", timeout=2.0)
        return resp.status_code == 200
    except Exception:
        return False
