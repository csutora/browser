.PHONY: build release clean

SHELL := /bin/bash

PBXPROJ := Dawn.xcodeproj/project.pbxproj
CURRENT_VERSION := $(shell /usr/bin/sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' $(PBXPROJ) | head -1)
TEAM := $(shell /usr/bin/sed -n 's/.*DEVELOPMENT_TEAM = \(.*\);/\1/p' $(PBXPROJ) | head -1)

DERIVED := build/release
APP := dist/Dawn.app

# signed by the project's team like any xcode build, but without the debugger entitlement xcode
# adds to development signatures, and with the hardened runtime notarization will need
build:
	rm -rf dist $(DERIVED)
	xcodebuild -project Dawn.xcodeproj -scheme Dawn -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
		build
	mkdir -p dist
	ditto $(DERIVED)/Build/Products/Release/Dawn.app $(APP)
	codesign --verify --strict --deep $(APP)
	@codesign -dv $(APP) 2>&1 | grep -qx "TeamIdentifier=$(TEAM)" || { \
		echo "error: $(APP) is not signed by team $(TEAM)"; exit 1; }
	@echo "built $(APP) ($$(/usr/bin/plutil -extract CFBundleShortVersionString raw $(APP)/Contents/Info.plist))"

release:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: uncommitted changes, the release wouldn't match any commit"; exit 1; \
	fi
	@printf "current version: $(CURRENT_VERSION)\nnew version: "; \
	read VERSION; \
	if ! [[ "$$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$$ ]]; then \
		echo "error: expected a version like 1.2.0"; exit 1; \
	fi; \
	if git rev-parse -q --verify "refs/tags/v$$VERSION" > /dev/null || gh release view "v$$VERSION" > /dev/null 2>&1; then \
		echo "error: v$$VERSION already exists"; exit 1; \
	fi; \
	/usr/bin/sed -i '' \
		-e "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $$VERSION;/" \
		-e "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $$VERSION;/" \
		$(PBXPROJ); \
	$(MAKE) build || exit 1; \
	ZIP="dist/Dawn-$$VERSION.zip"; \
	ditto -c -k --keepParent $(APP) "$$ZIP"; \
	echo "built $$ZIP"; \
	echo "next: commit the version bump, push, then"; \
	echo "  gh release create v$$VERSION $$ZIP --title v$$VERSION --generate-notes"

clean:
	rm -rf dist $(DERIVED)
