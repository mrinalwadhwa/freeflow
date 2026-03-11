#!/usr/bin/env python3
"""Stress test for persistent WebSocket streaming.

Runs many rapid back-to-back dictation sessions over a single persistent
WebSocket connection to reproduce the stuck-session bug where the server
never sends transcript_done. Varies audio lengths, inter-session gaps,
and includes edge cases like very short audio and immediate stop.

Reports timing stats, success/failure counts, and flags sessions that
required more than a threshold to complete (indicating the server may
have been slow or partially stuck).

Usage:
    cd apps/freeflow/main/FreeFlowService
    export FREEFLOW_SERVICE_URL="https://YOUR-CLUSTER-ID-freeflow.cluster.autonomy.computer"
    export FREEFLOW_SESSION_TOKEN="$(./scripts/dev-token.sh)"

    # Default: 20 sessions, mixed audio lengths
    python3 tests/test_stress_stream.py

    # Heavy: 50 sessions, verbose
    python3 tests/test_stress_stream.py --sessions 50 -v

    # Rapid fire: no gap between sessions
    python3 tests/test_stress_stream.py --gap 0

    # Custom timeout threshold for flagging slow sessions
    python3 tests/test_stress_stream.py --slow-threshold 3.0
"""

import argparse
import asyncio
import base64
import json
import math
import os
import random
import struct
import sys
import time
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def get_config():
    base_url = os.environ.get("FREEFLOW_SERVICE_URL", "")
    token = os.environ.get("FREEFLOW_SESSION_TOKEN", "")
    if not base_url:
        print("ERROR: FREEFLOW_SERVICE_URL not set")
        sys.exit(1)
    if not token:
        print("ERROR: FREEFLOW_SESSION_TOKEN not set")
        sys.exit(1)
    return base_url, token


def build_ws_url(base_url: str, token: str) -> str:
    ws_url = base_url.rstrip("/")
    if ws_url.startswith("https://"):
        ws_url = "wss://" + ws_url[len("https://"):]
    elif ws_url.startswith("http://"):
        ws_url = "ws://" + ws_url[len("http://"):]
    return f"{ws_url}/stream?token={token}"


# ---------------------------------------------------------------------------
# Audio generation
# ---------------------------------------------------------------------------

def generate_sine_pcm(
    duration_s: float = 1.0,
    frequency: float = 440.0,
    sample_rate: int = 16000,
    amplitude: int = 3000,
) -> bytes:
    n_samples = int(sample_rate * duration_s)
    samples = []
    for i in range(n_samples):
        value = int(amplitude * math.sin(2 * math.pi * frequency * i / sample_rate))
        samples.append(max(-32768, min(32767, value)))
    return struct.pack(f"<{n_samples}h", *samples)


def generate_silence_pcm(
    duration_s: float = 0.5,
    sample_rate: int = 16000,
) -> bytes:
    n_samples = int(sample_rate * duration_s)
    return b"\x00\x00" * n_samples


def chunk_pcm(pcm_data: bytes, chunk_size: int = 3200) -> list[bytes]:
    return [
        pcm_data[i : i + chunk_size]
        for i in range(0, len(pcm_data), chunk_size)
    ]


# ---------------------------------------------------------------------------
# Session profiles — different audio patterns to stress different code paths
# ---------------------------------------------------------------------------

@dataclass
class SessionProfile:
    name: str
    audio_duration_s: float
    chunk_delay_s: float = 0.05  # delay between chunks (simulates real-time)
    use_silence: bool = False     # send silence instead of sine wave
    frequency: float = 440.0

    def generate_audio(self) -> bytes:
        if self.use_silence:
            return generate_silence_pcm(self.audio_duration_s)
        return generate_sine_pcm(
            duration_s=self.audio_duration_s,
            frequency=self.frequency,
        )


