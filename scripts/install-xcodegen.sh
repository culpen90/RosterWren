#!/usr/bin/env bash

set -euo pipefail

xcodegen_version="2.45.4"
xcodegen_sha256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
xcodegen_url="https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip"

if command -v xcodegen >/dev/null 2>&1 \
  && xcodegen --version | grep -Fx "Version: $xcodegen_version" >/dev/null; then
  xcodegen --version
  exit 0
fi

install_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/RosterWren-XcodeGen-$xcodegen_version"
archive_path="$install_root/xcodegen.zip"
binary_directory="$install_root/xcodegen/bin"
binary_path="$binary_directory/xcodegen"

mkdir -p "$install_root"
curl -fsSL --retry 3 "$xcodegen_url" -o "$archive_path"
printf '%s  %s\n' "$xcodegen_sha256" "$archive_path" | shasum -a 256 -c -
unzip -q -o "$archive_path" -d "$install_root"
rm -f "$archive_path"

if [[ ! -x "$binary_path" ]] \
  || ! "$binary_path" --version | grep -Fx "Version: $xcodegen_version" >/dev/null; then
  echo "Pinned XcodeGen installation failed validation." >&2
  exit 70
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$binary_directory" >> "$GITHUB_PATH"
fi

"$binary_path" --version
