SIMULATOR ?= iPhone 17 Pro
# Overridable so CI can build against 'generic/platform=iOS Simulator' and not depend on a
# particular simulator being installed on the runner.
DESTINATION ?= platform=iOS Simulator,name=$(SIMULATOR)
# Extra flags for xcodebuild — CI passes -clonedSourcePackagesDirPath to make SPM checkouts cacheable.
XCODEBUILD_FLAGS ?=

# Distribution. TEAM_ID is your 10-character Apple Developer Team ID; it is deliberately not checked
# into project.pbxproj, so a fresh clone doesn't try to sign against an account it can't reach.
TEAM_ID ?=
ARCHIVE_PATH ?= build/RenderiOS.xcarchive
EXPORT_PATH ?= build/export

.DEFAULT_GOAL := check

## check: everything CI would run
.PHONY: check
check: test build

## build: build the iOS app for the simulator
.PHONY: build
build:
	xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
	  -destination '$(DESTINATION)' $(XCODEBUILD_FLAGS) build

## test: run every unit test (no network)
.PHONY: test
test: test-package test-app

## test-package: RenderAPI package tests — fast, no simulator
.PHONY: test-package
test-package:
	cd Packages/RenderAPI && swift test

## test-app: app-target tests (stores) — needs a simulator, resolved at run time
.PHONY: test-app
test-app:
	xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
	  -destination "$$(Scripts/test-destination.sh)" $(XCODEBUILD_FLAGS) test

## run: build, install, and launch on the simulator
.PHONY: run
run:
	@Scripts/run-simulator.sh "$(SIMULATOR)"

## walkthrough: record a scripted tour of the app (signs in with the key in .env)
.PHONY: walkthrough
walkthrough:
	@SIMULATOR="$(SIMULATOR)" Scripts/record-walkthrough.sh

## walkthrough-oauth: the same tour, signing in through the OAuth device flow (waits for you)
.PHONY: walkthrough-oauth
walkthrough-oauth:
	@SIMULATOR="$(SIMULATOR)" Scripts/record-walkthrough-oauth.sh

## walkthrough-captions: burn the recorder's beats file into the picture as subtitles
.PHONY: walkthrough-captions
walkthrough-captions:
	@Scripts/burn-captions.sh

## walkthrough-verify: one frame per beat, tiled — check the tour visited what it narrates
.PHONY: walkthrough-verify
walkthrough-verify:
	@Scripts/verify-walkthrough.sh

## register-device: register a connected iPhone with TEAM_ID — once, before a new team's first archive
.PHONY: register-device
# Automatic signing makes a development profile before `archive`, and Apple only issues one to a
# team with a registered device. The archive's generic destination has no device to register, so
# this builds once for the connected iPhone (or DEVICE_ID=<UDID>), which registers it.
register-device:
	@test -n "$(TEAM_ID)" || { echo "TEAM_ID is unset — pass your 10-character Apple Team ID: make register-device TEAM_ID=XXXXXXXXXX"; exit 1; }
	@id='$(DEVICE_ID)'; \
	if [ -z "$$id" ]; then \
	  id=$$(xcrun devicectl list devices 2>/dev/null | grep -E 'available.*physical' \
	    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9a-f]{40}' | head -1); \
	fi; \
	test -n "$$id" || { echo "No connected iPhone found. Plug one in and trust this Mac, or pass DEVICE_ID=<UDID>."; exit 1; }; \
	echo "Registering $$id with team $(TEAM_ID)"; \
	xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
	  -destination "id=$$id" \
	  DEVELOPMENT_TEAM='$(TEAM_ID)' \
	  -allowProvisioningUpdates -allowProvisioningDeviceRegistration $(XCODEBUILD_FLAGS) build

## archive: build a signed device archive for distribution (needs TEAM_ID=XXXXXXXXXX)
.PHONY: archive
# On a team with no registered devices, run `make register-device` first.
archive:
	@test -n "$(TEAM_ID)" || { echo "TEAM_ID is unset — pass your 10-character Apple Team ID: make archive TEAM_ID=XXXXXXXXXX"; exit 1; }
	xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
	  -destination 'generic/platform=iOS' \
	  -archivePath '$(ARCHIVE_PATH)' \
	  DEVELOPMENT_TEAM='$(TEAM_ID)' \
	  -allowProvisioningUpdates $(XCODEBUILD_FLAGS) archive

## ipa: turn the archive into an .ipa ready to upload to TestFlight
# Not called `export`: that's a GNU make directive, and a target sharing the name is ambiguous.
.PHONY: ipa
ipa: archive
	@cp Scripts/ExportOptions.plist build/ExportOptions.plist
	@/usr/libexec/PlistBuddy -c "Set :teamID $(TEAM_ID)" build/ExportOptions.plist
	xcodebuild -exportArchive -archivePath '$(ARCHIVE_PATH)' \
	  -exportPath '$(EXPORT_PATH)' -exportOptionsPlist build/ExportOptions.plist \
	  -allowProvisioningUpdates
	@echo
	@echo "Wrote $(EXPORT_PATH)/RenderiOS.ipa — upload it with Transporter.app, or:"
	@echo "  xcrun altool --upload-app -f $(EXPORT_PATH)/RenderiOS.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
	@echo "Bump CURRENT_PROJECT_VERSION before the next upload — build numbers must not repeat."

## generate: re-vendor the OpenAPI spec and regenerate the client
.PHONY: generate
generate:
	@Scripts/generate-api.sh

## drift: check whether Render has changed the spec since it was last vendored
.PHONY: drift
drift: generate
	@git diff --stat -- Packages/RenderAPI \
	  | grep . && echo "^^ spec drifted — review the diff" || echo "no drift"

.PHONY: clean
clean:
	rm -rf build Packages/RenderAPI/.build

.PHONY: help
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
