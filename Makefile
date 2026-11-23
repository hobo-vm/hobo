HOBO_SIGN_IDENTITY ?= -
RELEASE := .build/release
# Laid out as Homebrew lays out a formula (docs/design.md decision 22): the CLI in bin/hobo and the
# payloads (agents, hobo-ui, Windows boot files and scripts, VM icon signs) in share/hobo beside it.
STAGE := .build/hobo
BIN := $(STAGE)/bin/hobo
PREFIX ?= /usr/local

.DEFAULT_GOAL := help
.PHONY: help build sign install release release-test test integration-test test-vms readme readme-check windows-ui windows-ui-check site site-preview clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

build: ## Release build
	swift build -c release

# The staged tree, signed with the virtualization entitlement (ad-hoc unless HOBO_SIGN_IDENTITY names one).
sign: build ## Stage .build/hobo (bin/hobo, share/hobo) and sign the CLI with the virtualization entitlement
	rm -rf $(STAGE)
	install -d $(STAGE)/bin $(STAGE)/share/hobo
	install -m 755 $(RELEASE)/hobo $(BIN)
	cp -R $(RELEASE)/hobo_HoboVM.bundle/Contents/Resources/ $(STAGE)/share/hobo/
	codesign --force --sign "$(HOBO_SIGN_IDENTITY)" --entitlements entitlements.plist --options runtime $(BIN)

# Copies the staged tree into PREFIX (with sudo if it needs it), removes the binary older builds
# installed in ~/.local/bin, which would shadow it, and refreshes hobo's global Claude skill if one
# is installed, so it matches the new binary.
SKILL := $(HOME)/.claude/skills/hobo/SKILL.md
install: sign ## Install bin/hobo and share/hobo under PREFIX (default /usr/local)
	@copy='rm -f $(PREFIX)/bin/hobo && rm -rf $(PREFIX)/share/hobo && install -d $(PREFIX)/bin $(PREFIX)/share/hobo && install -m 755 $(BIN) $(PREFIX)/bin/hobo && ditto $(STAGE)/share/hobo $(PREFIX)/share/hobo'; \
	  sh -c "$$copy" 2>/dev/null || sudo sh -c "$$copy"
	rm -f $(HOME)/.local/bin/hobo
	@if grep -qs '^hobo-version:' $(SKILL); then $(PREFIX)/bin/hobo claude install; fi

# A release is cut on main by scripts/release.sh; scripts/package.sh makes what it publishes.
release: ## Cut a release: tests, tarball, tag, GitHub release and Homebrew tap (VERSION=x.y.z, default the next minor)
	VERSION="$(VERSION)" scripts/release.sh

release-test: sign ## Package .build/dist (tarball, formula) and brew install the formula from the local tarball
	scripts/package.sh --test

test: readme-check windows-ui-check ## README and Windows backend checks, docs-script tests, then unit tests
	node --test 'site/scripts/*.test.mjs'
	swift test
	cd Agent && go test ./...

# README.md's feature tour is generated from docs/features/*.md (site/scripts/readme.mjs).
readme: ## Regenerate README.md's features from docs/features
	node site/scripts/readme.mjs

readme-check: ## Fail if README.md is out of date with docs/features
	node site/scripts/readme.mjs --check

# hobo ui's Windows backend is built in a Windows VM and committed (scripts/windows-ui.sh).
windows-ui: ## Rebuild hobo ui's Windows backend in a Windows build VM
	scripts/windows-ui.sh build

windows-ui-check: ## Fail if hobo ui's Windows backend is out of date with UIWindows/
	scripts/windows-ui.sh check

site: ## Build the hobo.gsquared.app site into site/dist
	cd site && npm ci && npm run build

site-preview: ## Serve the site with live reload from docs/, and open it in the browser
	cd site && npm ci && npm run dev -- --open

# The test runner can't hold the entitlement, so VM tests drive the signed binary. A host-wide
# lock queues runs from different worktrees: only 2 macOS guests fit on a host.
INTEGRATION_LOCK := $(or $(HOBO_HOME),$(HOME)/.hobo)/integration.lock
# The kept VMs the guest tests clone, built from Tests/HoboVMTests/recipes by test-vms. Set one
# empty to leave that guest out; a missing one fails its tests.
HOBO_MACOS_VM ?= macos27
HOBO_LINUX_VM ?= ubuntu26
HOBO_WINDOWS_VM ?= windows11
KEPT_VMS = HOBO_MACOS_VM=$(HOBO_MACOS_VM) HOBO_LINUX_VM=$(HOBO_LINUX_VM) HOBO_WINDOWS_VM=$(HOBO_WINDOWS_VM)
integration-test: sign ## Tests that drive the signed binary
	@mkdir -p $(dir $(INTEGRATION_LOCK))
	$(KEPT_VMS) HOBO_INTEGRATION=1 HOBO_BIN=$(abspath $(BIN)) lockf $(INTEGRATION_LOCK) swift test --filter HoboVMTests

test-vms: sign ## Build the kept VMs the guest tests clone, any that are missing (Windows needs HOBO_WINDOWS_ISO)
	$(KEPT_VMS) HOBO_BIN=$(abspath $(BIN)) scripts/test-vms.sh

clean: ## Remove build products
	swift package clean
