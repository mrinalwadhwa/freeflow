# Benchmark

## Hot path

FreeFlow talks directly to OpenAI from the Mac. On each dictation the app:

1. Opens a WebSocket to `wss://api.openai.com/v1/realtime` and configures it
   for transcription only (the first session pays the ~300 ms handshake; later
   sessions adopt a warm backup connection pre-opened in the background and
   skip the handshake entirely).
2. Streams 16 kHz PCM chunks resampled to 24 kHz while the user holds the
   dictation key.
3. On key release, commits the audio buffer and waits for the
   `conversation.item.input_audio_transcription.completed` event.
4. Runs the raw transcript through the local polish pipeline: deterministic
   regex substitution → `is_clean` skip heuristic → (optional) a single
   `gpt-4.1-nano` chat completion for LLM refinement.
5. Injects the polished text into the target app via the accessibility API.

A batch fallback (`POST /v1/audio/transcriptions` with the full WAV) catches
the case where the Realtime WebSocket cannot be established or errors out
mid-session.

## Measuring locally

Two gated benchmark suites live in
`FreeFlowKit/Tests/FreeFlowKitTests/OpenAIRealtimeBenchmarkTests.swift`:

- `bench: single session breakdown` — one full session, prints
  startStreaming / sendAudio / finishStreaming / total.
- `bench: 5 sessions with 1.5 s gap (warm backup)` — five sequential sessions
  with a realistic gap between them so the background warm-backup task has
  time to pre-open the next connection.

Run them with:

```bash
OPENAI_API_KEY=sk-... \
FREEFLOW_TEST_OPENAI=1 \
FREEFLOW_TEST_OPENAI_BENCH=1 \
swift test --filter OpenAIRealtimeBenchmark 2>&1 | tail -20
```

The benchmarks currently drive the Realtime API with silent PCM, which is a
worst case for `finishStreaming` (there is no speech content for the model
to transcribe). A real-speech end-to-end benchmark capturing mic → paste
latency can be taken from the release build once the app is installed.
