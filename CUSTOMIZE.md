# Customize FreeFlow

FreeFlow is designed to be taken apart and reassembled. This guide walks
through the most common customizations: changing the polish prompt,
changing the OpenAI models, and rebuilding the app with your changes.

## Overview

Everything runs on your Mac. There is no server deployment — the app
talks directly to OpenAI using your API key. To customize, you edit
code, rebuild the app, and use the rebuilt binary yourself.

## 1. Change a prompt

The polish prompts are inlined as string literals in
`FreeFlowKit/Sources/FreeFlowKit/Services/PolishPipeline.swift`:

| Constant | What it controls |
|----------|-----------------|
| `systemPromptEnglish` | English: filler removal, list formatting, dictated punctuation, corrections, number formatting, wording preservation |
| `systemPromptMinimal` | All other languages: light cleanup that preserves original phrasing |

Open `PolishPipeline.swift` and add a rule. For example, to make the
polish step produce British English:

    11. British English: use British spelling conventions. "organize" becomes
        "organise", "color" becomes "colour", "center" becomes "centre", etc.

Or to format code identifiers in backticks:

    11. Code identifiers: when the speaker mentions a function, variable,
        class name, or file path, wrap it in backticks. "the render function"
        becomes "the `render` function".

Add your rule at the end of the numbered list, before the final
instructions about language preservation and output format.

## 2. Change a model

Four constants control the entire AI pipeline. They are the default
argument values on the provider initializers:

| Constant | File | Default | What it does |
|----------|------|---------|-------------|
| `realtimeModel` | `OpenAIRealtimeProvider.swift` | `gpt-4o-realtime-preview` | Streaming speech-to-text via the Realtime API |
| `sttModel` | `OpenAIRealtimeProvider.swift` | `gpt-4o-mini-transcribe` | Transcription model within the Realtime session |
| `model` | `OpenAIDictationProvider.swift` | `gpt-4o-mini-transcribe` | Batch transcription model (used as fallback) |
| `polishModel` | both providers | `gpt-4.1-nano` | Text cleanup after transcription |

Change the string, rebuild, done.

## 3. Rebuild

    make generate   # Regenerate Xcode project
    make build      # Build the app

The debug build is at
`~/Library/Developer/Xcode/DerivedData/FreeFlow-*/Build/Products/Debug/FreeFlow.app`.
Launch it directly or replace your installed app with the rebuilt one.

## Going further

Everything else in `FreeFlowKit/Sources/FreeFlowKit/Services/` is open to
modification: audio capture, device switching, text injection, the
dictation pipeline state machine, even the Realtime protocol message
construction. The test suite under `FreeFlowKit/Tests/FreeFlowKitTests/`
covers every provider and pipeline stage so regressions are caught
quickly.
