# NovelReader — SwiftUI iOS app
#
# Quick start after clone:
#   make setup      # install xcodegen (if needed) + generate NovelReader.xcodeproj
#   make test       # run the unit test suite (boots a simulator if none is running)
#   make run        # build, install, and launch the app on a simulator
#
# NovelReader.xcodeproj is generated from project.yml via xcodegen — it is not
# hand-edited and not committed. Edit project.yml, then `make generate`.

PROJECT   := NovelReader.xcodeproj
SCHEME    := NovelReader
CONFIGURATION := Debug
DERIVED   := build
APP       := $(DERIVED)/Build/Products/$(CONFIGURATION)-iphonesimulator/$(SCHEME).app
ARCHIVE   := $(DERIVED)/$(SCHEME).xcarchive
EXPORT    := $(DERIVED)/export
BUNDLE_ID := com.zeyanlin.novelreader
TEAM_ID   := NKJSLB6HBR
SIMULATOR ?= iPhone 17
IPAD      ?= iPad Pro 13-inch (M5)

# App Store Connect accepts one iPhone size and one iPad size and scales the
# rest, so shoot the largest of each: 6.9" (1320x2868) and 13" (2064x2752).
SHOT_PHONE ?= iPhone 17 Pro Max
SHOT_IPAD  ?= iPad Pro 13-inch (M5)
SHOT_LANGS ?= zh-Hant zh-Hans en
SHOTS      ?= screenshots

.DEFAULT_GOAL := help
.PHONY: help setup generate build test test-ui test-ui-live test-live run run-iphone run-ipad open release archive ipa package clean screenshots shots-device

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# --- Setup / housekeeping ---

setup: ## install xcodegen (if needed) and generate the Xcode project
	@which xcodegen > /dev/null || brew install xcodegen
	$(MAKE) generate

generate: ## regenerate NovelReader.xcodeproj from project.yml (source of truth)
	xcodegen generate

clean: ## Remove build artifacts
	rm -rf $(DERIVED)
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true

# --- App: requires the iOS simulator runtime ---

build: generate ## Compile the app for the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) build

test: generate ## Run unit tests (XCTest)
	@# Tests need a concrete simulator; the generic destination is build-only.
	xcodebuild test -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-only-testing:NovelReaderTests \
		-enableCodeCoverage YES

test-ui: generate ## Run the UI smoke walk (boots the app; no network needed)
	xcodebuild test -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-only-testing:NovelReaderUITests

test-ui-live: generate ## Run the UI walk including the network-dependent read-a-book path
	TEST_RUNNER_NOVELREADER_LIVE=1 \
	xcodebuild test -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-only-testing:NovelReaderUITests

test-live: generate ## Run the opt-in live site checks (needs a network; slow)
	@# Excluded from `make test` on purpose: these fail on site redesigns and
	@# Cloudflare challenges, which must never turn a code regression green.
	@# TEST_RUNNER_ is xcodebuild's prefix for "pass this into the test process".
	TEST_RUNNER_NOVELREADER_LIVE=1 \
	xcodebuild test -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-only-testing:NovelReaderTests/LiveSiteTests

run: build ## Build, then install & launch on BOTH the iPhone and iPad simulators
	@# Target devices by name (not "booted") so both can run side by side.
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	@xcrun simctl boot "$(IPAD)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIMULATOR)" "$(APP)"
	xcrun simctl launch "$(SIMULATOR)" $(BUNDLE_ID)
	xcrun simctl install "$(IPAD)" "$(APP)"
	xcrun simctl launch "$(IPAD)" $(BUNDLE_ID)

run-iphone: build ## Build, then install & launch on the iPhone simulator only
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIMULATOR)" "$(APP)"
	xcrun simctl launch "$(SIMULATOR)" $(BUNDLE_ID)

run-ipad: build ## Build, then install & launch on the iPad simulator only
	@xcrun simctl boot "$(IPAD)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(IPAD)" "$(APP)"
	xcrun simctl launch "$(IPAD)" $(BUNDLE_ID)

# --- App Store screenshots ---

screenshots: generate ## Capture App Store screenshots (all languages, iPhone 6.9" + iPad 13")
	@# Fictional demo library (DemoSeed, Debug-only): the listing must not name
	@# a content source, since the app itself ships pointing at none.
	@for lang in $(SHOT_LANGS); do \
		$(MAKE) --no-print-directory shots-device DEVICE="$(SHOT_PHONE)" LANG_ID=$$lang OUT="$(SHOTS)/$$lang/iphone-6.9" || exit 1; \
		$(MAKE) --no-print-directory shots-device DEVICE="$(SHOT_IPAD)"  LANG_ID=$$lang OUT="$(SHOTS)/$$lang/ipad-13" || exit 1; \
	done
	@echo "screenshots → $(SHOTS)/"

shots-device:
	@rm -rf "$(DERIVED)/shots.xcresult" "$(OUT)"
	@mkdir -p "$(OUT)"
	@echo "→ $(DEVICE) [$(LANG_ID)]"
	@TEST_RUNNER_NOVELREADER_SCREENSHOTS=1 \
	TEST_RUNNER_NOVELREADER_SHOT_LANG=$(LANG_ID) \
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED) \
		-resultBundlePath "$(DERIVED)/shots.xcresult" \
		-destination 'platform=iOS Simulator,name=$(DEVICE)' \
		-only-testing:NovelReaderUITests/ScreenshotTests \
		> "$(DERIVED)/shots.log" 2>&1 \
		|| { tail -40 "$(DERIVED)/shots.log"; exit 1; }
	@# Attachments come out under generated filenames; manifest.json carries the
	@# name the test gave each one, which is what makes the output reviewable.
	@xcrun xcresulttool export attachments \
		--path "$(DERIVED)/shots.xcresult" --output-path "$(OUT)" >/dev/null
	@python3 scripts/name_screenshots.py "$(OUT)"

open: generate ## Open the project in Xcode
	open $(PROJECT)

# --- Release: signed App Store build (needs Xcode signed in to your Apple ID) ---

release: archive ipa ## Archive + export an uploadable .ipa

archive: generate ## Archive a signed Release build (auto signing)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-allowProvisioningUpdates \
		archive

ipa: ## Export an uploadable .ipa from the archive (run `make archive` first)
	@# Force the system rsync first: a Homebrew rsync in PATH breaks the IPA
	@# packaging step with "Copy failed" (extended-attributes incompatibility).
	PATH="/usr/bin:/bin:/usr/sbin:/sbin:$$PATH" xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportOptionsPlist exportOptions.plist \
		-exportPath $(EXPORT) \
		-allowProvisioningUpdates
	@echo "IPA → $(EXPORT)/$(SCHEME).ipa  (upload via Transporter)"

package: archive ipa ## Archive + export an uploadable .ipa — needs a real teamID in exportOptions.plist
