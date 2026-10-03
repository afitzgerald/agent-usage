#!/usr/bin/env bash
# Computes the next release tag from commit messages since the last vX.Y.Z tag
# reachable from HEAD, and prints it (e.g. "v0.2.9") to stdout. Prints nothing
# if HEAD is already tagged, or if there are no commits since the last tag —
# either way, there's nothing new to release.
#
# Bump rules, checked against every commit since the last tag:
#   - "type!: ..." subject or a "BREAKING CHANGE:" footer -> major
#   - anything else                                       -> patch
#
# Same rules as moomux-mac's copy. Minor bumps are a manual call: tag and push
# vX.Y.0 yourself. Pure bash matching rather than grep, which keeps it free of
# whichever grep the runner happens to ship.
set -euo pipefail

if [ -n "$(git tag --points-at HEAD)" ]; then
  exit 0
fi

# Only exact vX.Y.Z tags reachable from HEAD count as a release baseline — a
# stray "v*" tag with a different shape (v1, v1.2.3-rc1) or one that lives on
# an unrelated branch must not be picked as the last release.
last_tag=""
while read -r t; do
  [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && last_tag="$t"
done < <(git tag -l --merged HEAD 'v*' | sort -V)

if [ -z "$last_tag" ]; then
  range=(HEAD)
  version="0.0.0"
else
  range=("${last_tag}..HEAD")
  version="${last_tag#v}"
fi

if [ -z "$(git log "${range[@]}" --pretty=%s)" ]; then
  exit 0
fi

bump="patch"
while read -r line; do
  if [[ "$line" =~ ^[a-zA-Z]+(\([^\)]+\))?!: || "$line" == "BREAKING CHANGE:"* ]]; then
    bump="major"
  fi
done < <(git log "${range[@]}" --pretty=%B)

IFS='.' read -r major minor patch <<<"$version"
case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac

echo "v${major}.${minor}.${patch}"
