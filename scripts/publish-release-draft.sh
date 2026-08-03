#!/usr/bin/env bash

set -euo pipefail

tag="${1:-}"
artifact_directory="${2:-dist}"
expected_commit="${3:-}"

if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Usage: $0 <vMAJOR.MINOR.PATCH> [artifact-directory] [expected-commit]" >&2
  exit 64
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN or GH_TOKEN is required}"
fi

for required_tool in awk gh git grep shasum; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Required draft publication tool is unavailable: $required_tool" >&2
    exit 69
  fi
done

version="${tag#v}"
artifact_directory="$(cd "$artifact_directory" && pwd)"
checksum_name="RosterWren-$version-SHA256SUMS.txt"
checksum_path="$artifact_directory/$checksum_name"
expected_asset_names=(
  "RosterWren-$version-macOS-universal.dmg"
  "RosterWren-$version-macOS-universal.zip"
  "RosterWren-$version-dSYMs.zip"
  "$checksum_name"
)

for asset_name in "${expected_asset_names[@]}"; do
  if [[ ! -f "$artifact_directory/$asset_name" ]]; then
    echo "Draft release asset is missing: $asset_name" >&2
    exit 70
  fi
done

(
  cd "$artifact_directory"
  shasum -a 256 -c "$checksum_name"
)

repository_name="${GITHUB_REPOSITORY:-}"
if [[ -z "$repository_name" ]]; then
  repository_name="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi

distribution_marker_start="<!-- rosterwren-distribution-start -->"
distribution_marker_end="<!-- rosterwren-distribution-end -->"
case "${ROSTERWREN_SIGNING_MODE:-}" in
  developer-id)
    distribution_notice="The downloadable app is Developer ID signed and Apple-notarized."
    ;;
  adhoc)
    distribution_notice=$'> [!WARNING]\n> This release uses an ad-hoc development signature and is not Apple-notarized.'
    ;;
  *)
    echo "ROSTERWREN_SIGNING_MODE must be developer-id or adhoc before publication." >&2
    exit 78
    ;;
esac
expected_distribution_block="$distribution_marker_start"$'\n'"$distribution_notice"$'\n'"$distribution_marker_end"
draft_body="$(gh release view "$tag" --repo "$repository_name" \
  --json body --jq '.body')"
if [[ "$draft_body" != *"$expected_distribution_block"* ]]; then
  echo "$tag draft does not describe the signing mode used for its artifacts." >&2
  exit 65
fi

if [[ "$(gh release view "$tag" --repo "$repository_name" \
  --json isDraft --jq '.isDraft')" != true ]]; then
  echo "$tag must remain a draft until its asset digests are verified." >&2
  exit 65
fi

remote_assets="$(
  gh release view "$tag" \
    --repo "$repository_name" \
    --json assets \
    --jq '.assets[] | [.name, .digest] | @tsv'
)"
remote_asset_count=0
while IFS=$'\t' read -r remote_asset_name remote_asset_digest; do
  if [[ -z "$remote_asset_name" ]]; then
    continue
  fi
  case "$remote_asset_name" in
    "${expected_asset_names[0]}" \
      | "${expected_asset_names[1]}" \
      | "${expected_asset_names[2]}" \
      | "${expected_asset_names[3]}")
      ;;
    *)
      echo "GitHub draft contains an unexpected release asset: $remote_asset_name" >&2
      exit 70
      ;;
  esac
  if [[ -z "$remote_asset_digest" ]]; then
    echo "GitHub has not calculated a digest for: $remote_asset_name" >&2
    exit 70
  fi
  remote_asset_count=$((remote_asset_count + 1))
done <<< "$remote_assets"
if [[ "$remote_asset_count" -ne "${#expected_asset_names[@]}" ]]; then
  echo "GitHub draft does not contain exactly the expected release assets." >&2
  exit 70
fi

for asset_name in "${expected_asset_names[@]}"; do
  local_digest="sha256:$(shasum -a 256 "$artifact_directory/$asset_name" | awk '{print $1}')"
  remote_digest="$(printf '%s\n' "$remote_assets" \
    | awk -F '\t' -v name="$asset_name" '$1 == name { print $2 }')"
  if [[ -z "$remote_digest" || "$remote_digest" != "$local_digest" ]]; then
    echo "GitHub asset digest does not match the final local file: $asset_name" >&2
    exit 70
  fi
done

local_tag_commit=""
if git rev-parse --verify --quiet "$tag^{commit}" >/dev/null; then
  local_tag_commit="$(git rev-parse "$tag^{commit}")"
fi
if [[ -n "$expected_commit" ]]; then
  expected_commit="$(git rev-parse "$expected_commit^{commit}")"
  if [[ -n "$local_tag_commit" && "$local_tag_commit" != "$expected_commit" ]]; then
    echo "$tag does not point to the commit used to build its artifacts." >&2
    exit 65
  fi
  if [[ -z "$local_tag_commit" ]]; then
    draft_target="$(gh release view "$tag" --repo "$repository_name" \
      --json targetCommitish --jq '.targetCommitish')"
    if [[ "$draft_target" != "$expected_commit" ]]; then
      echo "$tag draft does not target the commit used to build its artifacts." >&2
      exit 65
    fi
  fi
fi

gh release edit "$tag" --draft=false --repo "$repository_name"
git fetch --tags --force origin
published_tag_commit="$(git rev-parse "$tag^{commit}")"
if [[ -n "$expected_commit" && "$published_tag_commit" != "$expected_commit" ]]; then
  echo "Published tag target does not match the verified artifact source." >&2
  exit 65
fi
if [[ "$(gh release view "$tag" --repo "$repository_name" \
  --json isDraft --jq '.isDraft')" != false ]]; then
  echo "$tag is still a draft after publication." >&2
  exit 70
fi
if [[ "$(gh release view "$tag" --repo "$repository_name" \
  --json isImmutable --jq '.isImmutable')" != true ]]; then
  echo "$tag was published without GitHub's immutable-release protection." >&2
  exit 70
fi

echo "Published $tag after verifying every GitHub asset digest."
