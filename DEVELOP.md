# Develop

Build, test, and understand the FreeFlow codebase.

## Build

    make build       # debug build (generates Xcode project if missing)
    make test        # fast tests (~5s, 591 tests)
    make test-all    # full suite incl Keychain + slow tests (~90s)
    make clean       # clean everything
    make xcode       # open in Xcode

`FREEFLOW_TEST_KEYCHAIN=1` enables Keychain tests (require macOS login
Keychain access, trigger password prompts). `FREEFLOW_TEST_SLOW=1`
enables timeout and backup connection tests (~80s).

## Project structure

The repo has three main directories:

**`FreeFlowApp/`** — macOS app. Menu bar UI, onboarding, provisioning,
settings, HUD overlay. Sources are in `Sources/`, bundled HTML and
assets in `Resources/`.

**`FreeFlowKit/`** — Swift framework with the testable core. The
dictation pipeline, streaming and batch providers, audio capture,
device switching, text injection, Keychain storage, and the recording
state machine. Protocols for every provider enable dependency injection
in tests.

**`FreeFlowService/`** — Python server deployed as an Autonomy zone.
`autonomy.yaml` defines the zone. `images/main/` contains the
Dockerfile and all server code: FastAPI endpoints (`main.py`),
Realtime API streaming (`realtime.py`), the polish pipeline
(`polish.py` + prompt text files), auth, invites, admin, and a
Node.js better-auth service in `auth/`.

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