"""Admin detection and authorization.

Track which users are admins. The first user to redeem the
BOOTSTRAP_TOKEN is automatically marked as admin. Provide a FastAPI
dependency that checks admin status for the current session user.

Admin status is stored in a Python-managed table (admin_users) rather
than in better-auth's user table, keeping the two systems decoupled.
"""

from fastapi import Depends, HTTPException

import auth
import db


async def ensure_table():
    """Create the admin_users table if it does not exist."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS admin_users (
                user_id     TEXT PRIMARY KEY,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)


async def mark_admin(user_id: str):
    """Mark a user as admin. Idempotent (ignores if already admin)."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        await conn.execute(
            """
            INSERT INTO admin_users (user_id)
            VALUES (%s)
            ON CONFLICT (user_id) DO NOTHING
            """,
            (user_id,),
        )


async def is_admin(user_id: str) -> bool:
    """Return True if the user is an admin."""
    pool = db.get_pool()
    async with pool.connection() as conn:
        result = await conn.execute(
            "SELECT 1 FROM admin_users WHERE user_id = %s",
            (user_id,),
        )
        row = await result.fetchone()
    return row is not None


async def require_admin(
    user: auth.AuthUser = Depends(auth.require_auth),
) -> auth.AuthUser:
    """FastAPI dependency that requires the current user to be an admin.

    Chain with require_auth: first authenticate, then check admin
    status.
    """
    if not await is_admin(user.user_id):
        raise HTTPException(status_code=403, detail="Admin access required")

    return user
