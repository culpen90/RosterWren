#!/usr/bin/env bash

set -euo pipefail

version="${1:-}"
build_number="${2:-${GITHUB_RUN_NUMBER:-1}}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Usage: $0 <major.minor.patch> [positive-build-number]" >&2
  exit 64
fi

if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 64
fi

for required_tool in codesign ditto hdiutil lipo plutil security shasum spctl unzip xattr xcodebuild xcodegen xcrun; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Required release tool is unavailable: $required_tool" >&2
    exit 69
  fi
done

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
derived_data="$repository_root/.build/ReleaseDerivedData"
dist_directory="$repository_root/dist"
products_directory="$derived_data/Build/Products/Release"
source_app="$products_directory/RosterWren.app"
source_dsym="$products_directory/RosterWren.app.dSYM"
artifact_prefix="RosterWren-$version"
dmg_path="$dist_directory/$artifact_prefix-macOS-universal.dmg"
app_zip_path="$dist_directory/$artifact_prefix-macOS-universal.zip"
dsym_zip_path="$dist_directory/$artifact_prefix-dSYMs.zip"
checksums_path="$dist_directory/$artifact_prefix-SHA256SUMS.txt"

release_signing_identity="${MACOS_SIGNING_IDENTITY:-}"
development_signing_identity="${MACOS_DEVELOPMENT_SIGNING_IDENTITY:-}"
requested_signing_mode="${ROSTERWREN_SIGNING_MODE:-}"
api_key_file="${APPLE_API_KEY_FILE:-}"
api_key_id="${APPLE_API_KEY_ID:-}"
api_issuer_id="${APPLE_API_ISSUER_ID:-}"
notary_value_count=0
for value in "$api_key_file" "$api_key_id" "$api_issuer_id"; do
  if [[ -n "$value" ]]; then
    notary_value_count=$((notary_value_count + 1))
  fi
done

if [[ "$notary_value_count" -ne 0 && "$notary_value_count" -ne 3 ]]; then
  echo "Apple notarization configuration is incomplete." >&2
  exit 78
fi

if [[ -n "$release_signing_identity" && -n "$development_signing_identity" ]]; then
  echo "Set either MACOS_SIGNING_IDENTITY or MACOS_DEVELOPMENT_SIGNING_IDENTITY, not both." >&2
  exit 78
fi

case "$requested_signing_mode" in
  ""|developer-id|adhoc) ;;
  *)
    echo "ROSTERWREN_SIGNING_MODE must be developer-id, adhoc, or unset." >&2
    exit 78
    ;;
esac

if [[ "$requested_signing_mode" == adhoc \
  && ( -n "$release_signing_identity" || -n "$development_signing_identity" ) ]]; then
  echo "Ad-hoc signing cannot be combined with a signing identity." >&2
  exit 78
fi

if [[ "$requested_signing_mode" == developer-id \
  && -n "$development_signing_identity" ]]; then
  echo "Developer ID mode cannot use MACOS_DEVELOPMENT_SIGNING_IDENTITY." >&2
  exit 78
fi

signing_mode=adhoc
signing_identity=""
if [[ -n "$release_signing_identity" ]]; then
  signing_mode=developer-id
  signing_identity="$release_signing_identity"
elif [[ -n "$development_signing_identity" ]]; then
  signing_mode=development
  signing_identity="$development_signing_identity"
elif [[ "$requested_signing_mode" == developer-id ]]; then
  echo "Developer ID mode requires MACOS_SIGNING_IDENTITY." >&2
  exit 78
elif [[ "$requested_signing_mode" != adhoc \
  && "${CI:-}" != true \
  && "${GITHUB_ACTIONS:-}" != true ]]; then
  # TCC privacy grants, including Accessibility, are associated with the app's
  # designated requirement. Prefer a locally installed Apple Development
  # identity so rebuilding the same app does not create a new ad-hoc identity.
  development_signing_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/"Apple Development:/ { print $2; exit }'
  )"
  if [[ -n "$development_signing_identity" ]]; then
    signing_mode=development
    signing_identity="$development_signing_identity"
  fi
fi

if [[ "$signing_mode" == developer-id && "$notary_value_count" -ne 3 ]]; then
  echo "Developer ID releases require complete notarization credentials." >&2
  exit 78
fi

if [[ "$signing_mode" != developer-id && "$notary_value_count" -ne 0 ]]; then
  echo "Notarization credentials require a Developer ID signing identity." >&2
  exit 78
