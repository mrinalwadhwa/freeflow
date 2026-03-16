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

## Fast

There are some benchmarks in [BENCHMARK.md](BENCHMARK.md). Two thirds of dictations complete in under 0.6 seconds:

<p align="center">
  <img src=".github/assets/latency.svg" width="100%" alt="Latency chart: 30 dictations, each square is one dictation, p50 = 0.57s">
</p>