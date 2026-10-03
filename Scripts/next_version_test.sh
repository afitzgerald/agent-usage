#!/usr/bin/env bash
# Regression test for next_version.sh's bump rules. Run directly:
#   ./Scripts/next_version_test.sh
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/next_version.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git config user.email test@test.com
git config user.name test

fail=0
check() {
  local what="$1" want="$2" got
  got="$("$script")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $what -> got '$got', want '$want'"
    fail=1
  else
    echo "ok: $what -> $got"
  fi
}

git commit -q --allow-empty -m "First commit, no tags yet"
check "untagged repo" "v0.0.1"

git tag v0.5.0
check "HEAD already tagged" ""

git tag v0.9.0-rc1
git commit -q --allow-empty -m "Rename quota percent"
check "plain subject, rc tag ignored" "v0.5.1"
git tag v0.5.1

git commit -q --allow-empty -m "feat: add widget"
check "feat: is still a patch" "v0.5.2"

git commit -q --allow-empty -m "feat(cli)!: drop old flag"
check "type!: subject" "v1.0.0"

git reset -q --hard v0.5.1
git commit -q --allow-empty -m "Change schema" -m "BREAKING CHANGE: percent renamed"
check "BREAKING CHANGE footer" "v1.0.0"

exit "$fail"