fi

mkdir -p "$dist_directory"
rm -f "$dmg_path" "$app_zip_path" "$dsym_zip_path" "$checksums_path"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/RosterWren-release.XXXXXX")"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

working_app="$temporary_directory/RosterWren.app"
image_directory="$temporary_directory/image"

cd "$repository_root"
xcodegen generate --spec project.yml
xcodebuild -quiet \
  -project RosterWren.xcodeproj \
  -scheme RosterWren \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  clean build

if [[ ! -d "$source_app" || ! -d "$source_dsym" ]]; then
  echo "Release build did not produce the app and dSYM bundle." >&2
  exit 70
fi

ditto "$source_app" "$working_app"
xattr -cr "$working_app"
xattr -d com.apple.FinderInfo "$working_app" 2>/dev/null || true

if [[ "$signing_mode" == developer-id ]]; then
  echo "Signing with Developer ID identity: $signing_identity"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$working_app"
elif [[ "$signing_mode" == development ]]; then
  echo "Signing local package with Apple Development identity: $signing_identity"
  codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$signing_identity" \
    "$working_app"
else
  echo "No stable signing identity is available; using an ad-hoc development signature."
  echo "Accessibility permission may need to be removed and granted again after every rebuild." >&2
  codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign - \
    "$working_app"
fi

codesign --verify --deep --strict --verbose=2 "$working_app"

built_version="$(plutil -extract CFBundleShortVersionString raw "$working_app/Contents/Info.plist")"
built_number="$(plutil -extract CFBundleVersion raw "$working_app/Contents/Info.plist")"
if [[ "$built_version" != "$version" || "$built_number" != "$build_number" ]]; then
  echo "Built app version does not match the requested release version." >&2
  exit 70
fi

architectures="$(lipo -archs "$working_app/Contents/MacOS/RosterWren")"
for required_architecture in arm64 x86_64; do
  if [[ " $architectures " != *" $required_architecture "* ]]; then
    echo "Built app is missing architecture: $required_architecture" >&2
    exit 70
  fi
done

if [[ "$signing_mode" == developer-id ]]; then
  notarization_zip="$temporary_directory/RosterWren-notarization.zip"
  ditto -c -k --sequesterRsrc --keepParent "$working_app" "$notarization_zip"
  xcrun notarytool submit "$notarization_zip" \
    --key "$api_key_file" \
    --key-id "$api_key_id" \
    --issuer "$api_issuer_id" \
    --wait
  xcrun stapler staple "$working_app"
  xcrun stapler validate "$working_app"
  spctl --assess --type execute --verbose=2 "$working_app"
fi

ditto -c -k --sequesterRsrc --keepParent "$working_app" "$app_zip_path"
ditto -c -k --sequesterRsrc --keepParent "$source_dsym" "$dsym_zip_path"

mkdir -p "$image_directory"
ditto "$working_app" "$image_directory/RosterWren.app"
ln -s /Applications "$image_directory/Applications"
hdiutil create \
  -quiet \
  -ov \
  -format UDZO \
  -volname "RosterWren $version" \
  -srcfolder "$image_directory" \
  "$dmg_path"

if [[ "$signing_mode" == developer-id ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
elif [[ "$signing_mode" == development ]]; then
  codesign --force --timestamp=none --sign "$signing_identity" "$dmg_path"
else
  codesign --force --timestamp=none --sign - "$dmg_path"
fi
codesign --verify --verbose=2 "$dmg_path"

if [[ "$signing_mode" == developer-id ]]; then
  xcrun notarytool submit "$dmg_path" \
    --key "$api_key_file" \
    --key-id "$api_key_id" \
    --issuer "$api_issuer_id" \
    --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$dmg_path"
fi

hdiutil verify -quiet "$dmg_path"
unzip -tq "$app_zip_path"
unzip -tq "$dsym_zip_path"

(
  cd "$dist_directory"
  shasum -a 256 \
    "$(basename "$dmg_path")" \
    "$(basename "$app_zip_path")" \
    "$(basename "$dsym_zip_path")" \
    > "$(basename "$checksums_path")"
)

echo "Packaged RosterWren $version (build $build_number; $architectures):"
printf '  %s\n' "$dmg_path" "$app_zip_path" "$dsym_zip_path" "$checksums_path"
