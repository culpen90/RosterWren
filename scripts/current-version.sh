#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"

while IFS= read -r exact_tag; do
  if [[ "$exact_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf '%s\n' "${exact_tag#v}"
    exit 0
  fi
done < <(
  git -C "$repository_root" tag \
    --points-at HEAD \
    --list 'v*' \
    --sort=-version:refname
)

source_version="$(awk -F '"' \
  '/^[[:space:]]*MARKETING_VERSION: "[^"]+"$/ { print $2; exit }' \
  "$repository_root/project.yml")"
if [[ ! "$source_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "project.yml does not contain a valid MARKETING_VERSION." >&2
  exit 65
fi

printf '%s\n' "$source_version"
