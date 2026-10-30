PREFIX ?= $(HOME)/.local
HOBO_SIGN_IDENTITY ?= -
BIN := .build/release/hobo
RECIPE ?= Recipes/macos-27.toml
# macOS 27.2 (26B123) as downloaded into the depot by a `latest` build; empty if absent.
HOBO_TEST_IPSW ?= $(wildcard $(HOME)/.hobo/depot/6613b34e8589db2202a01ec37a2648afb141ece13428175183f8f3e38438534f.ipsw)

.DEFAULT_GOAL := help
.PHONY: help build sign install test integration-test box clean

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
# The box build test runs only when HOBO_TEST_IPSW names an existing IPSW.
integration-test: sign ## VM-booting tests (box build uses HOBO_TEST_IPSW)
	HOBO_INTEGRATION=1 HOBO_BIN=$(abspath $(BIN)) $(if $(HOBO_TEST_IPSW),HOBO_TEST_IPSW=$(HOBO_TEST_IPSW)) \
		swift test --filter HoboVMTests

box: sign ## Build a box: make box RECIPE=Recipes/macos-27.toml
	$(BIN) box build $(RECIPE)

clean: ## Remove build products
	swift package clean