PROFILES = [
    SessionProfile("normal-1s", 1.0),
    SessionProfile("normal-2s", 2.0),
    SessionProfile("normal-3s", 3.0),
    SessionProfile("short-0.3s", 0.3, chunk_delay_s=0.02),
    SessionProfile("short-0.5s", 0.5, chunk_delay_s=0.03),
    SessionProfile("long-5s", 5.0, chunk_delay_s=0.08),
    SessionProfile("silence-1s", 1.0, use_silence=True),
    SessionProfile("silence-short", 0.2, use_silence=True),
    SessionProfile("rapid-1s", 1.0, chunk_delay_s=0.01),  # fast chunk send
    SessionProfile("rapid-0.5s", 0.5, chunk_delay_s=0.005),
    SessionProfile("normal-1.5s", 1.5),
    SessionProfile("normal-0.8s", 0.8, frequency=880.0),
]


def pick_profile(index: int) -> SessionProfile:
    """Pick a profile. Cycles through all profiles, with some randomness."""
    return PROFILES[index % len(PROFILES)]


# ---------------------------------------------------------------------------
# Session result tracking
# ---------------------------------------------------------------------------

@dataclass
class SessionResult:
    index: int
    profile_name: str
    audio_duration_s: float
    elapsed_s: float = 0.0
    success: bool = False
    error: str = ""
    raw_text: str = ""
    polished_text: str = ""
    timed_out: bool = False
    reconnected: bool = False


