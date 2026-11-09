HOBO_SIGN_IDENTITY ?= -
RELEASE := .build/release
# Hobo.app (designs/hobo-app.md): the GUI is Contents/MacOS/Hobo, the CLI Contents/Helpers/hobo, and
# the payloads (agents, hobo-ui, Windows boot files and scripts, VM icon signs) Contents/Resources.
APP := .build/Hobo.app
BIN := $(APP)/Contents/Helpers/hobo
INSTALLED := /Applications/Hobo.app
CLI_LINK := /usr/local/bin/hobo
VERSION := $(shell sed -n 's/.*version = "\(.*\)"/\1/p' Sources/HoboCore/Hobo.swift)

.DEFAULT_GOAL := help
.PHONY: help build app sign install test integration-test readme readme-check site site-preview clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

build: ## Release build
	swift build -c release

app: build ## Assemble Hobo.app from the release build, unsigned
	rm -rf .build/Hobo.app
	install -d $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	sed 's/@VERSION@/$(VERSION)/g' App/Info.plist > $(APP)/Contents/Info.plist
	install -m 755 $(RELEASE)/HoboApp $(APP)/Contents/MacOS/Hobo
	install -m 755 $(RELEASE)/hobo $(BIN)
	cp -R $(RELEASE)/hobo_HoboVM.bundle/Contents/Resources/ $(APP)/Contents/Resources/
	cp assets/Hobo.icns $(APP)/Contents/Resources/

# Inside out: the CLI, then the app, which seals its resources. Both hold the virtualization
# entitlement: the CLI runs VM processes, and the GUI builds VMs in its own process.
sign: app ## Hobo.app signed with the virtualization entitlement
	codesign --force --sign "$(HOBO_SIGN_IDENTITY)" --entitlements entitlements.plist --options runtime $(BIN)
	codesign --force --sign "$(HOBO_SIGN_IDENTITY)" --entitlements entitlements.plist --options runtime $(APP)

# Links the CLI where the app's Install Command Line Tool does (with sudo if /usr/local/bin needs
# it), removes the binary older builds installed in ~/.local/bin, which would shadow the link, and
# refreshes hobo's global Claude skill if one is installed, so it matches the new binary.
SKILL := $(HOME)/.claude/skills/hobo/SKILL.md
install: sign ## Install Hobo.app to /Applications and link /usr/local/bin/hobo to its CLI
	rm -rf /Applications/Hobo.app
	ditto $(APP) $(INSTALLED)
	@target=$(INSTALLED)/Contents/Helpers/hobo; \
	  if [ "$$(readlink $(CLI_LINK))" != "$$target" ]; then \
	    { mkdir -p $(dir $(CLI_LINK)) && ln -sfn $$target $(CLI_LINK); } 2>/dev/null || \
	      sudo sh -c "mkdir -p $(dir $(CLI_LINK)) && ln -sfn $$target $(CLI_LINK)"; \
	  fi
	rm -f $(HOME)/.local/bin/hobo
	@if grep -qs '^hobo-version:' $(SKILL); then $(CLI_LINK) claude install; fi

test: readme-check ## README check, docs-script tests, then unit tests
	node --test 'site/scripts/*.test.mjs'
	swift test
	cd Agent && go test ./...

# README.md's feature tour is generated from docs/features/*.md (site/scripts/readme.mjs).
readme: ## Regenerate README.md's features from docs/features
	node site/scripts/readme.mjs

readme-check: ## Fail if README.md is out of date with docs/features
	node site/scripts/readme.mjs --check

site: ## Build the hobo.gsquared.app site into site/dist
	cd site && npm ci && npm run build

site-preview: ## Serve the site with live reload from docs/, and open it in the browser
	cd site && npm ci && npm run dev -- --open

# The test runner can't hold the entitlement, so VM tests drive the signed binary. A host-wide
# lock queues runs from different worktrees: only 2 macOS guests fit on a host.
INTEGRATION_LOCK := $(or $(HOBO_HOME),$(HOME)/.hobo)/integration.lock
integration-test: sign ## Tests that drive the signed binary
	@mkdir -p $(dir $(INTEGRATION_LOCK))
	HOBO_INTEGRATION=1 HOBO_BIN=$(abspath $(BIN)) lockf $(INTEGRATION_LOCK) swift test --filter HoboVMTests

clean: ## Remove build products
	swift package clean
