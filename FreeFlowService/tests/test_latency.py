#!/usr/bin/env python3
"""Latency measurement for FreeFlow dictation.

Measures the time that matters to users: from releasing the key (sending
"stop") to receiving polished text back ("transcript_done"). This is the
user-perceived latency, because during recording the streaming transcript
is already ~95% complete.

Also measures total session time (start → transcript_done) and connection
setup time for completeness, but the headline number is after-stop latency.

Uses realistic audio durations that match actual dictation patterns:
  - Short (1-2s):  "Sounds good, thanks."
  - Medium (3-5s): "I was thinking we should move the deadline to Friday."
  - Long (6-10s):  A full paragraph of natural speech.

Audio is a sine wave (not real speech), so transcription results are
garbage, but the pipeline timing is representative: the server still
opens a Realtime API connection, streams audio, collects a transcript,
runs the polish pipeline, and returns the result.

Usage:
    cd apps/voice/main/FreeFlowService

    # Read credentials from Keychain:
    eval "$(./scripts/dev-token.sh --from-keychain)"

    # Or set manually:
    export FREEFLOW_SERVICE_URL="https://YOUR-CLUSTER-ID-freeflow.cluster.autonomy.computer"
    export FREEFLOW_SESSION_TOKEN="$(./scripts/dev-token.sh)"

    # Default: 30 sessions across short/medium/long audio
    python3 tests/test_latency.py

    # Only medium-length dictations (most common)
    python3 tests/test_latency.py --profile medium

    # More sessions for statistical confidence
    python3 tests/test_latency.py --sessions 50

    # Verbose: show per-session messages
    python3 tests/test_latency.py -v

    # Zero gap between sessions (max throughput)
    python3 tests/test_latency.py --gap 0

    # Concurrent users (simulates N people dictating at the same time)
    python3 tests/test_latency.py --concurrent 10

    # Concurrent ramp test
    python3 tests/test_latency.py --concurrent-ramp 1,5,10,25,50
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
    duration_s: float,
    frequency: float = 440.0,
    sample_rate: int = 16000,
    amplitude: int = 3000,
) -> bytes:
    """Generate a sine wave as 16-bit PCM at 16kHz mono."""
    n_samples = int(sample_rate * duration_s)
    samples = []
    for i in range(n_samples):
        value = int(amplitude * math.sin(2 * math.pi * frequency * i / sample_rate))
        samples.append(max(-32768, min(32767, value)))
    return struct.pack(f"<{n_samples}h", *samples)


def chunk_pcm(pcm_data: bytes, chunk_size: int = 3200) -> list[bytes]:
    """Split PCM into chunks. 3200 bytes = 100ms at 16kHz/16-bit/mono."""
    return [
        pcm_data[i : i + chunk_size]
        for i in range(0, len(pcm_data), chunk_size)
    ]


# ---------------------------------------------------------------------------
# Audio profiles: realistic dictation lengths
# ---------------------------------------------------------------------------

@dataclass
class AudioProfile:
    name: str
    label: str          # human description
    duration_s: float
    chunk_delay_s: float = 0.1  # simulate real-time: 100ms per 100ms chunk

    def generate_chunks(self) -> list[bytes]:
        pcm = generate_sine_pcm(self.duration_s)
        return chunk_pcm(pcm)


# Profiles match real dictation patterns.
# chunk_delay_s = 0.1 means we send 100ms of audio every 100ms (real-time).
SHORT_PROFILES = [
    AudioProfile("short-1.0s", "~4 words",   1.0),
    AudioProfile("short-1.5s", "~6 words",   1.5),
    AudioProfile("short-2.0s", "~8 words",   2.0),
]

MEDIUM_PROFILES = [
    AudioProfile("med-3.0s",   "~12 words",  3.0),
    AudioProfile("med-4.0s",   "~16 words",  4.0),
    AudioProfile("med-5.0s",   "~20 words",  5.0),
]

LONG_PROFILES = [
    AudioProfile("long-6.0s",  "~24 words",  6.0),
    AudioProfile("long-8.0s",  "~32 words",  8.0),
    AudioProfile("long-10.0s", "~40 words", 10.0),
]

ALL_PROFILES = SHORT_PROFILES + MEDIUM_PROFILES + LONG_PROFILES

PROFILE_GROUPS = {
    "short":  SHORT_PROFILES,
    "medium": MEDIUM_PROFILES,
    "long":   LONG_PROFILES,
    "all":    ALL_PROFILES,
}


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

@dataclass
class SessionResult:
    index: int
    profile: str
    audio_duration_s: float
    connect_time_s: float = 0.0      # WebSocket connect (only for concurrent)
    send_time_s: float = 0.0         # start → stop (audio sending time)
    after_stop_s: float = 0.0        # stop → transcript_done (THE key number)
    total_s: float = 0.0             # start → transcript_done
    success: bool = False
    error: str = ""
    timed_out: bool = False
    text: str = ""


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = int(len(s) * p / 100)
    return s[min(idx, len(s) - 1)]


def format_stats(values: list[float]) -> str:
    if not values:
        return "n/a"
    return (f"min={min(values):.2f}s  "
            f"p50={percentile(values, 50):.2f}s  "
            f"p95={percentile(values, 95):.2f}s  "
            f"max={max(values):.2f}s")


# ---------------------------------------------------------------------------
# Single-connection sequential test
# ---------------------------------------------------------------------------

async def run_session(
    ws,
    index: int,
    profile: AudioProfile,
    session_timeout: float,
    verbose: bool,
) -> SessionResult:
    """Run one dictation session on an existing WebSocket connection.

    Times three phases separately:
      send_time:    start → stop sent (dominated by audio duration)
      after_stop:   stop sent → transcript_done received (user-perceived latency)
      total:        start → transcript_done
    """
    result = SessionResult(
        index=index,
        profile=profile.name,
        audio_duration_s=profile.duration_s,
    )

    chunks = profile.generate_chunks()

    def log(msg: str):
        if verbose:
            print(f"    [{profile.name}] {msg}")

    t_start = time.monotonic()

    try:
        # Start
        await ws.send(json.dumps({
            "type": "start",
            "context": {
                "bundle_id": "com.test.latency",
                "app_name": "LatencyTest",
                "window_title": f"Session {index} — {profile.name}",
            },
            "language": "en",
        }))

        # Send audio chunks at real-time pace
        for chunk in chunks:
            audio_b64 = base64.b64encode(chunk).decode("utf-8")
            await ws.send(json.dumps({"type": "audio", "audio": audio_b64}))
            if profile.chunk_delay_s > 0:
                await asyncio.sleep(profile.chunk_delay_s)

        # Stop — this is when the user releases the key
        await ws.send(json.dumps({"type": "stop"}))
        t_stop = time.monotonic()
        result.send_time_s = t_stop - t_start
        log(f"Stop sent after {result.send_time_s:.2f}s ({len(chunks)} chunks)")

        # Wait for transcript_done — this is the latency the user feels
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=session_timeout)
            msg = json.loads(raw)
            msg_type = msg.get("type", "")

            if msg_type == "transcript_done":
                result.text = msg.get("text", "")
                result.success = True
                break
            elif msg_type == "error":
                error_msg = msg.get("error", "unknown")
                if "buffer too small" in error_msg:
                    result.success = True
                    result.error = f"(expected) {error_msg}"
                else:
                    result.error = error_msg
                break
            elif msg_type in ("transcript_delta", "pong"):
                continue
            else:
                log(f"Unexpected: {msg_type}")

        t_done = time.monotonic()
        result.after_stop_s = t_done - t_stop
        result.total_s = t_done - t_start
        log(f"Done: after_stop={result.after_stop_s:.2f}s  total={result.total_s:.2f}s")

    except asyncio.TimeoutError:
        t_now = time.monotonic()
        result.timed_out = True
        result.error = f"Timed out after {session_timeout:.0f}s"
        result.after_stop_s = t_now - (t_stop if 't_stop' in dir() else t_start)
        result.total_s = t_now - t_start
    except Exception as e:
        t_now = time.monotonic()
        result.error = str(e)
        result.total_s = t_now - t_start

    return result


async def run_sequential(
    ws_url: str,
    profiles: list[AudioProfile],
    num_sessions: int,
    gap_s: float,
    session_timeout: float,
    verbose: bool,
) -> list[SessionResult]:
    """Run sessions sequentially on a single persistent WebSocket."""

    try:
        import websockets
    except ImportError:
        print("ERROR: websockets package required. pip install websockets")
        sys.exit(1)

    print(f"\n  Connecting...")
    ws = await websockets.connect(ws_url, ping_interval=20, ping_timeout=20)

    # Verify with ping
    await ws.send(json.dumps({"type": "ping"}))
    raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
    msg = json.loads(raw)
    if msg.get("type") == "pong":
        print(f"  Connected OK\n")
    else:
        print(f"  WARNING: expected pong, got {msg.get('type')}\n")

    results = []
    for i in range(num_sessions):
        profile = profiles[i % len(profiles)]
        result = await run_session(ws, i + 1, profile, session_timeout, verbose)

        status = "✔" if result.success else "✘"
        extra = ""
        if result.timed_out:
            extra = " [TIMEOUT]"
        elif result.error and not result.success:
            extra = f" [{result.error[:40]}]"

        print(
            f"  {status} #{i + 1:3d}  {profile.name:14s}  "
            f"after_stop={result.after_stop_s:.2f}s  "
            f"total={result.total_s:.2f}s"
            f"{extra}"
        )

        results.append(result)

        if i < num_sessions - 1 and gap_s > 0:
            await asyncio.sleep(gap_s)

    # Final ping
    try:
        await ws.send(json.dumps({"type": "ping"}))
        raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
        if json.loads(raw).get("type") == "pong":
            print(f"\n  Final ping OK")
    except Exception as e:
        print(f"\n  Final ping failed: {e}")

    await ws.close()
    return results


# ---------------------------------------------------------------------------
# Concurrent users test
# ---------------------------------------------------------------------------

async def run_concurrent_user(
    user_id: int,
    ws_url: str,
    profile: AudioProfile,
    start_event: asyncio.Event,
    stagger_s: float,
    session_timeout: float,
    verbose: bool,
) -> SessionResult:
    """Simulate one user: connect, wait for go, dictate, return result."""

    try:
        import websockets
    except ImportError:
        print("ERROR: websockets package required")
        sys.exit(1)

    result = SessionResult(
        index=user_id,
        profile=profile.name,
        audio_duration_s=profile.duration_s,
    )

    def log(msg: str):
        if verbose:
            print(f"    [user {user_id:3d}] {msg}")

    # Connect
    t_conn = time.monotonic()
    try:
        ws = await asyncio.wait_for(
            websockets.connect(ws_url, ping_interval=20, ping_timeout=20),
            timeout=15.0,
        )
    except Exception as e:
        result.error = f"Connect failed: {e}"
        result.connect_time_s = time.monotonic() - t_conn
        return result
    result.connect_time_s = time.monotonic() - t_conn
    log(f"Connected in {result.connect_time_s:.2f}s")

    # Verify
    try:
        await ws.send(json.dumps({"type": "ping"}))
        raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
        if json.loads(raw).get("type") != "pong":
            result.error = "Ping failed"
            await ws.close()
            return result
    except Exception as e:
        result.error = f"Ping failed: {e}"
        try:
            await ws.close()
        except Exception:
            pass
        return result

    # Wait for coordinated start
    await start_event.wait()
    if stagger_s > 0:
        await asyncio.sleep(stagger_s)

    # Run dictation
    inner = await run_session(ws, user_id, profile, session_timeout, verbose)

    # Copy fields
    result.send_time_s = inner.send_time_s
    result.after_stop_s = inner.after_stop_s
    result.total_s = inner.total_s
    result.success = inner.success
    result.error = inner.error
    result.timed_out = inner.timed_out
    result.text = inner.text

    try:
        await ws.close()
    except Exception:
        pass

    return result


async def run_concurrent_round(
    num_users: int,
    ws_url: str,
    profile: AudioProfile,
    session_timeout: float,
    stagger_per_user_ms: float,
    verbose: bool,
) -> list[SessionResult]:
    """Run num_users concurrent dictation sessions."""

    start_event = asyncio.Event()

    tasks = []
    for i in range(num_users):
        stagger_s = i * (stagger_per_user_ms / 1000.0)
        tasks.append(asyncio.create_task(
            run_concurrent_user(
                user_id=i + 1,
                ws_url=ws_url,
                profile=profile,
                start_event=start_event,
                stagger_s=stagger_s,
                session_timeout=session_timeout,
                verbose=verbose,
            )
        ))

    # Let connections establish
    await asyncio.sleep(1.0)

    t_wall = time.monotonic()
    start_event.set()
    raw_results = await asyncio.gather(*tasks, return_exceptions=True)
    wall_time = time.monotonic() - t_wall

    results = []
    for r in raw_results:
        if isinstance(r, Exception):
            results.append(SessionResult(index=-1, profile=profile.name,
                                         audio_duration_s=profile.duration_s,
                                         error=str(r)))
        else:
            results.append(r)

    return results


# ---------------------------------------------------------------------------
# Print results
# ---------------------------------------------------------------------------

def print_summary(results: list[SessionResult], title: str = ""):
    passed = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    after_stop_times = [r.after_stop_s for r in passed]
    total_times = [r.total_s for r in passed]

    print(f"\n{'=' * 66}")
    if title:
        print(title)
        print(f"{'=' * 66}")
    print(f"  Sessions: {len(results)}  Passed: {len(passed)}  Failed: {len(failed)}")

    if after_stop_times:
        print(f"\n  After-stop latency (key released → text returned):")
        print(f"    {format_stats(after_stop_times)}")

    if total_times:
        print(f"\n  Total time (start → text returned):")
        print(f"    {format_stats(total_times)}")

    # Break down by profile group
    profile_groups: dict[str, list[float]] = {}
    for r in passed:
        # Group by duration bucket
        if r.audio_duration_s <= 2.5:
            bucket = "short (1-2s)"
        elif r.audio_duration_s <= 5.5:
            bucket = "medium (3-5s)"
        else:
            bucket = "long (6-10s)"
        profile_groups.setdefault(bucket, []).append(r.after_stop_s)

    if len(profile_groups) > 1:
        print(f"\n  After-stop by audio length:")
        for bucket in ["short (1-2s)", "medium (3-5s)", "long (6-10s)"]:
            if bucket in profile_groups:
                vals = profile_groups[bucket]
                print(f"    {bucket:16s}  {format_stats(vals)}")

    if failed:
        print(f"\n  Failures:")
        for r in failed:
            print(f"    #{r.index}: {r.error}")

    print()
    if not failed:
        print("  ✔ All sessions completed successfully")
    else:
        print(f"  ⚠ {len(failed)} failures")


def print_concurrent_summary(
    levels: list[int],
    all_results: list[tuple[int, list[SessionResult]]],
):
    print(f"\n{'=' * 76}")
    print("CONCURRENT USERS SUMMARY")
    print(f"{'=' * 76}")
    print(f"\n  {'Users':>6}  {'Pass':>5}  {'Fail':>5}  "
          f"{'p50':>8}  {'p95':>8}  {'max':>8}  "
          f"{'p50 tot':>8}  {'p95 tot':>8}")
    print(f"  {'─' * 6}  {'─' * 5}  {'─' * 5}  "
          f"{'─' * 8}  {'─' * 8}  {'─' * 8}  "
          f"{'─' * 8}  {'─' * 8}")

    for num_users, results in all_results:
        passed = [r for r in results if r.success]
        failed_count = len(results) - len(passed)
        after_stop = [r.after_stop_s for r in passed]
        totals = [r.total_s for r in passed]

        if after_stop:
            p50_as = percentile(after_stop, 50)
            p95_as = percentile(after_stop, 95)
            max_as = max(after_stop)
            p50_t = percentile(totals, 50)
            p95_t = percentile(totals, 95)
            print(f"  {num_users:>6}  {len(passed):>5}  {failed_count:>5}  "
                  f"{p50_as:>7.2f}s  {p95_as:>7.2f}s  {max_as:>7.2f}s  "
                  f"{p50_t:>7.2f}s  {p95_t:>7.2f}s")
        else:
            print(f"  {num_users:>6}  {len(passed):>5}  {failed_count:>5}  "
                  f"{'n/a':>8}  {'n/a':>8}  {'n/a':>8}  "
                  f"{'n/a':>8}  {'n/a':>8}")

    total_failures = sum(
        len(results) - sum(1 for r in results if r.success)
        for _, results in all_results
    )
    print()
    if total_failures:
        print(f"  ⚠ {total_failures} total failures")
    else:
        print("  ✔ All sessions across all levels completed successfully")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

async def main():
    parser = argparse.ArgumentParser(
        description="Measure FreeFlow dictation latency (after-stop time)",
    )
    parser.add_argument(
        "--sessions", type=int, default=30,
        help="Number of sequential sessions (default: 30)",
    )
    parser.add_argument(
        "--profile", type=str, default="all",
        choices=["short", "medium", "long", "all"],
        help="Audio profile group (default: all)",
    )
    parser.add_argument(
        "--gap", type=float, default=0.3,
        help="Seconds between sequential sessions (default: 0.3)",
    )
    parser.add_argument(
        "--timeout", type=float, default=30.0,
        help="Per-session timeout in seconds (default: 30.0)",
    )
    parser.add_argument(
        "--concurrent", type=int, default=0,
        help="Run N concurrent users instead of sequential (default: 0 = sequential)",
    )
    parser.add_argument(
        "--concurrent-ramp", type=str, default="",
        help="Comma-separated concurrent user levels (e.g. 1,5,10,25,50)",
    )
    parser.add_argument(
        "--concurrent-rounds", type=int, default=2,
        help="Rounds per concurrency level in ramp test (default: 2)",
    )
    parser.add_argument(
        "--stagger-ms", type=float, default=50.0,
        help="Stagger between concurrent users in ms (default: 50)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
        help="Verbose per-session logging",
    )
    args = parser.parse_args()

    base_url, token = get_config()
    ws_url = build_ws_url(base_url, token)

    profiles = PROFILE_GROUPS[args.profile]

    # --- Concurrent ramp test ---
    if args.concurrent_ramp:
        levels = [int(x.strip()) for x in args.concurrent_ramp.split(",")]
        # Use medium profile for concurrent tests (most representative)
        profile = AudioProfile("med-4.0s", "~16 words", 4.0)

        print(f"\n{'=' * 76}")
        print("CONCURRENT LATENCY RAMP TEST")
        print(f"{'=' * 76}")
        print(f"  Audio: {profile.name} ({profile.duration_s}s)")
        print(f"  Levels: {levels}")
        print(f"  Rounds per level: {args.concurrent_rounds}")
        print(f"  Stagger: {args.stagger_ms}ms per user")

        all_results: list[tuple[int, list[SessionResult]]] = []

        for level in levels:
            level_results: list[SessionResult] = []
            for round_num in range(1, args.concurrent_rounds + 1):
                print(f"\n  --- {level} users, round {round_num} ---")
                results = await run_concurrent_round(
                    num_users=level,
                    ws_url=ws_url,
                    profile=profile,
                    session_timeout=args.timeout,
                    stagger_per_user_ms=args.stagger_ms,
                    verbose=args.verbose,
                )
                passed = sum(1 for r in results if r.success)
                after_stops = [r.after_stop_s for r in results if r.success]
                if after_stops:
                    print(f"  {passed}/{len(results)} passed  "
                          f"after_stop p50={percentile(after_stops, 50):.2f}s  "
                          f"p95={percentile(after_stops, 95):.2f}s  "
                          f"max={max(after_stops):.2f}s")
                level_results.extend(results)

                if round_num < args.concurrent_rounds:
                    await asyncio.sleep(3.0)

            all_results.append((level, level_results))

            if level != levels[-1]:
                print(f"\n  Pausing 5s before next level...")
                await asyncio.sleep(5.0)

        print_concurrent_summary(levels, all_results)
        total_failures = sum(
            len(r) - sum(1 for x in r if x.success) for _, r in all_results
        )
        sys.exit(1 if total_failures > 0 else 0)

    # --- Single concurrent level ---
    elif args.concurrent > 0:
        profile = AudioProfile("med-4.0s", "~16 words", 4.0)

        print(f"\n{'=' * 66}")
        print(f"CONCURRENT LATENCY TEST: {args.concurrent} users")
        print(f"{'=' * 66}")
        print(f"  Audio: {profile.name} ({profile.duration_s}s)")

        results = await run_concurrent_round(
            num_users=args.concurrent,
            ws_url=ws_url,
            profile=profile,
            session_timeout=args.timeout,
            stagger_per_user_ms=args.stagger_ms,
            verbose=args.verbose,
        )

        for r in results:
            status = "✔" if r.success else "✘"
            extra = ""
            if r.timed_out:
                extra = " [TIMEOUT]"
            elif r.error and not r.success:
                extra = f" [{r.error[:40]}]"
            print(
                f"  {status} user {r.index:3d}  "
                f"after_stop={r.after_stop_s:.2f}s  "
                f"total={r.total_s:.2f}s"
                f"{extra}"
            )

        print_summary(results, f"CONCURRENT LATENCY: {args.concurrent} users")
        failures = sum(1 for r in results if not r.success)
        sys.exit(1 if failures > 0 else 0)

    # --- Sequential test (default) ---
    else:
        print(f"\n{'=' * 66}")
        print("LATENCY MEASUREMENT")
        print(f"{'=' * 66}")
        print(f"  Profile: {args.profile} ({len(profiles)} variants)")
        print(f"  Sessions: {args.sessions}")
        print(f"  Gap: {args.gap}s")
        print(f"  Timeout: {args.timeout}s")
        print()

        results = await run_sequential(
            ws_url=ws_url,
            profiles=profiles,
            num_sessions=args.sessions,
            gap_s=args.gap,
            session_timeout=args.timeout,
            verbose=args.verbose,
        )

        print_summary(results, "LATENCY RESULTS")
        failures = sum(1 for r in results if not r.success)
        sys.exit(1 if failures > 0 else 0)


if __name__ == "__main__":
    asyncio.run(main())
