.PHONY: build run test clean xcode generate release archive sign notarize appcast

# XcodeGen must be installed: brew install xcodegen
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := Voice.xcodeproj
SCHEME   := VoiceApp
CONFIG   := Debug

# Release settings
TEAM_ID          := 3A56YKKGA5
SIGN_IDENTITY    := Developer ID Application: Ockam Inc. ($(TEAM_ID))
NOTARIZE_PROFILE := voice-notarize
ARCHIVE_PATH     := build/Voice.xcarchive
APP_PATH         := build/Voice.app
RELEASE_DIR      := releases
ZIP_NAME         := Voice.zip
ZIP_PATH         := $(RELEASE_DIR)/$(ZIP_NAME)
DOWNLOAD_URL     := https://autonomy.computer/voice/
SPARKLE_BIN      := $(shell find ~/Library/Developer/Xcode/DerivedData/Voice-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

# Generate the Xcode project from project.yml
generate:
ifndef XCODEGEN
	$(error "xcodegen not found. Install with: brew install xcodegen")
endif
	xcodegen generate

# Build the app (generates project first if missing)
build: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

# Build and launch
run: build
	@open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | grep -m1 ' BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Voice.app"

# Run all VoiceKit tests via Swift Package Manager (no Xcode project needed).
# swift test runs both XCTest-based and Swift Testing suites in one invocation,
# but the final summary line only counts Swift Testing tests. This target parses
# the full output to report a combined total from both frameworks.
test:
	@cd VoiceKit && swift test 2>&1 | tee .test_output; \
	exit_code=$$?; \
	xc_pass=`grep -c '^Test Case.*passed' .test_output || true`; \
	xc_fail=`grep -c '^Test Case.*failed' .test_output || true`; \
	st_line=`grep 'Test run with' .test_output || true`; \
	st_total=`echo "$$st_line" | sed -n 's/.*with \([0-9]*\) tests.*/\1/p'`; \
	st_total=$${st_total:-0}; \
	xc_pass=$${xc_pass:-0}; \
	xc_fail=$${xc_fail:-0}; \
	total=`expr $$xc_pass + $$xc_fail + $$st_total`; \
	fail=$$xc_fail; \
	echo ""; \
	echo "── Combined: $$total tests (`expr $$xc_pass + $$xc_fail` XCTest + $$st_total Swift Testing), $$fail failures ──"; \
	rm -f .test_output; \
	exit $$exit_code

# Clean build artifacts
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	cd VoiceKit && swift package clean
	rm -rf DerivedData build

# Open in Xcode (generates project first if missing)
xcode: $(PROJECT)
	open $(PROJECT)

# Generate the project if it doesn't exist
$(PROJECT): project.yml
	$(MAKE) generate

# ---------------------------------------------------------------------------
# Release pipeline: archive → sign → zip → notarize → staple → appcast
# ---------------------------------------------------------------------------

# Full release pipeline
release: archive sign notarize appcast
	@echo ""
	@echo "══════════════════════════════════════════════════"
	@echo "  Release complete!"
	@echo "  ZIP:     $(ZIP_PATH)"
	@echo "  Appcast: $(RELEASE_DIR)/appcast.xml"
	@echo "══════════════════════════════════════════════════"

# Archive a Release build and export the app
archive: $(PROJECT)
	@echo "── Archiving Release build ──"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		ENABLE_HARDENED_RUNTIME=YES \
		archive
	@echo "── Extracting app from archive ──"
	@rm -rf $(APP_PATH)
	@cp -R "$(ARCHIVE_PATH)/Products/Applications/Voice.app" $(APP_PATH)

# Sign the app bundle with hardened runtime and entitlements.
# Sparkle embeds XPC services and a nested Updater.app that must be
# signed inside-out: innermost bundles first, then the framework, then
# the outer app. codesign --deep cannot handle this reliably.
sign:
	@echo "── Signing Sparkle nested components ──"
	@SPARKLE_FW="$(APP_PATH)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	for xpc in "$$SPARKLE_FW/XPCServices/Installer.xpc" \
	           "$$SPARKLE_FW/XPCServices/Downloader.xpc"; do \
		if [ -d "$$xpc" ]; then \
			echo "  Signing $$xpc"; \
			codesign --force --options runtime --sign "$(SIGN_IDENTITY)" --timestamp "$$xpc"; \
		fi; \
	done; \
	if [ -d "$$SPARKLE_FW/Updater.app" ]; then \
		echo "  Signing $$SPARKLE_FW/Updater.app"; \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" --timestamp "$$SPARKLE_FW/Updater.app"; \
	fi; \
	if [ -f "$$SPARKLE_FW/Autoupdate" ]; then \
		echo "  Signing $$SPARKLE_FW/Autoupdate"; \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" --timestamp "$$SPARKLE_FW/Autoupdate"; \
	fi
	@echo "── Signing Sparkle framework ──"
	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		--timestamp \
		"$(APP_PATH)/Contents/Frameworks/Sparkle.framework/Versions/B"
	@echo "── Signing app bundle ──"
	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		--entitlements VoiceApp/Voice.entitlements \
		--timestamp \
		$(APP_PATH)
	@echo "── Verifying signature ──"
	codesign --verify --deep --strict --verbose=2 $(APP_PATH)
	@echo "── Creating ZIP ──"
	@mkdir -p $(RELEASE_DIR)
	@rm -f $(ZIP_PATH)
	@cd build && ditto -c -k --keepParent Voice.app ../$(ZIP_PATH)
	@echo "  $(ZIP_PATH) ($$(du -h $(ZIP_PATH) | cut -f1))"

# Submit ZIP to Apple notarization and staple the ticket
notarize:
	@echo "── Submitting to Apple notarization ──"
	xcrun notarytool submit $(ZIP_PATH) \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	@echo "── Stapling notarization ticket ──"
	xcrun stapler staple $(APP_PATH)
	@echo "── Re-creating ZIP with stapled ticket ──"
	@rm -f $(ZIP_PATH)
	@cd build && ditto -c -k --keepParent Voice.app ../$(ZIP_PATH)
	@echo "  $(ZIP_PATH) ($$(du -h $(ZIP_PATH) | cut -f1))"
	@echo "── Verifying Gatekeeper approval ──"
	spctl --assess --type execute --verbose=2 $(APP_PATH)

# Generate or update appcast.xml from the release ZIP
appcast:
ifeq ($(SPARKLE_BIN),)
	$(error "Sparkle tools not found. Run 'make build' first to fetch the Sparkle package.")
endif
	@echo "── Generating appcast ──"
	"$(SPARKLE_BIN)/generate_appcast" \
		--download-url-prefix "$(DOWNLOAD_URL)" \
		-o $(RELEASE_DIR)/appcast.xml \
		$(RELEASE_DIR)
	@echo "  $(RELEASE_DIR)/appcast.xml"
