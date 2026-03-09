"""Email configuration management.

Store and retrieve email provider settings (Resend, SendGrid) for OTP
delivery. The api_key is encrypted at rest using AES-256-CBC with
BETTER_AUTH_SECRET as the key material. The email_config table holds a
single row (upsert on save).

Provide helpers for the admin settings endpoints and for reading the
current config to drive capabilities responses.
"""

import hashlib
import os
import secrets as stdlib_secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

import db

BETTER_AUTH_SECRET = os.environ.get("BETTER_AUTH_SECRET", "")


# ------------------------------------------------------------------
# Encryption helpers
# ------------------------------------------------------------------

def _derive_key() -> bytes:
    """Derive a 32-byte AES key from BETTER_AUTH_SECRET via SHA-256."""
    return hashlib.sha256(BETTER_AUTH_SECRET.encode()).digest()


def encrypt_api_key(plaintext: str) -> str:
    """Encrypt an API key with AES-256-CBC.

    Return "iv_hex:ciphertext_hex". The IV is random per encryption so
    the same plaintext produces different ciphertext each time.
    """
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.padding import PKCS7

    key = _derive_key()
    iv = stdlib_secrets.token_bytes(16)

    padder = PKCS7(128).padder()
    padded = padder.update(plaintext.encode()) + padder.finalize()

    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    encryptor = cipher.encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()

    return f"{iv.hex()}:{ciphertext.hex()}"


def decrypt_api_key(stored: str) -> str:
    """Decrypt an API key stored as "iv_hex:ciphertext_hex".

    If the value does not contain a colon, return it as-is (plaintext
    fallback for backward compatibility or initial setup).
    """
    if not stored or ":" not in stored:
        return stored or ""

    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.padding import PKCS7

    try:
        iv_hex, enc_hex = stored.split(":", 1)
        key = _derive_key()
        iv = bytes.fromhex(iv_hex)

        cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
        decryptor = cipher.decryptor()
        padded = decryptor.update(bytes.fromhex(enc_hex)) + decryptor.finalize()

        unpadder = PKCS7(128).unpadder()
        plaintext = unpadder.update(padded) + unpadder.finalize()
        return plaintext.decode()
    except Exception:
        return stored


# ------------------------------------------------------------------
# Data model
# ------------------------------------------------------------------

@dataclass
class EmailConfig:
    """Email provider configuration."""

    id: int
    provider: str
    api_key_encrypted: str
    from_address: str
    verified: bool
    require_email: bool
    require_email_deadline: Optional[datetime]
    updated_at: datetime

    @property
    def api_key(self) -> str:
        """Decrypt and return the API key."""
        return decrypt_api_key(self.api_key_encrypted)

    @property
    def is_configured(self) -> bool:
        """Whether email sending is configured (provider + key + from)."""
        return bool(self.provider and self.api_key_encrypted and self.from_address)


# ------------------------------------------------------------------
# Table management
# ------------------------------------------------------------------

async def ensure_table():
    """Create the email_config table if it does not exist."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS email_config (
                id                      SERIAL PRIMARY KEY,
                provider                TEXT NOT NULL,
                api_key                 TEXT NOT NULL,
                from_address            TEXT NOT NULL,
                verified                BOOLEAN NOT NULL DEFAULT FALSE,
                require_email           BOOLEAN NOT NULL DEFAULT FALSE,
                require_email_deadline  TIMESTAMPTZ,
                updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)


# ------------------------------------------------------------------
# Read
# ------------------------------------------------------------------

async def get_config() -> Optional[EmailConfig]:
    """Return the current email configuration, or None if not set."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            "SELECT id, provider, api_key, from_address, verified, "
            "require_email, require_email_deadline, updated_at "
            "FROM email_config ORDER BY id LIMIT 1"
        )
        row = await result.fetchone()

    if row is None:
        return None

    return EmailConfig(
        id=row[0],
        provider=row[1],
        api_key_encrypted=row[2],
        from_address=row[3],
        verified=row[4],
        require_email=row[5],
        require_email_deadline=row[6],
        updated_at=row[7],
    )


async def is_email_configured() -> bool:
    """Return True if email sending is configured and verified."""
    config = await get_config()
    return config is not None and config.is_configured and config.verified


# ------------------------------------------------------------------
# Write
# ------------------------------------------------------------------

