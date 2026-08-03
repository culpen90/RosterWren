#!/usr/bin/env bash

set -euo pipefail

initial_version="${INITIAL_RELEASE_VERSION:-0.1.0}"
if [[ ! "$initial_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "INITIAL_RELEASE_VERSION must be a stable semantic version." >&2
  exit 64
fi

for required_tool in gh git grep shasum; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Required release reconciliation tool is unavailable: $required_tool" >&2
    exit 69
  fi
done

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/RosterWren-reconcile.XXXXXX")"
release_worktree=""

remove_release_worktree() {
  if [[ -n "$release_worktree" ]]; then
    git -C "$repository_root" worktree remove --force "$release_worktree" \
      >/dev/null 2>&1 || true
    release_worktree=""
  fi
}

cleanup() {
  remove_release_worktree
  rm -rf "$temporary_directory"
  git -C "$repository_root" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

repository_name="${GITHUB_REPOSITORY:-}"
if [[ -z "$repository_name" ]]; then
  repository_name="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi
repository_arguments=(--repo "$repository_name")
distribution_marker_start="<!-- rosterwren-distribution-start -->"
distribution_marker_end="<!-- rosterwren-distribution-end -->"

if [[ "${ROSTERWREN_SIGNING_MODE:-}" != "developer-id" \
  && "${ROSTERWREN_SIGNING_MODE:-}" != "adhoc" ]]; then
  echo "ROSTERWREN_SIGNING_MODE must be developer-id or adhoc before reconciliation." >&2
  exit 78
fi

distribution_notice() {
  if [[ "${ROSTERWREN_SIGNING_MODE:-}" == "adhoc" ]]; then
    printf '%s\n' \
      "> [!WARNING]" \
      "> This release uses an ad-hoc development signature and is not Apple-notarized."
  else
    echo "The downloadable app is Developer ID signed and Apple-notarized."
  fi
}

release_notes_for_version() {
  local version="$1"
  local artifact_prefix="RosterWren-$version"

  printf '%s\n\n%s\n\n%s\n' \
    "Download **\`$artifact_prefix-macOS-universal.dmg\`** and drag RosterWren to Applications." \
    "Use **\`$artifact_prefix-SHA256SUMS.txt\`** to verify every downloadable binary artifact." \
    "$distribution_marker_start"
  distribution_notice
  echo "$distribution_marker_end"
}

refresh_draft_distribution_notice() {
  local tag="$1"
  local notes_input="$temporary_directory/${tag#v}-notes-input.md"
  local notes_output="$temporary_directory/${tag#v}-notes-output.md"
  local notice_file="$temporary_directory/${tag#v}-distribution-notice.md"
  local start_count
  local end_count

  gh release view "$tag" \
    "${repository_arguments[@]}" \
    --json body \
    --jq '.body' > "$notes_input"
  start_count="$(grep -Fxc "$distribution_marker_start" "$notes_input" || true)"
  end_count="$(grep -Fxc "$distribution_marker_end" "$notes_input" || true)"
  if [[ "$start_count" != 1 || "$end_count" != 1 ]]; then
    echo "$tag draft does not contain the managed distribution notice markers." >&2
    exit 65
  fi

  distribution_notice > "$notice_file"
  awk \
    -v start="$distribution_marker_start" \
    -v finish="$distribution_marker_end" \
    -v notice_file="$notice_file" \
    '
      $0 == start {
        print
        while ((getline notice_line < notice_file) > 0) {
          print notice_line
        }
        close(notice_file)
        replacing = 1
        next
      }
      $0 == finish {
        replacing = 0
        print
        next
      }
      !replacing { print }
    ' \
    "$notes_input" > "$notes_output"
  gh release edit "$tag" \
    --notes-file "$notes_output" \
    "${repository_arguments[@]}"
}

expected_asset_names_for_version() {
  local version="$1"
  printf '%s\n' \
    "RosterWren-$version-macOS-universal.dmg" \
    "RosterWren-$version-macOS-universal.zip" \
    "RosterWren-$version-dSYMs.zip" \
    "RosterWren-$version-SHA256SUMS.txt"
}

inspect_release() {
  local tag="$1"
  local asset_listing="$2"
  release_exists=false
  release_is_draft=false
  release_is_immutable=false
  release_assets_complete=false

  if gh release view "$tag" "${repository_arguments[@]}" \
    --json assets,isDraft \
    --jq '.assets[].name' > "$asset_listing" 2>/dev/null; then
    release_exists=true
    release_is_draft="$(gh release view "$tag" \
      "${repository_arguments[@]}" \
      --json isDraft \
      --jq '.isDraft')"
    if [[ "$release_is_draft" == false ]]; then
      release_is_immutable="$(gh release view "$tag" \
        "${repository_arguments[@]}" \
        --json isImmutable \
        --jq '.isImmutable')"
    fi
    release_assets_complete=true
    while IFS= read -r expected_asset_name; do
      if ! grep -Fx "$expected_asset_name" "$asset_listing" >/dev/null; then
        release_assets_complete=false
        break
      fi
    done < <(expected_asset_names_for_version "${tag#v}")
  fi
}

package_tagged_commit() {
  local tag="$1"
  local version="${tag#v}"
  local tag_commit="$2"

  remove_release_worktree
  release_worktree="$temporary_directory/source-$version"
  git -C "$repository_root" worktree add \
    --detach \
    "$release_worktree" \
    "$tag_commit" \
    >/dev/null

  if [[ ! -x "$release_worktree/scripts/package-release.sh" ]]; then
    echo "$tag does not contain the release packaging script; refusing to build it from another commit." >&2
    exit 65
  fi

  (
    cd "$release_worktree"
    ./scripts/package-release.sh "$version"
  )
  packaged_artifact_directory="$release_worktree/dist"
}

publish_or_repair_draft() {
  local tag="$1"
  local version="${tag#v}"
  local expected_commit="$2"
  local artifact_directory="$3"
  local tag_already_exists="$4"
  local asset_arguments=()

  while IFS= read -r expected_asset_name; do
    local asset_path="$artifact_directory/$expected_asset_name"
    if [[ ! -f "$asset_path" ]]; then
      echo "Release asset is missing: $asset_path" >&2
      exit 70
    fi
    asset_arguments+=("$asset_path")
  done < <(expected_asset_names_for_version "$version")

  if [[ "$release_exists" == true ]]; then
    if [[ "$release_is_draft" != true ]]; then
      echo "$tag is already public but incomplete; refusing to mutate published release assets." >&2
      exit 65
    fi
    refresh_draft_distribution_notice "$tag"
    gh release upload "$tag" \
      "${asset_arguments[@]}" \
      --clobber \
      "${repository_arguments[@]}"
  elif [[ "$tag_already_exists" == true ]]; then
    gh release create "$tag" \
      "${asset_arguments[@]}" \
      --draft \
      --verify-tag \
      --title "RosterWren $version" \
      --notes "$(release_notes_for_version "$version")" \
      --generate-notes \
      "${repository_arguments[@]}"
  else
    gh release create "$tag" \
      "${asset_arguments[@]}" \
      --draft \
      --target "$expected_commit" \
      --title "RosterWren $version" \
      --notes "$(release_notes_for_version "$version")" \
      --generate-notes \
      "${repository_arguments[@]}"
  fi

  "$repository_root/scripts/publish-release-draft.sh" \
    "$tag" \
    "$artifact_directory" \
    "$expected_commit"
}

cd "$repository_root"
git fetch --tags --force origin

stable_tags=()
while IFS= read -r candidate_tag; do
  if [[ ! "$candidate_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Unexpected v-prefixed tag prevents automatic release reconciliation: $candidate_tag" >&2
    exit 65
  fi

  candidate_commit="$(git rev-parse "$candidate_tag^{commit}")"
  if ! git merge-base --is-ancestor "$candidate_commit" HEAD; then
    echo "Release tag is not reachable from the checked-out main branch: $candidate_tag" >&2
    exit 65
  fi
  stable_tags+=("$candidate_tag")
done < <(git tag --list 'v*' --sort=version:refname)

if [[ "${#stable_tags[@]}" -eq 0 ]]; then
  initial_tag="v$initial_version"
  initial_asset_listing="$temporary_directory/$initial_version-assets.txt"
  inspect_release "$initial_tag" "$initial_asset_listing"

  if [[ "$release_exists" == true ]]; then
    if [[ "$release_is_draft" != true ]]; then
      echo "$initial_tag has a public release but no reachable Git tag; manual recovery is required." >&2
      exit 65
    fi

    initial_target="$(gh release view "$initial_tag" \
      "${repository_arguments[@]}" \
      --json targetCommitish \
      --jq '.targetCommitish')"
    if [[ ! "$initial_target" =~ ^[0-9a-f]{40}$ ]]; then
      echo "$initial_tag draft must target the exact immutable source commit." >&2
      exit 65
    fi
    initial_commit="$(git rev-parse "$initial_target^{commit}")"
    if [[ "$initial_target" != "$initial_commit" ]] \
      || ! git merge-base --is-ancestor "$initial_commit" HEAD; then
      echo "$initial_tag draft target is not a reachable exact commit on the checked-out main branch." >&2
      exit 65
    fi

    package_tagged_commit "$initial_tag" "$initial_commit"
    initial_artifact_directory="$packaged_artifact_directory"
  else
    initial_commit="${GITHUB_SHA:-$(git rev-parse HEAD)}"
    if [[ "$(git rev-parse HEAD)" != "$initial_commit" ]]; then
      echo "The initial release must run from the checked-out GITHUB_SHA." >&2
      exit 65
    fi

    ./scripts/package-release.sh "$initial_version"
    initial_artifact_directory="$repository_root/dist"
  fi

  publish_or_repair_draft \
    "$initial_tag" \
    "$initial_commit" \
    "$initial_artifact_directory" \
    false
  echo "Published the initial $initial_tag release with verified assets."
  exit 0
fi

for stable_tag in "${stable_tags[@]}"; do
  asset_listing="$temporary_directory/${stable_tag#v}-assets.txt"
  inspect_release "$stable_tag" "$asset_listing"
  if [[ "$release_exists" == true \
    && "$release_is_draft" == false \
    && "$release_is_immutable" == true \
    && "$release_assets_complete" == true ]]; then
    continue
  fi

  if [[ "$release_exists" == true \
    && "$release_is_draft" == false \
    && "$release_is_immutable" != true ]]; then
    echo "$stable_tag is public but mutable; immutable releases must remain enabled." >&2
    exit 65
  fi

  if [[ "$release_exists" == true && "$release_is_draft" == false ]]; then
    echo "$stable_tag is public but incomplete; manual recovery is required to preserve immutable assets." >&2
    exit 65
  fi

  stable_commit="$(git rev-parse "$stable_tag^{commit}")"
  package_tagged_commit "$stable_tag" "$stable_commit"
  publish_or_repair_draft \
    "$stable_tag" \
    "$stable_commit" \
    "$packaged_artifact_directory" \
    true
  echo "Repaired and published $stable_tag from its exact tagged commit."
done

echo "Every existing semantic release is complete."
