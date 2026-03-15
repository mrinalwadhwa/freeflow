# FreeFlow

A macOS app built on Autonomy.

## Install

```
brew install build-trust/freeflow/freeflow
```

Existing installs update automatically via Sparkle.

## Requirements

- macOS 13.0+
- Xcode 16+ / Swift 6+
- XcodeGen (`brew install xcodegen`)

## Building

```
make build
make run
make test
make clean
```

## Releasing

Releases are coordinated by a single script that handles both the macOS
app and the service image.

### Release the macOS app

```
./scripts/release.sh app
```

This tags the current version from Info.plist, pushes the tag, waits
for CI to build/sign/notarize, creates a GitHub Release with the DMG
and appcast, then updates the Homebrew Cask.

To set the version before releasing:

```
./scripts/release.sh app --version 0.2.0
```

### Release the service image

```
./scripts/release.sh image
```

This triggers the image build workflow, which builds and pushes the
FreeFlowService Docker image to ECR.

## License

TBD