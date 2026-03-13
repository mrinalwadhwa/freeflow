"""Invite token management.

Create, redeem, revoke, and list invite tokens stored in PostgreSQL.
Tokens are 32-byte random hex strings, stored as SHA-256 hashes.
Redemption validates the token and calls better-auth to create a user
and session. Email-invites send the invite link directly to the
recipient via the configured email provider.
"""

import hashlib
import hmac
import os
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

import admin
import db
import email_config

AUTH_BASE_URL = "http://localhost:3456"
BOOTSTRAP_TOKEN = os.environ.get("BOOTSTRAP_TOKEN", "")


def _hash_token(token: str) -> str:
    """Return the SHA-256 hex digest of a token."""
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass
class Invite:
    """An invite token record."""

    id: int
    token_hash: str
    token: Optional[str]
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
                token           TEXT,
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
        # Add token column if it doesn't exist (migration for existing tables).
        await conn.execute("""
            ALTER TABLE invite_tokens
            ADD COLUMN IF NOT EXISTS token TEXT
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
                INSERT INTO invite_tokens (token_hash, token, label, email, created_by, max_uses, expires_at)
                VALUES (%s, %s, %s, %s, %s, %s, now() + make_interval(hours => %s))
                RETURNING id
                """,
                (token_hash, token, label, email, created_by, max_uses, expires_in_hours),
            )
        else:
            row = await conn.execute(
                """
                INSERT INTO invite_tokens (token_hash, token, label, email, created_by, max_uses)
                VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (token_hash, token, label, email, created_by, max_uses),
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
            """SELECT id, token_hash, token, label, email, created_by,
                      created_at, expires_at, max_uses, use_count, revoked
               FROM invite_tokens WHERE token_hash = %s""",
            (token_hash,),
        )
        result = await row.fetchone()

    if result is None:
        raise ValueError("Invalid invite token")

    invite = Invite(
        id=result[0],
        token_hash=result[1],
        token=result[2],
        label=result[3],
        email=result[4],
        created_by=result[5],
        created_at=result[6],
        expires_at=result[7],
        max_uses=result[8],
        use_count=result[9],
        revoked=result[10],
    )

    if invite.revoked:
        raise ValueError("Invite has been revoked")

    if invite.use_count >= invite.max_uses:
        raise ValueError("Invite has been fully used")

    now = datetime.now(timezone.utc)
    if invite.expires_at is not None and now >= invite.expires_at:
        raise ValueError("Invite has expired")

    return invite


async def _create_session_for_user(user_id: str) -> str:
    """Create a new better-auth session for an existing user.

    Inserts a session directly into the auth_session table, bypassing
    the sign-in endpoint entirely. This avoids password issues (the
    original password was a random throwaway from invite redemption).

    The token format matches better-auth's bearer plugin expectations:
    an opaque string that resolves via GET /api/auth/get-session.
    """
    session_id = secrets.token_hex(16)
    session_token = secrets.token_hex(32)
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(days=7)

    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute(
            """
            INSERT INTO auth_session (id, "expiresAt", token, "createdAt", "updatedAt", "userId")
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (session_id, expires_at, session_token, now, now, user_id),
        )

    return session_token


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

    The BOOTSTRAP_TOKEN is a special one-time token that marks the
    first redeemer as admin. Regular tokens create normal users.
    """
    is_bootstrap = bool(BOOTSTRAP_TOKEN) and hmac.compare_digest(token, BOOTSTRAP_TOKEN)

    if is_bootstrap:
        # Check if an admin already exists.
        pool = db.get_pool()
        async with pool.connection() as conn:
            result = await conn.execute(
                "SELECT user_id FROM admin_users LIMIT 1"
            )
            row = await result.fetchone()
        if row is not None:
            # Admin exists. Return a fresh session for the existing
            # admin instead of rejecting. This handles sign-out →
            # re-sign-in: the zone still has the admin from the
            # previous session, and the bootstrap token hasn't changed,
            # so zone_lifecycle didn't clear the data.
            admin_user_id = row[0]
            session_token = await _create_session_for_user(admin_user_id)
            return RedeemResult(
                session_token=session_token,
                user_id=admin_user_id,
                has_email=False,
            )
    else:
        invite = await _validate_token(token)

    # Determine email for the new user.
    if not is_bootstrap:
        if not invite.email:
            raise ValueError("Invite is missing an email address")
        email = invite.email
        has_email = True
        label = invite.label or "Invited user"
    else:
        has_email = False
        label = "Admin"
        email = f"admin-{secrets.token_hex(8)}@placeholder.freeflow.local"

    user_id, session_token = await _create_user_via_auth(email, label)

    if is_bootstrap:
        await admin.mark_admin(user_id)

    if not is_bootstrap:
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


async def send_invite_email(
    token: str,
    email: str,
    base_url: str,
    label: Optional[str] = None,
) -> None:
    """Send an invite link to an email address via the configured provider.

    Raise ValueError if email is not configured. Raise RuntimeError if
    the email send fails.
    """
    config = await email_config.get_config()
    if config is None or not config.is_configured or not config.verified:
        raise ValueError("Email is not configured. Set up an email provider first.")

    invite_url = f"{base_url}/invite/{token}"
    app_name = "FreeFlow"
    recipient_label = label or "there"

    subject = f"You're invited to {app_name}"
    text = (
        f"Hi {recipient_label},\n\n"
        f"You've been invited to use {app_name}. "
        f"Click the link below to get started:\n\n"
        f"{invite_url}\n\n"
        f"This link will help you set up {app_name} on your Mac."
    )
    html = (
        f"<p>Hi {recipient_label},</p>"
        f"<p>You've been invited to use <strong>{app_name}</strong>.</p>"
        f'<p style="margin:24px 0">'
        f'<a href="{invite_url}" style="display:inline-block;padding:12px 24px;'
        f"background:#0066cc;color:#fff;border-radius:8px;text-decoration:none;"
        f'font-weight:500">Get started with {app_name}</a></p>'
        f'<p style="color:#6e6e73;font-size:14px">'
        f"Or copy this link: {invite_url}</p>"
    )

    api_key = config.api_key
    from_address = config.from_address

    if config.provider == "resend":
        await email_config._send_via_resend(
            api_key, from_address, email, subject, text, html,
        )
    elif config.provider == "sendgrid":
        await email_config._send_via_sendgrid(
            api_key, from_address, email, subject, text, html,
        )
    else:
        raise RuntimeError(f"Unsupported email provider: {config.provider}")


async def list_invites() -> list[Invite]:
    """Return all invite tokens, newest first."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            """SELECT id, token_hash, token, label, email, created_by,
                      created_at, expires_at, max_uses, use_count, revoked
               FROM invite_tokens ORDER BY created_at DESC"""
        )
        rows = await result.fetchall()

    return [
        Invite(
            id=row[0],
            token_hash=row[1],
            token=row[2],
            label=row[3],
            email=row[4],
            created_by=row[5],
            created_at=row[6],
            expires_at=row[7],
            max_uses=row[8],
            use_count=row[9],
            revoked=row[10],
        )
        for row in rows
    ]
