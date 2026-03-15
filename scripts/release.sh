#!/bin/bash
set -euo pipefail

# Release FreeFlow: tag, push, wait for CI, update Homebrew Cask.
#
# Usage:
#   ./scripts/release.sh           # uses version from Info.plist
#   ./scripts/release.sh 0.2.0     # explicit version
#
# Expects:
#   - Working directory is the freeflow repo root
#   - ../homebrew is the homebrew-freeflow repo checkout
#   - gh CLI is authenticated
#   - No uncommitted changes

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOMEBREW_ROOT="$REPO_ROOT/../homebrew"
CASK_FILE="$HOMEBREW_ROOT/Casks/freeflow.rb"

cd "$REPO_ROOT"

# ── Preflight ──────────────────────────────────────────────────────

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: uncommitted changes in freeflow repo" >&2
  exit 1
fi

if [ ! -f "$CASK_FILE" ]; then
  echo "Error: $CASK_FILE not found" >&2
  echo "Expected homebrew-freeflow checkout at ../homebrew" >&2
  exit 1
fi

if [ -n "$(cd "$HOMEBREW_ROOT" && git status --porcelain)" ]; then
  echo "Error: uncommitted changes in homebrew repo" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not found" >&2
  exit 1
fi

# ── Version ────────────────────────────────────────────────────────

if [ $# -ge 1 ]; then
  VERSION="$1"
else
  VERSION=$(make version)
fi
TAG="v${VERSION}"

echo "Releasing FreeFlow ${VERSION} (tag: ${TAG})"
echo ""

# Check tag doesn't already exist
if git rev-parse "$TAG" &>/dev/null; then
  echo "Error: tag ${TAG} already exists" >&2
  exit 1
fi

# ── Tag and push ───────────────────────────────────────────────────

echo "── Tagging ${TAG} ──"
git tag -m "FreeFlow ${VERSION}" "$TAG"
git push origin "$TAG"

echo ""
echo "── Waiting for CI ──"
echo "The release environment requires your approval."
echo "Approve at: https://github.com/build-trust/freeflow/actions"
echo ""

# Wait for the workflow run to appear
sleep 5
RUN_ID=$(gh run list --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId')
if [ -z "$RUN_ID" ]; then
  echo "Error: no workflow run found for tag ${TAG}" >&2
  exit 1
fi

echo "Run: https://github.com/build-trust/freeflow/actions/runs/${RUN_ID}"
echo ""

# Wait for completion (this blocks until done or failed)
gh run watch "$RUN_ID" --exit-status
echo ""

# ── Download DMG and compute SHA256 ───────────────────────────────

echo "── Downloading DMG ──"
DMG_PATH=$(mktemp -d)/FreeFlow.dmg
gh release download "$TAG" --pattern "FreeFlow.dmg" --output "$DMG_PATH"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
rm -f "$DMG_PATH"

echo "  SHA256: ${SHA256}"
echo ""

# ── Update Homebrew Cask ──────────────────────────────────────────

echo "── Updating Homebrew Cask ──"
cd "$HOMEBREW_ROOT"

sed -i '' "s/version \".*\"/version \"${VERSION}\"/" Casks/freeflow.rb
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" Casks/freeflow.rb

echo "  Updated Casks/freeflow.rb:"
head -3 Casks/freeflow.rb | sed 's/^/    /'
echo ""

git add Casks/freeflow.rb
git commit -m "Update FreeFlow to ${VERSION}"
git push

echo ""
echo "══════════════════════════════════════════════════"
echo "  Release complete!"
echo "  Tag:      ${TAG}"
echo "  Release:  https://github.com/build-trust/freeflow/releases/tag/${TAG}"
echo "  Install:  brew install build-trust/freeflow/freeflow"
echo "══════════════════════════════════════════════════"
