# FreeFlow

Press a hotkey, dictate naturally, polished text appears in any app.

Ramble, use filler words, correct yourself mid-sentence. FreeFlow turns messy
speech into clean writing and injects it wherever your cursor is: your messaging app,
your editor, your coding agent, the terminal, email, anything.

It is open source, so you have the [freedom to customize](CUSTOMIZE.md) it any way you want. You deploy it
on a server private to you, so your audio and data flow through infrastructure
you control.

One deployment serves your entire team with no per-seat fees.

## Demo (sound on 🔊)

In this demo, you'll hear rambling speech with filler words and corrections. Watch what appears at the cursor.

<p align="center">
  <video src="https://github.com/user-attachments/assets/7e6cfd80-c7a8-4d3c-b31b-727887c94b77" autoplay loop playsinline></video>
</p>

## Install

Install with [Homebrew](https://brew.sh) or download [FreeFlow.dmg](https://github.com/build-trust/freeflow/releases/latest/download/FreeFlow.dmg) directly.

```
brew install build-trust/freeflow/freeflow
```

On first launch, FreeFlow walks you through setup: create an [Autonomy](https://autonomy.computer) account, deploy your server, and start dictating. About two minutes to your first dictation.

## Fast, polished, and accurate

There are some benchmarks in [BENCHMARK.md](BENCHMARK.md). Two thirds of dictations complete in under 0.6 seconds:

<p align="center">
  <img src=".github/assets/latency.svg" width="100%" alt="Latency chart: 30 dictations, each square is one dictation, p50 = 0.57s">
</p>

Audio streams to your private server over a persistent WebSocket while you speak.
The server forwards it to a realtime model, which transcribes incrementally. By the
time you release the key, the transcript is already done. A skip heuristic
bypasses the polish step entirely for clean transcripts (roughly 40% of dictations).
When polish is needed, a fast model handles it in about 0.4 seconds.

Two independent WebSocket connections are kept warm: a primary that streams
audio during recording, and a standby that races the primary with the full
audio buffer when you release the key. If both WebSockets fail, an HTTP batch
fallback catches it. Whichever path finishes first wins.

<p align="center">
  <img src=".github/assets/how-it-works.svg" width="100%" alt="How it works: FreeFlow streams audio from your Mac to your private server to a realtime speech model, then returns polished text">
</p>

## Freedom: open, private, and unlimited

Everything is in this repo: the app, the server, the deployment
configuration. Change the models, rewrite the prompts, add a language, or
fork the whole thing. Your team's audio, transcripts, and context data flow through your private FreeFlow Server deployed in [Autonomy](https://autonomy.computer).

One container handles your entire team with no per-seat fees. In our
[concurrent users benchmark](BENCHMARK.md), 50 people dictating
simultaneously produced sub-second median latency with zero failures.
Each dictation only occupies the server for a few seconds, so 50
concurrent slots supports hundreds of users in practice. The economics
improve as you add people because the infrastructure cost is small and fixed.
