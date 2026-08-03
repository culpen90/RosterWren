PROJECT := RosterWren.xcodeproj
SCHEME := RosterWren
DERIVED_DATA := .build/DerivedData
VERSION ?= $(shell ./scripts/current-version.sh)
BUILD_NUMBER ?= 1

.PHONY: generate build test app open clean

generate:
	xcodegen generate --spec project.yml

build: generate
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

test: generate
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO test

app:
	./scripts/package-release.sh "$(VERSION)" "$(BUILD_NUMBER)"

open: app
	open "dist/RosterWren-$(VERSION)-macOS-universal.dmg"

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)" clean
