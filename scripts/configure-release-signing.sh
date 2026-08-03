#!/usr/bin/env bash

set -euo pipefail

certificate_base64="${MACOS_CERTIFICATE_P12_BASE64:-}"
certificate_password="${MACOS_CERTIFICATE_PASSWORD:-}"
signing_identity="${MACOS_SIGNING_IDENTITY:-}"
api_key_base64="${APPLE_API_KEY_P8_BASE64:-}"
api_key_id="${APPLE_API_KEY_ID:-}"
api_issuer_id="${APPLE_API_ISSUER_ID:-}"
allow_adhoc_releases="${ALLOW_ADHOC_RELEASES:-false}"

if [[ "$allow_adhoc_releases" != true && "$allow_adhoc_releases" != false && -n "$allow_adhoc_releases" ]]; then
  echo "ALLOW_ADHOC_RELEASES must be true, false, or unset." >&2
  exit 64
fi

configured_value_count=0
for value in \
  "$certificate_base64" \
  "$certificate_password" \
  "$signing_identity" \
  "$api_key_base64" \
  "$api_key_id" \
  "$api_issuer_id"; do
  if [[ -n "$value" ]]; then
    configured_value_count=$((configured_value_count + 1))
  fi
done

if [[ "$configured_value_count" -eq 0 ]]; then
  if [[ "$allow_adhoc_releases" == true ]]; then
    echo "ROSTERWREN_SIGNING_MODE=adhoc" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
    echo "Ad-hoc release publication was explicitly enabled by repository policy."
    exit 0
  fi
  echo "Release signing secrets are absent. Configure them before publishing, or explicitly set ALLOW_ADHOC_RELEASES=true for development-only releases." >&2
  exit 78
fi

if [[ "$configured_value_count" -ne 6 ]]; then
  echo "Release signing configuration is incomplete. Configure all six documented secrets or none of them." >&2
  exit 78
fi

if [[ "$signing_identity" == *$'\n'* || "$api_key_id" == *$'\n'* || "$api_issuer_id" == *$'\n'* ]]; then
  echo "Release signing identifiers must be single-line values." >&2
  exit 78
fi
if [[ ! "$api_key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "APPLE_API_KEY_ID must be a 10-character uppercase alphanumeric key ID." >&2
  exit 78
fi
if [[ ! "$api_issuer_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "APPLE_API_ISSUER_ID must be a UUID." >&2
  exit 78
fi

runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"
github_environment="${GITHUB_ENV:?GITHUB_ENV is required}"
keychain_path="$runner_temp/rosterwren-signing.keychain-db"
certificate_path="$runner_temp/rosterwren-signing.p12"
api_key_path="$runner_temp/AuthKey_${api_key_id}.p8"
keychain_password="$(openssl rand -hex 32)"
configuration_succeeded=false
umask 077

cleanup_failed_configuration() {
  if [[ "$configuration_succeeded" != true ]]; then
    rm -f "$certificate_path" "$api_key_path"
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
}
trap cleanup_failed_configuration EXIT

printf '%s' "$certificate_base64" | /usr/bin/base64 -D > "$certificate_path"
printf '%s' "$api_key_base64" | /usr/bin/base64 -D > "$api_key_path"
chmod 600 "$certificate_path" "$api_key_path"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$certificate_password" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"

existing_keychains=()
while IFS= read -r existing_keychain; do
  existing_keychain="$(printf '%s' "$existing_keychain" \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  if [[ -n "$existing_keychain" ]]; then
    existing_keychains+=("$existing_keychain")
  fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain_path" "${existing_keychains[@]}"

if ! security find-identity -v -p codesigning "$keychain_path" \
  | grep -F "\"$signing_identity\"" >/dev/null; then
  echo "The imported certificate does not provide the configured signing identity." >&2
  exit 78
fi

rm -f "$certificate_path"
{
  echo "ROSTERWREN_SIGNING_MODE=developer-id"
  echo "ROSTERWREN_KEYCHAIN_PATH=$keychain_path"
  echo "MACOS_SIGNING_IDENTITY=$signing_identity"
  echo "APPLE_API_KEY_FILE=$api_key_path"
  echo "APPLE_API_KEY_ID=$api_key_id"
  echo "APPLE_API_ISSUER_ID=$api_issuer_id"
} >> "$github_environment"

configuration_succeeded=true
echo "Developer ID signing and Apple notarization are configured."
