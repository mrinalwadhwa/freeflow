#!/usr/bin/env python3
"""Test persistent WebSocket streaming with multiple sessions and keepalive.

Connects to the /stream endpoint once and exercises:
  1. Ping/pong keepalive before any dictation session
  2. A dictation session (start → audio → stop → transcript_done)
  3. Ping/pong keepalive between sessions
  4. A second dictation session on the same connection
  5. Clean disconnect

Usage:
    cd apps/freeflow/main/FreeFlowService
    export FREEFLOW_API_KEY="$(grep API_KEY secrets.yaml | cut -d' ' -f2)"
    export FREEFLOW_SERVICE_URL="https://a9eb812238f753132652ae09963a05e9-freeflow.cluster.autonomy.computer"
    python3 tests/test_persistent_stream.py
    python3 tests/test_persistent_stream.py -v          # verbose logging
    python3 tests/test_persistent_stream.py --ping-only # just test keepalive
"""

import argparse
import asyncio
import base64
import json
import math
import os
import struct
import sys
import time


def get_config():
    """Read configuration from environment variables."""
    base_url = os.environ.get("FREEFLOW_SERVICE_URL", "")
    api_key = os.environ.get("FREEFLOW_API_KEY", "")
    if not base_url:
        print("ERROR: FREEFLOW_SERVICE_URL not set")
        sys.exit(1)
    if not api_key:
        print("ERROR: FREEFLOW_API_KEY not set")
        sys.exit(1)
    return base_url, api_key


def build_ws_url(base_url: str, api_key: str) -> str:
    """Convert HTTP(S) URL to WS(S) and append auth token."""
    ws_url = base_url.rstrip("/")
    if ws_url.startswith("https://"):
        ws_url = "wss://" + ws_url[len("https://"):]
    elif ws_url.startswith("http://"):
        ws_url = "ws://" + ws_url[len("http://"):]
    return f"{ws_url}/stream?token={api_key}"


def generate_sine_pcm(
    duration_s: float = 1.0,
    frequency: float = 440.0,
    sample_rate: int = 16000,
    amplitude: int = 3000,
) -> bytes:
    """Generate a sine wave as 16-bit PCM at the given sample rate."""
    n_samples = int(sample_rate * duration_s)
    samples = []
    for i in range(n_samples):
        value = int(amplitude * math.sin(2 * math.pi * frequency * i / sample_rate))
        samples.append(max(-32768, min(32767, value)))
    return struct.pack(f"<{n_samples}h", *samples)


def chunk_pcm(pcm_data: bytes, chunk_size: int = 3200) -> list[bytes]:
    """Split PCM data into chunks (default 100ms at 16kHz 16-bit mono)."""
    return [
        pcm_data[i : i + chunk_size]
        for i in range(0, len(pcm_data), chunk_size)
    ]