async def save_config(
    provider: str,
    api_key: str,
    from_address: str,
) -> EmailConfig:
    """Save email provider configuration (upsert).

    The api_key is encrypted before storage. The verified flag is set
    to False until a test email succeeds.
    """
    encrypted_key = encrypt_api_key(api_key)
    now = datetime.now(timezone.utc)

    pool = db.get_pool()
    async with pool.connection() as conn:
        # Check if a row exists.
        result = await conn.execute("SELECT id FROM email_config LIMIT 1")
        existing = await result.fetchone()

        if existing:
            await conn.execute(
                """
                UPDATE email_config
                SET provider = %s, api_key = %s, from_address = %s,
                    verified = FALSE, updated_at = %s
                WHERE id = %s
                """,
                (provider, encrypted_key, from_address, now, existing[0]),
            )
            row_id = existing[0]
        else:
            result = await conn.execute(
                """
                INSERT INTO email_config (provider, api_key, from_address, verified, updated_at)
                VALUES (%s, %s, %s, FALSE, %s)
                RETURNING id
                """,
                (provider, encrypted_key, from_address, now),
            )
            row = await result.fetchone()
            row_id = row[0]

    return EmailConfig(
        id=row_id,
        provider=provider,
        api_key_encrypted=encrypted_key,
        from_address=from_address,
        verified=False,
        require_email=False,
        require_email_deadline=None,
        updated_at=now,
    )


async def mark_verified():
    """Mark the current email configuration as verified."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute(
            "UPDATE email_config SET verified = TRUE, updated_at = now()"
        )


async def save_require_email(
    require: bool,
    grace_period_days: Optional[int] = None,
) -> None:
    """Update the require_email policy.

    When require is True, set the deadline to now + grace_period_days.
    When require is False, clear the deadline.
    """
    pool = db.get_pool()
    async with pool.connection() as conn:
        if require and grace_period_days is not None:
            await conn.execute(
                """
                UPDATE email_config
                SET require_email = TRUE,
                    require_email_deadline = now() + make_interval(days => %s),
                    updated_at = now()
                """,
                (grace_period_days,),
            )
        elif require:
            await conn.execute(
                """
                UPDATE email_config
                SET require_email = TRUE,
                    require_email_deadline = COALESCE(require_email_deadline, now() + interval '14 days'),
                    updated_at = now()
                """
            )
        else:
            await conn.execute(
                """
                UPDATE email_config
                SET require_email = FALSE,
                    require_email_deadline = NULL,
                    updated_at = now()
                """
            )


# ------------------------------------------------------------------
# Test email
# ------------------------------------------------------------------

async def send_test_email(to_address: str) -> str:
    """Send a test email using the current configuration.

    Return a success message or raise an exception on failure.
    """
    config = await get_config()
    if config is None or not config.is_configured:
        raise ValueError("Email is not configured")

    api_key = config.api_key
    provider = config.provider
    from_address = config.from_address

    subject = "Voice email configuration test"
    text = "This is a test email from your Voice service. If you received this, email sending is working correctly."
    html = (
        "<p>This is a test email from your Voice service.</p>"
        '<p style="color:#34c759;font-weight:600">Email sending is working correctly.</p>'
    )

    if provider == "resend":
        await _send_via_resend(api_key, from_address, to_address, subject, text, html)
    elif provider == "sendgrid":
        await _send_via_sendgrid(api_key, from_address, to_address, subject, text, html)
    else:
        raise ValueError(f"Unsupported email provider: {provider}")

    # Mark as verified after a successful test send.
    await mark_verified()
    return f"Test email sent to {to_address} via {provider}"


async def _send_via_resend(
    api_key: str,
    from_address: str,
    to_address: str,
    subject: str,
    text: str,
    html: str,
) -> None:
    """Send an email via the Resend REST API."""
    import httpx

    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            "https://api.resend.com/emails",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "from": from_address,
                "to": [to_address],
                "subject": subject,
                "text": text,
                "html": html,
            },
        )
    if resp.status_code >= 400:
        raise RuntimeError(f"Resend API error {resp.status_code}: {resp.text}")


async def _send_via_sendgrid(
    api_key: str,
    from_address: str,
    to_address: str,
    subject: str,
    text: str,
    html: str,
) -> None:
    """Send an email via the SendGrid REST API."""
    import httpx

    payload = {
        "personalizations": [{"to": [{"email": to_address}]}],
        "from": {"email": from_address},
        "subject": subject,
        "content": [
            {"type": "text/plain", "value": text},
            {"type": "text/html", "value": html},
        ],
    }

    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            "https://api.sendgrid.com/v3/mail/send",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
    # SendGrid returns 202 on success.
    if resp.status_code >= 400:
        raise RuntimeError(f"SendGrid API error {resp.status_code}: {resp.text}")


# ------------------------------------------------------------------
# Capabilities helper
# ------------------------------------------------------------------

async def get_capabilities() -> dict:
    """Return email-related capabilities for the /api/auth/capabilities endpoint."""
    config = await get_config()

    email_otp = False
    require_email = False
    require_email_deadline = None

    if config is not None and config.is_configured and config.verified:
        email_otp = True
        require_email = config.require_email
        if config.require_email and config.require_email_deadline:
            require_email_deadline = config.require_email_deadline.isoformat()

    return {
        "email_otp": email_otp,
        "require_email": require_email,
        "require_email_deadline": require_email_deadline,
    }