@dataclass
class StressTestStats:
    results: list[SessionResult] = field(default_factory=list)
    reconnect_count: int = 0

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def passed(self) -> int:
        return sum(1 for r in self.results if r.success)

    @property
    def failed(self) -> int:
        return sum(1 for r in self.results if not r.success)

    @property
    def timed_out(self) -> int:
        return sum(1 for r in self.results if r.timed_out)

    def slow_sessions(self, threshold: float) -> list[SessionResult]:
        return [r for r in self.results if r.success and r.elapsed_s > threshold]

    @property
    def durations(self) -> list[float]:
        return [r.elapsed_s for r in self.results if r.success]

    def print_summary(self, slow_threshold: float):
        print("\n" + "=" * 60)
        print("STRESS TEST RESULTS")
        print("=" * 60)

        print(f"\nSessions:      {self.total}")
        print(f"Passed:        {self.passed}")
        print(f"Failed:        {self.failed}")
        print(f"Timed out:     {self.timed_out}")
        print(f"Reconnects:    {self.reconnect_count}")

        if self.durations:
            avg = sum(self.durations) / len(self.durations)
            mn = min(self.durations)
            mx = max(self.durations)
            p50 = sorted(self.durations)[len(self.durations) // 2]
            p95_idx = int(len(self.durations) * 0.95)
            p95 = sorted(self.durations)[min(p95_idx, len(self.durations) - 1)]
            print(f"\nLatency (successful sessions):")
            print(f"  min:  {mn:.2f}s")
            print(f"  avg:  {avg:.2f}s")
            print(f"  p50:  {p50:.2f}s")
            print(f"  p95:  {p95:.2f}s")
            print(f"  max:  {mx:.2f}s")

        slow = self.slow_sessions(slow_threshold)
        if slow:
            print(f"\nSlow sessions (>{slow_threshold:.1f}s): {len(slow)}")
            for r in slow:
                print(f"  #{r.index}: {r.profile_name} — {r.elapsed_s:.2f}s")

        if self.failed > 0:
            print(f"\nFailed sessions:")
            for r in self.results:
                if not r.success:
                    timeout_tag = " [TIMEOUT]" if r.timed_out else ""
                    reconnect_tag = " [RECONNECTED]" if r.reconnected else ""
                    print(
                        f"  #{r.index}: {r.profile_name} — "
                        f"{r.error}{timeout_tag}{reconnect_tag}"
                    )

        print()

        if self.failed == 0:
            print("✔ All sessions completed successfully")
        else:
            print(f"✘ {self.failed} session(s) failed")

        print()


# ---------------------------------------------------------------------------
# Stress test runner
# ---------------------------------------------------------------------------

class StressTestRunner:
    def __init__(
        self,
        ws_url: str,
        num_sessions: int = 20,
        gap_s: float = 0.2,
        session_timeout: float = 15.0,
        slow_threshold: float = 5.0,
        verbose: bool = False,
    ):
        self.ws_url = ws_url
        self.num_sessions = num_sessions
        self.gap_s = gap_s
        self.session_timeout = session_timeout
        self.slow_threshold = slow_threshold
        self.verbose = verbose
        self.ws = None
        self.stats = StressTestStats()

    def log(self, msg: str):
        if self.verbose:
            print(f"  [debug] {msg}")

    async def connect(self):
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
        self.log(f"Connected in {dt:.2f}s")

    async def reconnect(self):
        """Close and reopen the WebSocket."""
        self.stats.reconnect_count += 1
        self.log("Reconnecting...")
        if self.ws:
            try:
                await self.ws.close()
            except Exception:
                pass
            self.ws = None
        await self.connect()
        self.log("Reconnected")

    async def disconnect(self):
        if self.ws:
            try:
                await self.ws.close()
            except Exception:
                pass

    async def send_json(self, obj: dict):
        text = json.dumps(obj)
        self.log(f"→ {text[:120]}")
        await self.ws.send(text)

    async def recv_json(self, timeout: float = 15.0) -> dict:
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        msg = json.loads(raw)
        msg_type = msg.get("type", "?")
        if msg_type == "transcript_delta":
            self.log(f"← delta: {msg.get('delta', '')[:40]}")
        else:
            summary = json.dumps(msg)
            if len(summary) > 120:
                summary = summary[:120] + "..."
            self.log(f"← {summary}")
        return msg

    async def run_session(self, index: int, profile: SessionProfile) -> SessionResult:
        """Run a single dictation session and return the result."""
        result = SessionResult(
            index=index,
            profile_name=profile.name,
            audio_duration_s=profile.audio_duration_s,
        )

        pcm = profile.generate_audio()
        chunks = chunk_pcm(pcm)

        t0 = time.monotonic()

        try:
            # Start
            await self.send_json({
                "type": "start",
                "context": {
                    "bundle_id": "com.test.stress",
                    "app_name": "StressTest",
                    "window_title": f"Session {index} — {profile.name}",
                },
                "language": "en",
            })

            # Send audio chunks
            for chunk in chunks:
                audio_b64 = base64.b64encode(chunk).decode("utf-8")
                await self.send_json({"type": "audio", "audio": audio_b64})
                if profile.chunk_delay_s > 0:
                    await asyncio.sleep(profile.chunk_delay_s)

            # Stop
            await self.send_json({"type": "stop"})
            self.log(f"Session {index}: stop sent, sent {len(chunks)} chunks")

            # Wait for transcript_done
            while True:
                msg = await self.recv_json(timeout=self.session_timeout)
                msg_type = msg.get("type", "")

                if msg_type == "transcript_done":
                    result.raw_text = msg.get("raw", "")
                    result.polished_text = msg.get("text", "")
                    result.success = True
                    break
                elif msg_type == "error":
                    error_msg = msg.get("error", "unknown")
                    # Some errors are expected (e.g. buffer too small for silence)
                    # and still represent a completed protocol exchange.
                    if "buffer too small" in error_msg:
                        result.success = True
                        result.error = f"(expected) {error_msg}"
                        break
                    result.error = error_msg
                    break
                elif msg_type == "transcript_delta":
                    continue
                elif msg_type == "pong":
                    continue
                else:
                    self.log(f"Unexpected message: {msg_type}")

        except asyncio.TimeoutError:
            result.timed_out = True
            result.error = f"Timed out after {self.session_timeout:.0f}s"
        except Exception as e:
            result.error = str(e)

        result.elapsed_s = time.monotonic() - t0
        return result

    async def run(self):
        print(f"\n── Stress Test: {self.num_sessions} sessions, "
              f"gap={self.gap_s}s, timeout={self.session_timeout}s ──\n")

        await self.connect()

        # Initial ping to verify connection.
        try:
            await self.send_json({"type": "ping"})
            msg = await self.recv_json(timeout=5.0)
            if msg.get("type") == "pong":
                print("  ✔ Initial ping/pong OK\n")
            else:
                print(f"  ✘ Expected pong, got {msg.get('type')}\n")
        except Exception as e:
            print(f"  ✘ Initial ping failed: {e}\n")
            return

        for i in range(1, self.num_sessions + 1):
            profile = pick_profile(i - 1)

            result = await self.run_session(i, profile)

            # Print inline status.
            status = "✔" if result.success else "✘"
            extra = ""
            if result.timed_out:
                extra = " [TIMEOUT]"
            elif result.error and not result.success:
                extra = f" [{result.error[:50]}]"
            elif result.elapsed_s > self.slow_threshold:
                extra = " [SLOW]"

            print(
                f"  {status} #{i:3d} {profile.name:20s} "
                f"{result.elapsed_s:6.2f}s"
                f"{extra}"
            )

            self.stats.results.append(result)

            # If the session timed out or the connection broke, reconnect.
            if result.timed_out or (not result.success and "closed" in result.error.lower()):
                print(f"        ↳ Reconnecting after failure...")
                result.reconnected = True
                try:
                    await self.reconnect()
                    # Verify reconnection with a ping.
                    await self.send_json({"type": "ping"})
                    msg = await self.recv_json(timeout=5.0)
                    if msg.get("type") == "pong":
                        print(f"        ↳ Reconnected OK")
                    else:
                        print(f"        ↳ Reconnect ping failed")
                except Exception as e:
                    print(f"        ↳ Reconnect failed: {e}")
                    break

            # Inter-session gap (with some jitter).
            if i < self.num_sessions and self.gap_s > 0:
                jitter = random.uniform(0, self.gap_s * 0.5)
                await asyncio.sleep(self.gap_s + jitter)

        # Final ping to check connection is still alive.
        try:
            await self.send_json({"type": "ping"})
            msg = await self.recv_json(timeout=5.0)
            if msg.get("type") == "pong":
                print("\n  ✔ Final ping/pong OK")
            else:
                print(f"\n  ✘ Final ping failed: got {msg.get('type')}")
        except Exception as e:
            print(f"\n  ✘ Final ping failed: {e}")

        await self.disconnect()

        self.stats.print_summary(self.slow_threshold)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

async def main():
    parser = argparse.ArgumentParser(
        description="Stress test persistent WebSocket streaming",
    )
    parser.add_argument(
        "--sessions", type=int, default=20,
        help="Number of dictation sessions (default: 20)",
    )
    parser.add_argument(
        "--gap", type=float, default=0.2,
        help="Seconds between sessions (default: 0.2)",
    )
    parser.add_argument(
        "--timeout", type=float, default=15.0,
        help="Per-session timeout in seconds (default: 15.0)",
    )
    parser.add_argument(
        "--slow-threshold", type=float, default=5.0,
        help="Flag sessions slower than this (default: 5.0s)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
        help="Verbose logging of all messages",
    )
    args = parser.parse_args()

    base_url, token = get_config()
    ws_url = build_ws_url(base_url, token)

    runner = StressTestRunner(
        ws_url=ws_url,
        num_sessions=args.sessions,
        gap_s=args.gap,
        session_timeout=args.timeout,
        slow_threshold=args.slow_threshold,
        verbose=args.verbose,
    )

    await runner.run()

    sys.exit(1 if runner.stats.failed > 0 else 0)


if __name__ == "__main__":
    asyncio.run(main())
