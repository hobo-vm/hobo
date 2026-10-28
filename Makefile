PREFIX ?= $(HOME)/.local
HOBO_SIGN_IDENTITY ?= -
BIN := .build/release/hobo

.PHONY: build sign install test integration-test clean

build:
	swift build -c release

sign: build
	codesign --force --sign "$(HOBO_SIGN_IDENTITY)" --entitlements entitlements.plist --options runtime $(BIN)

install: sign
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/hobo

test:
	swift test

integration-test:
	HOBO_INTEGRATION=1 swift test

clean:
	swift package clean
