# Develop

Build, test, customize, and understand the FreeFlow codebase.

## Prerequisites

- macOS 14+
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

    make build       # debug build (generates Xcode project if missing)
    make test        # fast tests (~5s)
    make test-all    # full suite incl Keychain + slow tests (~90s)
    make clean       # clean everything
    make xcode       # open in Xcode

`FREEFLOW_TEST_KEYCHAIN=1` enables Keychain tests (require macOS login
Keychain access, trigger password prompts). `FREEFLOW_TEST_OPENAI=1`
enables live tests that hit the real OpenAI API and require
`OPENAI_API_KEY` to be set. `FREEFLOW_TEST_OPENAI_BENCH=1` additionally
enables the latency benchmark suite.

## Project structure

The repo has two main directories:

**`FreeFlowApp/`** — macOS app. Menu bar UI, onboarding, settings, HUD
overlay. Sources are in `Sources/`, bundled HTML and assets in
`Resources/`.

**`FreeFlowKit/`** — Swift package with the testable core. The
dictation pipeline, streaming and batch OpenAI providers, the polish
pipeline, audio capture, device switching, text injection, Keychain
storage, and the recording state machine. Protocols for every provider
enable dependency injection in tests.

## Customize

FreeFlow is designed to be taken apart and reassembled. Edit code,
rebuild, and use the rebuilt binary.

### Change a prompt

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

### Change a model

Four constants control the entire AI pipeline. They are the default
argument values on the provider initializers:

| Constant | File | Default | What it does |
|----------|------|---------|-------------|
| `realtimeModel` | `OpenAIRealtimeProvider.swift` | `gpt-4o-realtime-preview` | Streaming speech-to-text via the Realtime API |
| `sttModel` | `OpenAIRealtimeProvider.swift` | `gpt-4o-mini-transcribe` | Transcription model within the Realtime session |
| `model` | `OpenAIDictationProvider.swift` | `gpt-4o-mini-transcribe` | Batch transcription model (used as fallback) |
| `polishModel` | both providers | `gpt-4.1-nano` | Text cleanup after transcription |

Change the string, rebuild, done.

### Rebuild

    make generate   # Regenerate Xcode project
    make build      # Build the app

The debug build is at
`~/Library/Developer/Xcode/DerivedData/FreeFlow-*/Build/Products/Debug/FreeFlow.app`.
Launch it directly or replace your installed app with the rebuilt one.

Everything else in `FreeFlowKit/Sources/FreeFlowKit/Services/` is open
to modification: audio capture, device switching, text injection, the
dictation pipeline state machine, even the Realtime protocol message
construction. The test suite covers every provider and pipeline stage so
regressions are caught quickly.

## App icon

The app icon is a 6-bar waveform squircle. The source SVG is
`FreeFlowApp/AppIcon.svg`.

### Regenerating

Requires `rsvg-convert` (install via `brew install librsvg` or Nix):

    rsvg-convert -w 1024 -h 1024 FreeFlowApp/AppIcon.svg -o /tmp/AppIcon-1024.png

    mkdir -p /tmp/AppIcon.iconset
    sips -z 16 16     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_16x16.png
    sips -z 32 32     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png
    sips -z 32 32     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_32x32.png
    sips -z 64 64     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png
    sips -z 128 128   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_128x128.png
    sips -z 256 256   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png
    sips -z 256 256   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_256x256.png
    sips -z 512 512   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png
    sips -z 512 512   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_512x512.png
    cp /tmp/AppIcon-1024.png /tmp/AppIcon.iconset/icon_512x512@2x.png

    iconutil -c icns /tmp/AppIcon.iconset -o FreeFlowApp/Resources/AppIcon.icns

The `.icns` file is referenced by `CFBundleIconFile` in
`FreeFlowApp/Info.plist`. After regenerating, run `xcodegen generate`
and rebuild.
