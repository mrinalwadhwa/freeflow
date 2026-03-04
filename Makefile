.PHONY: build run test clean xcode generate

# XcodeGen must be installed: brew install xcodegen
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := Voice.xcodeproj
SCHEME   := VoiceApp
CONFIG   := Debug

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

# Run VoiceKit tests via Swift Package Manager (no Xcode project needed)
test:
	cd VoiceKit && swift test

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
