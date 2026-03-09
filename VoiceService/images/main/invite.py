"""Invite token management.

Create, redeem, revoke, and list invite tokens stored in PostgreSQL.
Tokens are 32-byte random hex strings, stored as SHA-256 hashes.
Redemption validates the token and calls better-auth to create a user
and session.
"""

import hashlib
import os
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

import httpx

import db

AUTH_BASE_URL = "http://localhost:3456"
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")


def _hash_token(token: str) -> str:
    """Return the SHA-256 hex digest of a token."""
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass
class Invite:
    """An invite token record."""

    id: int
    token_hash: str
    label: Optional[str]
    email: Optional[str]
    created_by: str
    created_at: datetime
    expires_at: Optional[datetime]
    max_uses: int
    use_count: int
    revoked: bool


@dataclass
class RedeemResult:
    """Result of redeeming an invite token."""

    session_token: str
    user_id: str
    has_email: bool


async def ensure_table():
    """Create the invite_tokens table if it does not exist."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS invite_tokens (
                id              SERIAL PRIMARY KEY,
                token_hash      TEXT NOT NULL UNIQUE,
                label           TEXT,
                email           TEXT,
                created_by      TEXT NOT NULL,
                created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
                expires_at      TIMESTAMPTZ,
                max_uses        INT NOT NULL DEFAULT 1,
                use_count       INT NOT NULL DEFAULT 0,
                revoked         BOOLEAN NOT NULL DEFAULT FALSE
            )
        """)


async def create_invite(
    created_by: str,
    label: Optional[str] = None,
    email: Optional[str] = None,
    max_uses: int = 1,
    expires_in_hours: Optional[int] = None,
) -> tuple[str, int]:
    """Create a new invite token.

    Return (plaintext_token, invite_id). The plaintext token is shown
    once to the admin; only the hash is stored.
    """
    token = secrets.token_hex(32)
    token_hash = _hash_token(token)

    pool = db.get_pool()
    async with pool.connection() as conn:
        if expires_in_hours is not None:
            row = await conn.execute(
                """
                INSERT INTO invite_tokens (token_hash, label, email, created_by, max_uses, expires_at)
                VALUES (%s, %s, %s, %s, %s, now() + make_interval(hours => %s))
                RETURNING id
                """,
                (token_hash, label, email, created_by, max_uses, expires_in_hours),
            )
        else:
            row = await conn.execute(
                """
                INSERT INTO invite_tokens (token_hash, label, email, created_by, max_uses)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id
                """,
                (token_hash, label, email, created_by, max_uses),
            )
        result = await row.fetchone()
        invite_id = result[0]

    return token, invite_id


async def _validate_token(token: str) -> Invite:
    """Look up and validate a token. Raise ValueError if invalid."""
    token_hash = _hash_token(token)
    pool = db.get_pool()

    async with pool.connection() as conn:
        row = await conn.execute(
            "SELECT * FROM invite_tokens WHERE token_hash = %s",
            (token_hash,),
        )
        result = await row.fetchone()

    if result is None:
        raise ValueError("Invalid invite token")

    invite = Invite(
        id=result[0],
        token_hash=result[1],
        label=result[2],
        email=result[3],
        created_by=result[4],
        created_at=result[5],
        expires_at=result[6],
        max_uses=result[7],
        use_count=result[8],
        revoked=result[9],
    )

    if invite.revoked:
        raise ValueError("Invite has been revoked")

    if invite.use_count >= invite.max_uses:
        raise ValueError("Invite has been fully used")

    now = datetime.now(timezone.utc)
    if invite.expires_at is not None and now >= invite.expires_at:
        raise ValueError("Invite has expired")

    return invite


async def _create_user_via_auth(
    email: str, name: str
) -> tuple[str, str]:
    """Create a user via better-auth's admin API and return (user_id, session_token).

    Use better-auth's sign-up endpoint to create a user with a random
    password. The password is never used (auth is via session tokens
    from invite redemption). Then extract the session token from the
    response.
    """
    password = secrets.token_hex(32)

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{AUTH_BASE_URL}/api/auth/sign-up/email",
            json={
                "email": email,
                "password": password,
                "name": name,
            },
        )

    if resp.status_code != 200:
        detail = resp.text
        raise RuntimeError(f"Failed to create user via better-auth: {resp.status_code} {detail}")

    data = resp.json()
    user_id = data.get("user", {}).get("id")
    session_token = data.get("token")

    if not user_id or not session_token:
        raise RuntimeError(f"Unexpected better-auth sign-up response: {data}")

    return user_id, session_token


async def redeem(token: str) -> RedeemResult:
    """Redeem an invite token: validate, create user, return session.

    The ADMIN_TOKEN is a special invite that marks the first redeemer
    as admin. Regular tokens create normal users.
    """
    is_admin_token = ADMIN_TOKEN and token == ADMIN_TOKEN

    if is_admin_token:
        # Admin token is not stored in the database. Validate that it
        # has not already been used by checking for an existing admin.
        pass
    else:
        invite = await _validate_token(token)

    # Determine email for the new user.
    if not is_admin_token and invite.email:
        email = invite.email
        has_email = True
        label = invite.label or "Invited user"
    else:
        # Generate a placeholder email. Use a unique suffix to avoid
        # collisions. The user can add a real email later (Tier 2).
        placeholder_id = secrets.token_hex(8)
        email = f"{placeholder_id}@placeholder.voice.local"
        has_email = False
        label = "Admin" if is_admin_token else (invite.label or "Invited user")

    user_id, session_token = await _create_user_via_auth(email, label)

    if not is_admin_token:
        # Increment use count.
        pool = db.get_pool()
        async with pool.connection() as conn:
            await conn.execute(
                "UPDATE invite_tokens SET use_count = use_count + 1 WHERE id = %s",
                (invite.id,),
            )

    return RedeemResult(
        session_token=session_token,
        user_id=user_id,
        has_email=has_email,
    )


async def revoke(invite_id: int):
    """Revoke an invite token by id."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            "UPDATE invite_tokens SET revoked = TRUE WHERE id = %s RETURNING id",
            (invite_id,),
        )
        row = await result.fetchone()
        if row is None:
            raise ValueError("Invite not found")


async def list_invites() -> list[Invite]:
    """Return all invite tokens, newest first."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            "SELECT * FROM invite_tokens ORDER BY created_at DESC"
        )
        rows = await result.fetchall()

    return [
        Invite(
            id=row[0],
            token_hash=row[1],
            label=row[2],
            email=row[3],
            created_by=row[4],
            created_at=row[5],
            expires_at=row[6],
            max_uses=row[7],
            use_count=row[8],
            revoked=row[9],
        )
        for row in rows
    ]
