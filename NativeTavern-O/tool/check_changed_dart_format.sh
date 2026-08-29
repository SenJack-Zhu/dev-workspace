#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

base_ref=${MOBILE_RELEASE_BASE_REF:-origin/main}
if git rev-parse --verify --quiet "$base_ref" >/dev/null; then
  comparison_base=$(git merge-base HEAD "$base_ref")
else
  comparison_base=HEAD
fi

changed_files=$(
  {
    git diff --name-only --diff-filter=ACMRT "$comparison_base" -- '*.dart'
    git ls-files --others --exclude-standard -- '*.dart'
  } | sort -u
)

if [ -z "$changed_files" ]; then
  echo "No changed Dart files to format-check."
  exit 0
fi

# Repository Dart paths do not contain whitespace.
# shellcheck disable=SC2086
dart format --output=none --set-exit-if-changed $changed_files
