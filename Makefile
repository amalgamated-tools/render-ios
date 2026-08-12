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

## test: run the RenderAPI package tests (no network)
.PHONY: test
test:
	cd Packages/RenderAPI && swift test

## run: build, install, and launch on the simulator
.PHONY: run
run:
	@Scripts/run-simulator.sh "$(SIMULATOR)"

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