class PersistentStreamTest:
    """Test harness for persistent WebSocket streaming."""

    def __init__(self, ws_url: str, verbose: bool = False):
        self.ws_url = ws_url
        self.verbose = verbose
        self.ws = None
        self.passed = 0
        self.failed = 0
        self.errors: list[str] = []

    def log(self, msg: str):
        if self.verbose:
            print(f"  [debug] {msg}")

    def ok(self, name: str, detail: str = ""):
        self.passed += 1
        suffix = f" — {detail}" if detail else ""
        print(f"  ✔ {name}{suffix}")

    def fail(self, name: str, detail: str = ""):
        self.failed += 1
        suffix = f" — {detail}" if detail else ""
        msg = f"  ✘ {name}{suffix}"
        print(msg)
        self.errors.append(msg)

    async def connect(self):
        """Open the persistent WebSocket connection."""
        try:
            import websockets
        except ImportError:
            print("ERROR: websockets package required. pip install websockets")
            sys.exit(1)

        self.log(f"Connecting to {self.ws_url[:80]}...")
        t0 = time.monotonic()
        self.ws = await websockets.connect(
            self.ws_url,
            ping_interval=20,
            ping_timeout=20,
        )
        dt = time.monotonic() - t0
        self.ok("Connect", f"{dt:.2f}s")

    async def disconnect(self):
        """Close the WebSocket connection."""
        if self.ws:
            await self.ws.close()
            self.ok("Disconnect")

    async def send_json(self, obj: dict):
        """Send a JSON message."""
        text = json.dumps(obj)
        self.log(f"→ {text[:200]}")
        await self.ws.send(text)

    async def recv_json(self, timeout: float = 15.0) -> dict:
        """Receive and parse a JSON message."""
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        msg = json.loads(raw)
        msg_type = msg.get("type", "?")
        if msg_type == "transcript_delta":
            delta = msg.get("delta", "")
            self.log(f"← transcript_delta: {delta[:60]}...")
        else:
            summary = json.dumps(msg)
            if len(summary) > 200:
                summary = summary[:200] + "..."
            self.log(f"← {summary}")
        return msg

    async def test_ping(self, label: str = "Ping/pong"):
        """Send a ping and verify pong response."""
        t0 = time.monotonic()
        await self.send_json({"type": "ping"})
        msg = await self.recv_json(timeout=5.0)
        dt = time.monotonic() - t0
        if msg.get("type") == "pong":
            self.ok(label, f"{dt * 1000:.0f}ms")
        else:
            self.fail(label, f"expected pong, got {msg.get('type')}")

    async def test_dictation_session(
        self, session_label: str, audio_duration: float = 1.5
    ):
        """Run a full dictation session: start → audio → stop → result."""
        pcm = generate_sine_pcm(duration_s=audio_duration)
        chunks = chunk_pcm(pcm)

        # Send start.
        t0 = time.monotonic()
        await self.send_json({
            "type": "start",
            "context": {
                "bundle_id": "com.test.persistent-stream",
                "app_name": "Test",
                "window_title": "Persistent Stream Test",
            },
            "language": "en",
        })
        self.log(f"Session '{session_label}': start sent")

        # Send audio chunks with small delays to simulate real-time.
        for i, chunk in enumerate(chunks):
            audio_b64 = base64.b64encode(chunk).decode("utf-8")
            await self.send_json({"type": "audio", "audio": audio_b64})
            # ~50ms between chunks to simulate realistic streaming.
            await asyncio.sleep(0.05)

        self.log(
            f"Session '{session_label}': "
            f"sent {len(chunks)} chunks ({len(pcm)} bytes)"
        )

        # Send stop.
        await self.send_json({"type": "stop"})
        self.log(f"Session '{session_label}': stop sent")

        # Wait for transcript_done (skip transcript_delta messages).
        result = None
        error = None
        while True:
            msg = await self.recv_json(timeout=30.0)
            msg_type = msg.get("type", "")
            if msg_type == "transcript_done":
                result = msg
                break
            elif msg_type == "error":
                error = msg.get("error", "unknown")
                break
            elif msg_type == "transcript_delta":
                continue
            elif msg_type == "pong":
                continue
            else:
                self.log(f"Unexpected message type: {msg_type}")

        dt = time.monotonic() - t0

        if error:
            self.fail(
                f"Session '{session_label}'",
                f"server error: {error}",
            )
            return False

        if result is None:
            self.fail(
                f"Session '{session_label}'",
                "no transcript_done received",
            )
            return False

        text = result.get("text", "")
        raw = result.get("raw", "")

        # A sine wave isn't speech, so the transcript may be empty or
        # contain hallucinated text. Both are acceptable for this test.
        # What matters is that the protocol completed successfully.
        self.ok(
            f"Session '{session_label}'",
            f"{dt:.2f}s, raw={repr(raw[:60])}, text={repr(text[:60])}",
        )
        return True

    async def run_full_test(self):
        """Run the complete persistent connection test sequence."""
        print("\n── Persistent WebSocket Stream Test ──\n")

        await self.connect()

        # 1. Ping before any session.
        await self.test_ping("Ping before first session")

        # 2. First dictation session.
        ok1 = await self.test_dictation_session("First dictation")

        # 3. Ping between sessions (connection should still be open).
        await self.test_ping("Ping between sessions")

        # 4. Second dictation session on the same connection.
        if ok1:
            await self.test_dictation_session("Second dictation")
        else:
            self.log("Skipping second session due to first session failure")

        # 5. One more ping to confirm connection is still alive.
        await self.test_ping("Ping after second session")

        # 6. Disconnect.
        await self.disconnect()

        self.print_summary()

    async def run_ping_only(self):
        """Test only the keepalive mechanism."""
        print("\n── Persistent WebSocket Ping Test ──\n")

        await self.connect()

        for i in range(3):
            await self.test_ping(f"Ping {i + 1}")
            await asyncio.sleep(1)

        await self.disconnect()

        self.print_summary()

    def print_summary(self):
        total = self.passed + self.failed
        print(f"\n── {self.passed}/{total} passed ──")
        if self.errors:
            print("\nFailures:")
            for err in self.errors:
                print(err)
        print()


async def main():
    parser = argparse.ArgumentParser(
        description="Test persistent WebSocket streaming"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Verbose logging"
    )
    parser.add_argument(
        "--ping-only",
        action="store_true",
        help="Only test ping/pong keepalive",
    )
    args = parser.parse_args()

    base_url, api_key = get_config()
    ws_url = build_ws_url(base_url, api_key)

    test = PersistentStreamTest(ws_url, verbose=args.verbose)

    if args.ping_only:
        await test.run_ping_only()
    else:
        await test.run_full_test()

    sys.exit(1 if test.failed > 0 else 0)


if __name__ == "__main__":
    asyncio.run(main())
