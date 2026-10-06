# Device signing: DEVELOPMENT_TEAM + APP_BUNDLE_ID in Config/Local.xcconfig (copy the .example).
# DEVICE_UDID defaults to the first connected iPhone.
SCHEME  := SecureVNC
DERIVED := build/install
APP     := SecureVNC.app
APP_ID  := $(shell sed -n 's/^APP_BUNDLE_ID *= *//p' Config/Local.xcconfig)
DEVICE_UDID ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ {print $$3; exit}')

.PHONY: help project device check test test-live icon

help:
	@echo "make device     Release build, install and launch on the connected iPhone"
	@echo "make check      generate the project and build Release for a generic iPhone"
	@echo "make test       library unit tests (macOS)"
	@echo "make test-live  + temp sshd on 127.0.0.1:2222 tunnelling to this Mac's Screen Sharing"
	@echo "make icon       regenerate the app icon PNGs (light, dark, tinted)"

project:
	xcodegen generate

device: project
	@test -n "$(DEVICE_UDID)" || { echo "No iPhone connected; set DEVICE_UDID (xcrun devicectl list devices)"; exit 1; }
	xcodebuild -scheme $(SCHEME) -configuration Release -destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE_UDID) $(DERIVED)/Build/Products/Release-iphoneos/$(APP)
	xcrun devicectl device process launch --device $(DEVICE_UDID) --terminate-existing $(APP_ID)

check: project
	xcodebuild -scheme $(SCHEME) -configuration Release -destination 'generic/platform=iOS' \
		-derivedDataPath build/check -allowProvisioningUpdates -quiet build
	@echo "Release build OK"

test:
	cd SecureVNCKit && swift test --skip TunnelIntegrationTests

test-live:
	cd SecureVNCKit && SECUREVNC_LIVE=1 swift test

icon:
	swiftc -O scripts/make-icon.swift -o /tmp/make-icon
	for v in light dark tinted; do /tmp/make-icon SecureVNC/Assets.xcassets/AppIcon.appiconset/icon-$$v.png $$v; done
