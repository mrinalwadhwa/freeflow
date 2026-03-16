# Benchmark

## 30 Real Dictations

Latency and accuracy from 30 sentences spoken naturally into the app.
Measured on a fresh Autonomy zone with the default model configuration.

**Setup:**
MacBook Pro (Apple Silicon), built-in mic, single Autonomy container
($75/mo base), gpt-4o-realtime-preview (STT), gpt-4.1-nano (polish),
debug build, streaming mode. March 16, 2026.

### Latency

**Total** is the time from releasing the dictation key to polished text
appearing at the cursor. It includes three phases: stop (audio
teardown), dictate (server round-trip), and inject (paste into app).

| Metric | Total | Dictate | Inject |
|--------|-------|---------|--------|
| min    | 0.39s | 0.29s   | 0.06s  |
| p50    | 0.57s | 0.49s   | 0.07s  |
| avg    | 0.68s | 0.60s   | 0.07s  |
| p95    | 1.47s | 1.38s   | 0.08s  |
| max    | 1.89s | 1.79s   | 0.09s  |

Audio recording durations ranged from 1.7s to 5.0s (avg 3.3s),
representing short and medium-length sentences typical of daily use.

| Threshold  | Sessions        |
|------------|-----------------|
| Under 0.5s | 11/30 (37%)    |
| Under 0.6s | 20/30 (67%)    |
| Under 0.75s | 22/30 (73%)   |
| Under 1.0s | 26/30 (87%)    |
| Under 1.5s | 29/30 (97%)    |

Two thirds of dictations complete in under 0.6 seconds.

### Accuracy

30/30 dictations produced the correct output.

| # | Spoke | Output | Total |
|---|-------|--------|-------|
| 1 | Sounds good, thanks. | Sounds good, thanks. | 0.55s |
| 2 | I'll look into that. | I'll look into that. | 0.48s |
| 3 | Can you send me that link? | Can you send me that link? | 0.46s |
| 4 | Let me check and get back to you. | Let me check and get back to you. | 0.58s |
| 5 | That makes sense to me. | That makes sense to me. | 0.55s |
| 6 | I'm free after two. | I'm free after two. | 1.89s |
| 7 | No changes needed. | No changes needed. | 0.39s |
| 8 | Works for me. | Works for me. | 0.57s |
| 9 | Let's go with option two. | Let's go with option two. | 1.14s |
| 10 | I'll handle it today. | I'll handle it today. | 0.67s |
| 11 | The build is passing, let's ship it. | The build is passing, let's ship it. | 0.42s |
| 12 | Can you set up a meeting for this week? | Can you set up a meeting for this week? | 0.43s |
| 13 | I just pushed the fix, it should be live after the next deploy. | I just pushed the fix, it should be live after the next deploy. | 0.51s |
| 14 | I think we should split this into two pull requests. | I think we should split this into two pull requests. | 1.47s |
| 15 | The customer called back and they're happy with the fix. | The customer called back and they're happy with the fix. | 0.42s |
| 16 | Let's skip the standup tomorrow and do an async update instead. | Let's skip the standup tomorrow and do an async update instead. | 0.58s |
| 17 | I talked to Sarah and she said the contract is almost ready. | I talked to Sarah and she said the contract is almost ready. | 0.50s |
| 18 | The numbers look good, but retention dropped a bit this month. | The numbers look good, but retention dropped a bit this month. | 0.57s |
| 19 | I need to buy apples, bananas, oranges, and a loaf of bread. | I need to buy apples, bananas, oranges, and a loaf of bread. | 0.49s |
| 20 | Can you review my pull request when you get a chance? | Can you review my pull request when you get a chance? | 0.87s |
| 21 | Let me know if you have any questions about the proposal. | Let me know if you have any questions about the proposal. | 0.87s |
| 22 | I moved the meeting to 3:30, hope that works. | I moved the meeting to 3:30, hope that works. | 0.81s |
| 23 | The API changes are done, just waiting on the front-end. | The API changes are done, just waiting on the front-end. | 0.50s |
| 24 | Good morning, just checking in on the status of the release. | Good morning, just checking in on the status of the release. | 0.43s |
| 25 | I'll send over the updated pricing by end of day. | I'll send over the updated pricing by end of day. | 0.45s |
| 26 | Let's table that discussion for now and revisit next week. | Let's table that discussion for now and revisit next week. | 0.57s |
| 27 | That bug is fixed, I added a test for it too. | That bug is fixed, I added a test for it too. | 0.73s |
| 28 | Can we push the launch to Wednesday? We need one more day. | Can we push the launch to Wednesday? We need one more day. | 1.20s |
| 29 | I agree, let's go ahead and merge it. | I agree, let's go ahead and merge it. | 0.58s |
| 30 | Thanks for the quick turnaround on that. | Thanks for the quick turnaround on that. | 0.80s |

### How latency is measured

The app instruments every dictation with four timestamps:

1. **t0:** `complete()` called (user releases the dictation key)
2. **t1:** Audio recording stopped, early silence check done
3. **t4:** Server returns polished text (streaming transcript finished + LLM polish)
4. **t5:** Text injected at cursor in the target app

| Phase | Calculation | What happens |
|-------|-------------|--------------|
| stop | t1 - t0 | Stop audio engine, check silence gate |
| dictate | t4 - t1 | Server finishes transcript, runs polish pipeline, returns text |
| inject | t5 - t4 | Paste text into the active app via accessibility API or Cmd+V |
| **total** | **t5 - t0** | **Key released to text visible** |

During recording, audio is streamed to the server over a persistent
WebSocket. The server forwards it to the Realtime API, which transcribes
incrementally. By the time the user releases the key, the transcript is
typically complete. The remaining server time is the polish step
(gpt-4.1-nano, ~0.4s when needed) and returning the result. A skip
heuristic bypasses the LLM entirely when the transcript is already
clean, which happens for roughly 40% of dictations.

---

## 50 Concurrent Users

Separate test. Simulated N users each with their own WebSocket
connection, all dictating at the same time on the same single Autonomy
container. Each user sends 4 seconds of synthetic audio (medium-length
sentence). Two rounds per concurrency level.

This measures server capacity, not transcription accuracy. It answers:
how many people can dictate simultaneously on one $75/mo container
before latency degrades?

**After-stop** is the time from sending "stop" to receiving the polished
transcript, the same phase as "dictate" in the real dictation test above.

| Concurrent users | Pass rate | After-stop p50 | After-stop p95 | After-stop max |
|------------------|-----------|----------------|----------------|----------------|
| 1                | 2/2       | 0.40s          | 0.40s          | 0.40s          |
| 5                | 10/10     | 0.30s          | 0.52s          | 0.52s          |
| 10               | 20/20     | 0.32s          | 1.14s          | 1.14s          |
| 25               | 50/50     | 0.33s          | 1.11s          | 1.19s          |
| 50               | 100/100   | 0.34s          | 1.26s          | 1.82s          |

No failures. The p50 stays flat at ~0.33s even at 50 concurrent users.
The p95 increases from 0.40s to 1.26s, meaning the slowest 5% of dictations at peak load still
complete in about a second.

A single $75/mo container serves 50 simultaneous dictations with
sub-second median latency and sub-2s worst case. Put differently: each
dictation lasts a few seconds, so even a 500-person team dictating
50 times a day would rarely exceed 10 concurrent sessions. A team of
several hundred could share a single container.
