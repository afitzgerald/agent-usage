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

.PHONY: build selftest install uninstall run clean

build:
	swift build -c release

# precondition, not assert, so this checks the real -O build.
selftest: build
	$(BIN) --selftest

# Unloaded before the copy: overwriting the binary under a running job can get
# it killed mid-write for an invalid code signature.
install: build
	$(BIN) --selftest
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	mkdir -p $(PREFIX)/bin $(dir $(PLIST)) $(dir $(LOG))
	cp $(BIN) $(INSTALLED)
	codesign --force --sign "$(IDENTITY)" --identifier $(LABEL) $(INSTALLED)
	sed -e 's|@BIN@|$(INSTALLED)|' -e 's|@LOG@|$(LOG)|' Resources/$(LABEL).plist > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "installed; first run writes $(HOME)/Library/Application Support/AgentUsage/usage.json"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(INSTALLED)

# Runs the installed job now instead of waiting for the next interval.
run:
	launchctl kickstart $(DOMAIN)/$(LABEL)

clean:
	rm -rf .build
