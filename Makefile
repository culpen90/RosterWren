PROJECT := RosterWren.xcodeproj
SCHEME := RosterWren
DERIVED_DATA := .build/DerivedData

.PHONY: generate build test app open clean

generate:
	xcodegen generate --spec project.yml

build: generate
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

test: generate
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO test

app: generate
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" ENABLE_CODE_COVERAGE=NO CODE_SIGNING_ALLOWED=NO build
	mkdir -p dist
	rm -rf "dist/RosterWren.app"
	rm -f "dist/RosterWren.dmg"
	staging_dir="$$(mktemp -d /tmp/RosterWren-build.XXXXXX)"; \
	trap 'rm -rf "$$staging_dir"' EXIT; \
	mkdir -p "$$staging_dir/image"; \
	ditto "$(DERIVED_DATA)/Build/Products/Release/RosterWren.app" "$$staging_dir/image/RosterWren.app"; \
	ln -s /Applications "$$staging_dir/image/Applications"; \
	xattr -cr "$$staging_dir/image/RosterWren.app"; \
	xattr -d com.apple.FinderInfo "$$staging_dir/image/RosterWren.app" 2>/dev/null || true; \
	codesign --force --deep --options runtime --timestamp=none --sign - "$$staging_dir/image/RosterWren.app"; \
	xattr -d com.apple.FinderInfo "$$staging_dir/image/RosterWren.app" 2>/dev/null || true; \
	codesign --verify --deep --strict --verbose=2 "$$staging_dir/image/RosterWren.app"; \
	hdiutil create -quiet -ov -format UDZO -volname RosterWren -srcfolder "$$staging_dir/image" "dist/RosterWren.dmg"

open: app
	open "dist/RosterWren.dmg"

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)" clean
