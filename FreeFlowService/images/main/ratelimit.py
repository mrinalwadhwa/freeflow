"""In-memory rate limiting for sensitive endpoints.

Provides a FastAPI dependency that enforces per-key request limits
using a sliding window counter. Keys are typically client IP addresses
but can be any string (e.g. email address for OTP endpoints).

No external dependencies. State is process-local and resets on restart.
Suitable for single-pod deployments.
"""

import time
from collections import defaultdict
from threading import Lock
from typing import Callable, Optional

from fastapi import HTTPException, Request


class RateLimiter:
    """Sliding window rate limiter.

    Tracks timestamps of recent requests per key. On each check,
    expired entries outside the window are pruned before counting.

    Thread-safe via a lock on the shared state dict.
    """

    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._hits: dict[str, list[float]] = defaultdict(list)
        self._lock = Lock()

    def check(self, key: str) -> bool:
        """Return True if the request is allowed, False if rate limited."""
        now = time.monotonic()
        cutoff = now - self.window_seconds

        with self._lock:
            timestamps = self._hits[key]
            # Prune expired entries.
            while timestamps and timestamps[0] <= cutoff:
                timestamps.pop(0)

            if len(timestamps) >= self.max_requests:
                return False

            timestamps.append(now)
            return True

    def remaining(self, key: str) -> int:
        """Return the number of requests remaining in the current window."""
        now = time.monotonic()
        cutoff = now - self.window_seconds

        with self._lock:
            timestamps = self._hits[key]
            while timestamps and timestamps[0] <= cutoff:
                timestamps.pop(0)
            return max(0, self.max_requests - len(timestamps))


def _client_ip(request: Request) -> str:
    """Extract the client IP from the request.

    Check X-Forwarded-For first (set by the load balancer / ingress),
    then fall back to the direct client address. Use the leftmost
    (original client) IP from X-Forwarded-For.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


# ---------------------------------------------------------------------------
# Pre-configured limiters for sensitive endpoints
# ---------------------------------------------------------------------------

# Invite redemption: 5 requests per minute per IP.
_redeem_limiter = RateLimiter(max_requests=5, window_seconds=60)

# Auth proxy (OTP, sign-in): 10 requests per minute per IP.
_auth_limiter = RateLimiter(max_requests=10, window_seconds=60)

# Global fallback: 120 requests per minute per IP.
_global_limiter = RateLimiter(max_requests=120, window_seconds=60)


def _make_dependency(
    limiter: RateLimiter,
    key_func: Optional[Callable[[Request], str]] = None,
):
    """Build a FastAPI dependency that enforces a rate limit."""

    async def dependency(request: Request):
        key = key_func(request) if key_func else _client_ip(request)
        if not limiter.check(key):
            raise HTTPException(
                status_code=429,
                detail="Too many requests. Please try again later.",
            )

    return dependency


require_redeem_limit = _make_dependency(_redeem_limiter)
require_auth_limit = _make_dependency(_auth_limiter)
require_global_limit = _make_dependency(_global_limiter)
