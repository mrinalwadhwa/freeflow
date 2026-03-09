"""PostgreSQL connection pool for Python-managed tables.

Provide an async connection pool using psycopg for tables managed by
the Python process (invite_tokens, email_config). The pool connects
to the zone's PostgreSQL instance using OCKAM_DATABASE_* environment
variables, the same database that better-auth uses for its own tables.
"""

import os

import psycopg_pool


def _build_conninfo() -> str:
    """Build a libpq connection string from environment variables."""
    instance = os.environ.get("OCKAM_DATABASE_INSTANCE", "")
    user = os.environ.get("OCKAM_DATABASE_USER", "")
    password = os.environ.get("OCKAM_DATABASE_PASSWORD", "")
    if not instance or not user or not password:
        raise RuntimeError(
            "Database not configured. Set OCKAM_DATABASE_INSTANCE, "
            "OCKAM_DATABASE_USER, and OCKAM_DATABASE_PASSWORD."
        )
    # instance is host:port/dbname or host/dbname
    if "/" in instance:
        host_port, dbname = instance.rsplit("/", 1)
    else:
        host_port = instance
        dbname = user
    if ":" in host_port:
        host, port = host_port.rsplit(":", 1)
    else:
        host = host_port
        port = "5432"
    return f"host={host} port={port} dbname={dbname} user={user} password={password}"


_pool: psycopg_pool.AsyncConnectionPool | None = None


async def open_pool():
    """Create and open the async connection pool.

    Call once during FastAPI lifespan startup, after the auth service
    is healthy (so migrations have run and the database is reachable).
    """
    global _pool
    conninfo = _build_conninfo()
    _pool = psycopg_pool.AsyncConnectionPool(
        conninfo=conninfo,
        min_size=1,
        max_size=5,
        open=False,
    )
    await _pool.open()
    print("[db] Connection pool opened")


async def close_pool():
    """Close the connection pool. Call during FastAPI shutdown."""
    global _pool
    if _pool is not None:
        await _pool.close()
        print("[db] Connection pool closed")
        _pool = None


def get_pool() -> psycopg_pool.AsyncConnectionPool:
    """Return the connection pool. Raises if not yet opened."""
    if _pool is None:
        raise RuntimeError("Database pool is not open. Call open_pool() first.")
    return _pool
