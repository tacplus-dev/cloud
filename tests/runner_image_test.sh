#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the pools' image pin (#4): modules/settings pins runner_image's startup-script by the SHA-256 of
# modules/projects/ci/files/runner-startup.sh; ci/runner-image.sh NAME COMMIT, a bake's bump, pins the image by its
# name and writes looper's runner/startup.sh at COMMIT there, with its commit and SHA-256, and changes nothing else;
# it refuses a family, a name not runner-arm64-docker-<date>-<time>, a short commit, and a startup.sh it cannot
# fetch (leaving everything as it was). Needs bash, git and sha256sum; no network (the fetch is a file:// URL).
#
#   tests/runner_image_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
# pinned FILE KEY: the value of KEY in FILE's runner_image output.
pinned() { sed -n "/^output \"runner_image\"/,/^}/s/^    $2 *= *\\(.*\\)\$/\\1/p" "$1"; }

startup=$here/modules/projects/ci/files/runner-startup.sh
[ "$(pinned "$here/modules/settings/main.tf" startup_sha256)" = "\"$(sha256sum < "$startup" | cut -d' ' -f1)\"" ] &&
  ok "modules/settings pins files/runner-startup.sh by its SHA-256" || fail "files/runner-startup.sh is not the one modules/settings pins"
[[ $(pinned "$here/modules/settings/main.tf" looper_commit) =~ ^\"[0-9a-f]{40}\"$ ]] &&
  ok "modules/settings names the looper commit of the startup-script" || fail "looper_commit: $(pinned "$here/modules/settings/main.tf" looper_commit)"
image=$(pinned "$here/modules/settings/main.tf" image)
[[ $image == null || $image =~ ^\"runner-arm64-docker-[0-9]{8}-[0-9]{6}\"$ ]] &&
  ok "the pools' image is pinned by name, or not yet: $image" || fail "the pools' image: $image"

# A copy of what the script reads and writes, and a looper checkout's runner/startup.sh at a commit.
tree() {
  rm -rf "$work/repo" "$work/before"
  mkdir -p "$work/repo/ci" "$work/repo/modules/settings" "$work/repo/modules/projects/ci/files"
  cp "$here/ci/runner-image.sh" "$work/repo/ci/"
  cp "$here/modules/settings/main.tf" "$work/repo/modules/settings/"
  cp "$startup" "$work/repo/modules/projects/ci/files/"
  cp -r "$work/repo" "$work/before"
}
commit=0123456789abcdef0123456789abcdef01234567
mkdir -p "$work/looper/$commit/runner"
printf '#!/bin/bash\necho "runner: ready (a new startup.sh)"\n' > "$work/looper/$commit/runner/startup.sh"
export RUNNER_IMAGE_LOOPER_URL=file://$work/looper
bump() { "$work/repo/ci/runner-image.sh" "$@" > "$work/out" 2>&1; }

tree
if bump runner-arm64-docker-20261104-120000 "$commit"; then
  s=$work/repo/modules/settings/main.tf
  [ "$(pinned "$s" image)" = '"runner-arm64-docker-20261104-120000"' ] && ok "the bump pins the image by name" || fail "image after the bump: $(pinned "$s" image)"
  [ "$(pinned "$s" looper_commit)" = "\"$commit\"" ] && ok "the bump names the looper commit" || fail "looper_commit after the bump: $(pinned "$s" looper_commit)"
  cmp -s "$work/repo/modules/projects/ci/files/runner-startup.sh" "$work/looper/$commit/runner/startup.sh" &&
    ok "the bump writes that commit's runner/startup.sh" || fail "files/runner-startup.sh is not the commit's"
  [ "$(pinned "$s" startup_sha256)" = "\"$(sha256sum < "$work/looper/$commit/runner/startup.sh" | cut -d' ' -f1)\"" ] &&
    ok "the bump pins its SHA-256" || fail "startup_sha256 after the bump: $(pinned "$s" startup_sha256)"
  [ "$(diff "$work/before/modules/settings/main.tf" "$s" | grep -c '^[<>]')" = 6 ] &&
    ok "the bump changes those three lines of modules/settings and nothing else" || { fail "the bump changed more:"; diff "$work/before/modules/settings/main.tf" "$s"; }
  # Bumped again, the same: the result is the same.
  cp "$s" "$work/once"
  bump runner-arm64-docker-20261104-120000 "$commit" && cmp -s "$work/once" "$s" && ok "a repeated bump changes nothing" || fail "a repeated bump changed the pin"
else
  fail "the bump failed: $(cat "$work/out")"
fi

refused() { # refused WHY ARGS...
  local why=$1; shift
  tree
  if bump "$@"; then fail "$why: accepted"
  elif diff -r "$work/before" "$work/repo" >/dev/null; then ok "$why: refused, nothing changed"
  else fail "$why: refused, but it changed files"; fi
}
refused "a family" family/runner-arm64-docker "$commit"
refused "a family's path" projects/tacplus-ci/global/images/family/runner-arm64-docker "$commit"
refused "an image's path, not its name" projects/tacplus-ci/global/images/runner-arm64-docker-20261104-120000 "$commit"
refused "another image's name" ubuntu-2404-noble-arm64-v20261024 "$commit"
refused "a short commit" runner-arm64-docker-20261104-120000 0123456
refused "a commit with no startup.sh" runner-arm64-docker-20261104-120000 fedcba9876543210fedcba9876543210fedcba98
refused "no arguments"
exit "$failed"
