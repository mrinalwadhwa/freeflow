"""Launch and manage the Node.js auth process.

Spawn the auth service as a subprocess on FastAPI startup. Poll its
health endpoint until it is ready, and restart it if it crashes.
"""

import asyncio
import os
import signal
import subprocess
import sys

import httpx

AUTH_PORT = 3456
AUTH_HEALTH_URL = f"http://localhost:{AUTH_PORT}/api/auth/ok"
AUTH_SCRIPT = os.path.join(os.path.dirname(__file__), "auth", "server.mjs")

_process: subprocess.Popen | None = None
_monitor_task: asyncio.Task | None = None


def _spawn() -> subprocess.Popen:
    """Start the Node.js auth process."""
    return subprocess.Popen(
        ["node", AUTH_SCRIPT],
        stdout=sys.stdout,
        stderr=sys.stderr,
    )


async def _wait_for_health(timeout: float = 10.0, interval: float = 0.2):
    """Poll the health endpoint until it responds 200 or timeout."""
    deadline = asyncio.get_event_loop().time() + timeout
    async with httpx.AsyncClient() as client:
        while asyncio.get_event_loop().time() < deadline:
            try:
                resp = await client.get(AUTH_HEALTH_URL, timeout=2.0)
                if resp.status_code == 200:
                    return
            except httpx.ConnectError:
                pass
            except httpx.RequestError:
                pass
            await asyncio.sleep(interval)
    raise RuntimeError(f"Auth service did not become healthy within {timeout}s")


async def _monitor():
    """Restart the auth process if it exits unexpectedly."""
    global _process
    while True:
        if _process is None:
            return
        await asyncio.sleep(1.0)
        if _process.poll() is not None:
            code = _process.returncode
            print(f"[startup] Auth process exited with code {code}, restarting")
            _process = _spawn()
            try:
                await _wait_for_health()
                print("[startup] Auth process restarted and healthy")
            except RuntimeError as e:
                print(f"[startup] Auth process failed to restart: {e}")


async def start_auth():
    """Start the auth process and wait for it to be healthy."""
    global _process, _monitor_task
    _process = _spawn()
    await _wait_for_health()
    print("[startup] Auth process is healthy")
    _monitor_task = asyncio.create_task(_monitor())


async def stop_auth():
    """Stop the auth process and cancel the monitor task."""
    global _process, _monitor_task
    if _monitor_task is not None:
        _monitor_task.cancel()
        try:
            await _monitor_task
        except asyncio.CancelledError:
            pass
        _monitor_task = None
    if _process is not None:
        _process.send_signal(signal.SIGTERM)
        try:
            _process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _process.kill()
            _process.wait()
        print(f"[startup] Auth process stopped (exit code {_process.returncode})")
        _process = None
