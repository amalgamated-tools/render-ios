SIMULATOR ?= iPhone 17 Pro
# Overridable so CI can build against 'generic/platform=iOS Simulator' and not depend on a
# particular simulator being installed on the runner.
DESTINATION ?= platform=iOS Simulator,name=$(SIMULATOR)
# Extra flags for xcodebuild — CI passes -clonedSourcePackagesDirPath to make SPM checkouts cacheable.
XCODEBUILD_FLAGS ?=

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
