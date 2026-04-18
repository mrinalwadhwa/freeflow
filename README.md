# FreeFlow – seamless speech to text in any app

Press a hotkey, dictate naturally, polished text appears in any app.

Ramble, use filler words, correct yourself mid-sentence. FreeFlow turns messy
speech into clean writing and injects it wherever your cursor is: your messaging app,
your editor, your coding agent, the terminal, email, anything.

It is open source, so you have the [freedom to customize](CUSTOMIZE.md) it any way you
want. It runs entirely on your Mac and talks directly to OpenAI with your own API key,
so your audio and transcripts never pass through anyone else's servers.

## Demo (sound on 🔊)

In this demo, you'll hear rambling speech with filler words and corrections. Watch what appears at the cursor.

https://github.com/user-attachments/assets/da62c769-d56b-4c16-be04-148197536dfa

## Install

Install the macOS app with [Homebrew](https://brew.sh) or [download the DMG](https://github.com/mrinalwadhwa/freeflow/releases/latest/download/FreeFlow.dmg) directly.

```
brew install mrinalwadhwa/freeflow/freeflow
```

On first launch, FreeFlow asks for your OpenAI API key and stores it in the macOS
Keychain. Create one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
After that, grant accessibility and microphone permissions and you are ready to dictate.

## Instant, polished, and accurate

Audio streams directly from your Mac to OpenAI's Realtime API over a persistent
WebSocket while you speak. The model transcribes incrementally, so by the time
you release the key the transcript is already done. A local skip heuristic
bypasses the polish step entirely for clean transcripts (roughly 40% of
dictations). When polish is needed, a fast chat model handles it in about 0.4
seconds. A warm backup connection is kept pre-opened in the background so that
the second and later dictations skip the WebSocket handshake entirely.

If the streaming path fails, FreeFlow falls back to OpenAI's batch transcription
endpoint automatically. Whichever path finishes first wins.

## Freedom: open, private, and unlimited

Everything is in this repo: the app, the providers, the polish pipeline, the
prompts. Change the models, rewrite the prompts, add a language, or fork the
whole thing. Your audio and transcripts flow directly from your Mac to OpenAI;
there is no FreeFlow server in the middle.

## Customize for your team

FreeFlow is designed to be taken apart and reassembled. Swap the speech
model, rewrite the polish prompt, add a language, or change how text is
injected. See [CUSTOMIZE.md](CUSTOMIZE.md).

## Contribute

Jump in, we'd love your help.

The single most useful contribution right now is
[mic compatibility data](https://github.com/mrinalwadhwa/freeflow/issues/2).
FreeFlow works well with built-in mics and AirPods, but every USB mic,
headset, and audio interface is different. The app's "Contribute Mic
Data" menu item generates a one-click diagnostic report that
can help us improve accuracy of dictation for everyone.

Want to add or improve support for a language? [Here's how.](https://github.com/mrinalwadhwa/freeflow/issues/1) Found an app where injection breaks? Open an issue. Code contributions and pull requests are welcome too. [DEVELOP.md](DEVELOP.md) has the build and test guide.
