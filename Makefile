PREFIX ?= $(HOME)/.local
HOBO_SIGN_IDENTITY ?= -
BIN := .build/release/hobo

.DEFAULT_GOAL := help
.PHONY: help build sign install test integration-test clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

build: ## Release build
	swift build -c release

sign: build ## Release build signed with the virtualization entitlement
	codesign --force --sign "$(HOBO_SIGN_IDENTITY)" --entitlements entitlements.plist --options runtime $(BIN)

install: sign ## Install the signed binary to $(PREFIX)/bin
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/hobo

test: ## Unit tests
	swift test

# The test runner can't hold the entitlement, so VM tests drive the signed binary.
integration-test: sign ## Tests that drive the signed binary
	HOBO_INTEGRATION=1 HOBO_BIN=$(abspath $(BIN)) swift test --filter HoboVMTests

clean: ## Remove build products
	swift package clean
