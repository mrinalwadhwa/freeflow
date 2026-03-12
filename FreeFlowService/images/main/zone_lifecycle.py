"""Zone lifecycle management.

Detect re-provisioning by comparing the current BOOTSTRAP_TOKEN hash
against a stored value. When the token changes, Autonomy has deleted
and re-created the zone, but the RDS database retains tables
from the previous deployment. Clear stale data so the new zone can
bootstrap cleanly.

The zone_meta table stores key-value metadata. Currently the only key
is 'bootstrap_token_hash', set after each successful startup.
"""

import hashlib
import os

import db

BOOTSTRAP_TOKEN = os.environ.get("BOOTSTRAP_TOKEN", "")

# Tables managed by the Python process.
_PYTHON_TABLES = ["admin_users", "invite_tokens", "email_config"]

# Tables managed by better-auth (Node.js). These use the auth_ prefix
# configured in auth.mjs.
_AUTH_TABLES = ["auth_user", "auth_session", "auth_account", "auth_verification"]


def _hash_token(token: str) -> str:
    """Return the SHA-256 hex digest of a token."""
    return hashlib.sha256(token.encode()).hexdigest()


async def ensure_table():
    """Create the zone_meta table if it does not exist."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS zone_meta (
                key     TEXT PRIMARY KEY,
                value   TEXT NOT NULL
            )
        """)


async def _get_stored_hash() -> str | None:
    """Read the stored bootstrap token hash, or None if not set."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            "SELECT value FROM zone_meta WHERE key = 'bootstrap_token_hash'",
        )
        row = await result.fetchone()
    return row[0] if row else None


async def _set_stored_hash(token_hash: str):
    """Store the bootstrap token hash (upsert)."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute(
            """
            INSERT INTO zone_meta (key, value) VALUES ('bootstrap_token_hash', %s)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
            """,
            (token_hash,),
        )


async def _clear_stale_data():
    """Truncate all zone data tables for a fresh start.

    Truncate Python-managed tables and better-auth tables. Use
    CASCADE to handle foreign key constraints between auth tables.
    Ignore errors for tables that do not exist yet (first deploy
    before migrations have run). Each table uses a separate
    connection so a missing-table error does not poison subsequent
    statements.
    """
    pool = db.get_pool()
    for table in _PYTHON_TABLES + _AUTH_TABLES:
        try:
            async with pool.connection() as conn:
                await conn.execute(f"TRUNCATE TABLE {table} CASCADE")
            print(f"[zone_lifecycle] Truncated {table}")
        except Exception:
            # Table may not exist yet on first deploy.
            print(f"[zone_lifecycle] Skipped {table} (does not exist)")


async def check_reprovisioning():
    """Detect re-provisioning and clear stale data if needed.

    Call during startup, after the database pool is open but before
    the app begins serving requests.

    Logic:
    1. If BOOTSTRAP_TOKEN is empty, skip (local dev without a token).
    2. Read the stored bootstrap token hash from zone_meta.
    3. If the stored hash matches the current token, no action needed.
    4. If they differ (or no stored hash exists), check whether
       admin_users has any rows. If it does, this is a re-provisioning
       scenario: clear all stale data.
    5. Store the current token hash for next startup.
    """
    if not BOOTSTRAP_TOKEN:
        print("[zone_lifecycle] No BOOTSTRAP_TOKEN set, skipping re-provisioning check")
        return

    await ensure_table()

    current_hash = _hash_token(BOOTSTRAP_TOKEN)
    stored_hash = await _get_stored_hash()

    if stored_hash == current_hash:
        print("[zone_lifecycle] Bootstrap token unchanged, no re-provisioning detected")
        return

    # Token changed or no stored hash. Check if there is stale data.
    pool = db.get_pool()
    has_stale_admin = False
    try:
        async with pool.connection() as conn:
            result = await conn.execute("SELECT 1 FROM admin_users LIMIT 1")
            row = await result.fetchone()
            has_stale_admin = row is not None
    except Exception:
        # Table does not exist yet (first ever deploy). Nothing to clear.
        pass

    if has_stale_admin:
        print("[zone_lifecycle] Re-provisioning detected: bootstrap token changed "
              "and stale admin_users found. Clearing all zone data.")
        await _clear_stale_data()
    elif stored_hash is None:
        print("[zone_lifecycle] First startup, recording bootstrap token hash")
    else:
        print("[zone_lifecycle] Bootstrap token changed but no stale data found")

    await _set_stored_hash(current_hash)
    print("[zone_lifecycle] Stored new bootstrap token hash")
