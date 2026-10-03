PREFIX ?= $(HOME)/.local
LABEL := com.fitzgeraldweb.agent-usage
BIN := .build/release/agent-usage
INSTALLED := $(PREFIX)/bin/agent-usage
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG := $(HOME)/Library/Logs/agent-usage.log
DOMAIN := gui/$(shell id -u)
# Developer ID when that cert is installed, ad-hoc when it isn't. It matters
# more than it looks: the Keychain item holding the Claude credential trusts
# the binary that created it, and an ad-hoc signature changes on every build —
# so an ad-hoc reinstall costs one "allow access" dialog on its next run. A
# Developer ID signature with a fixed identifier survives rebuilds.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| rg -o -m1 'Developer ID Application: [^"]*')
IDENTITY := $(if $(IDENTITY),$(IDENTITY),-)

.PHONY: build selftest install uninstall run dist clean

build:
	swift build -c release

# precondition, not assert, so this checks the real -O build.
selftest: build
	$(BIN) --selftest

# Unloaded before the copy: overwriting the binary under a running job can get
# it killed mid-write for an invalid code signature.
install: build
	$(BIN) --selftest
	launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	mkdir -p $(PREFIX)/bin $(dir $(PLIST)) $(dir $(LOG))
	cp $(BIN) $(INSTALLED)
	codesign --force --sign "$(IDENTITY)" --identifier $(LABEL) $(INSTALLED)
	sed -e 's|@BIN@|$(INSTALLED)|' -e 's|@LOG@|$(LOG)|' Resources/$(LABEL).plist > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "installed; first run writes $(HOME)/Library/Application Support/AgentUsage/usage.json"

uninstall:
	launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(INSTALLED)

# Runs the installed job now instead of waiting for the next interval.
run:
	launchctl kickstart $(DOMAIN)/$(LABEL)

# The release artifact the Homebrew formula installs: a universal binary signed
# like `install` signs it, so the Keychain item trusts a brew copy and a make
# copy alike. Not notarized: brew downloads carry no quarantine flag and launchd
# never consults Gatekeeper. Runtime + timestamp anyway, so notarizing later is
# one notarytool call.
UNIVERSAL := --arch arm64 --arch x86_64
dist:
	@[ "$(IDENTITY)" != "-" ] || { echo "dist needs a Developer ID Application cert"; exit 1; }
	swift build -c release $(UNIVERSAL)
	rm -rf dist && mkdir dist
	cp "$$(swift build -c release $(UNIVERSAL) --show-bin-path)/agent-usage" dist/
	dist/agent-usage --selftest
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp --identifier $(LABEL) dist/agent-usage
	cd dist && zip -q agent-usage.zip agent-usage

clean:
	rm -rf .build dist
