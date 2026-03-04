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
