#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/nightly-builds.sh (#33), against a stub GitHub (tests/stub/github): list prints each repository of
# tacplus-dev, page after page, not archived, with a build.lock or a tacplus.lock on main, sorted; update writes them to
# stacks/gitlab/pinned-repositories.yaml, and the committed file is update's, never edited by hand; check reports each
# repository pinned and not in the file, or in the file and no longer pinned, and the drift job runs it; and each fails,
# writing nothing, when GitHub answers anything but a file or no file, or when no repository is pinned: a repository is
# never dropped (its schedule deleted) because GitHub did not answer. Needs bash, jq.
#
#   tests/nightly_builds_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_GITHUB=$work/github PATH=$here/tests/stub/github:$PATH GITHUB_API=http://api GITHUB_RAW=http://raw
# A copy of the repository's ci/ and its file, which update writes.
mkdir -p "$work/repo/stacks/gitlab" && cp -r "$here/ci" "$work/repo/" && cp "$here/stacks/gitlab/pinned-repositories.yaml" "$work/repo/stacks/gitlab/"
file=$work/repo/stacks/gitlab/pinned-repositories.yaml
run() { : > "$STUB_GITHUB/calls"; "$work/repo/ci/nightly-builds.sh" "$@" > "$work/out" 2> "$work/err"; }
names() { sed -n 's/^- \(.*\)$/\1/p' "$1"; }

# The committed file is update's: a stub GitHub that pins exactly its names gives it back as it is.
mkdir -p "$STUB_GITHUB/api/orgs/tacplus-dev"
names "$here/stacks/gitlab/pinned-repositories.yaml" | jq -R '{name: ., archived: false}' | jq -s . > "$STUB_GITHUB/api/orgs/tacplus-dev/repos?per_page=100&page=1"
pin() { mkdir -p "$STUB_GITHUB/raw/tacplus-dev/$1/$2" && echo "image@sha256:0" > "$STUB_GITHUB/raw/tacplus-dev/$1/$2/$3"; }
while read -r r; do pin "$r" main build.lock; done < <(names "$here/stacks/gitlab/pinned-repositories.yaml")
names "$here/stacks/gitlab/pinned-repositories.yaml" | grep -qx looper && names "$here/stacks/gitlab/pinned-repositories.yaml" | grep -qx cluster &&
  ok "tacplus-dev/looper and tacplus-dev/cluster are in stacks/gitlab/pinned-repositories.yaml" || fail "looper or cluster is not pinned in the file"
run update && cmp -s "$file" "$here/stacks/gitlab/pinned-repositories.yaml" &&
  ok "stacks/gitlab/pinned-repositories.yaml is what update writes: nobody edited it" ||
  fail "stacks/gitlab/pinned-repositories.yaml is not update's: $(diff "$here/stacks/gitlab/pinned-repositories.yaml" "$file")"
run check && [ ! -s "$work/out" ] && ok "check: nothing when the file is GitHub's" || fail "check of the same: $(cat "$work/out" "$work/err")"

# tacplus-dev: a full first page, a1..a100 (a3 archived), and a second, b and c. Pinned: a1 (build.lock), a2
# (tacplus.lock), c (build.lock on main); a3 archived with a build.lock; b's build.lock on another branch only.
rm -rf "$STUB_GITHUB" && mkdir -p "$STUB_GITHUB/api/orgs/tacplus-dev"
seq 1 100 | jq -R '{name: "a\(.)", archived: (. == "3")}' | jq -s . > "$STUB_GITHUB/api/orgs/tacplus-dev/repos?per_page=100&page=1"
echo '[{"name": "b", "archived": false}, {"name": "c", "archived": false}]' > "$STUB_GITHUB/api/orgs/tacplus-dev/repos?per_page=100&page=2"
pin a1 main build.lock && pin a2 main tacplus.lock && pin a3 main build.lock && pin b pin build.lock && pin c main build.lock

run list && [ "$(cat "$work/out")" = "$(printf 'a1\na2\nc')" ] &&
  ok "list: the repositories with a build.lock or a tacplus.lock on main, not archived, from every page, sorted" ||
  fail "list: $(cat "$work/out" "$work/err")"
grep -qxF 'http://api/orgs/tacplus-dev/repos?per_page=100&page=2' "$STUB_GITHUB/calls" &&
  ! grep -q 'page=3' "$STUB_GITHUB/calls" && ok "every page read, and no more" || fail "pages read: $(grep api "$STUB_GITHUB/calls")"
! grep -q '/a3/' "$STUB_GITHUB/calls" && ok "an archived repository is not read" || fail "a3 was read"

printf -- '- a1\n- b\n' > "$file"
run check && [ "$(cat "$work/out")" = "$(printf '%s\n' \
  'nightly-builds: tacplus-dev/a2 is pinned and has no nightly build schedule (ci/nightly-builds.sh update)' \
  'nightly-builds: tacplus-dev/c is pinned and has no nightly build schedule (ci/nightly-builds.sh update)' \
  'nightly-builds: tacplus-dev/b has a nightly build schedule and is no longer pinned (ci/nightly-builds.sh update)')" ] &&
  ok "check: a repository pinned and not in the file, and one in it no longer pinned, a line each; exit 0" ||
  fail "check: $(cat "$work/out" "$work/err")"
run update && [ "$(names "$file")" = "$(printf 'a1\na2\nc')" ] && grep -q '^# The pinned repositories of tacplus-dev, written by ci/nightly-builds.sh update' "$file" &&
  ok "update writes them, under its header" || fail "update: $(cat "$file" "$work/err")"
cp "$file" "$work/before"

pin a2 main build.lock && echo 'unavailable' > "$STUB_GITHUB/raw/tacplus-dev/a2/main/build.lock" && echo 503 > "$STUB_GITHUB/raw/tacplus-dev/a2/main/build.lock.code"
! run update && cmp -s "$file" "$work/before" && grep -q 'a2/main/build.lock with HTTP 503' "$work/err" &&
  ok "a repository GitHub does not answer for fails update, which writes nothing" || fail "update on a 503: $(cat "$work/out" "$work/err")"
! run check && [ ! -s "$work/out" ] && ok "and fails check, which reports nothing" || fail "check on a 503: $(cat "$work/out" "$work/err")"
rm "$STUB_GITHUB/raw/tacplus-dev/a2/main/build.lock" "$STUB_GITHUB/raw/tacplus-dev/a2/main/build.lock.code"

page=$STUB_GITHUB/api/orgs/tacplus-dev/repos?per_page=100\&page=2
cp "$page" "$work/page2"
echo '{"message": "API rate limit exceeded"}' > "$page" && echo 403 > "$page.code"
! run update && cmp -s "$file" "$work/before" && grep -q 'HTTP 403: {"message": "API rate limit exceeded"}' "$work/err" &&
  ok "a refused page of repositories fails update" || fail "a 403: $(cat "$work/out" "$work/err")"
rm "$page.code" && echo '{"message": "Not Found"}' > "$page"
! run list && [ ! -s "$work/out" ] && grep -q 'no list of repositories' "$work/err" &&
  ok "an answer that is no list fails" || fail "not a list: $(cat "$work/out" "$work/err")"
cp "$work/page2" "$page"

rm -rf "$STUB_GITHUB/raw"
! run update && cmp -s "$file" "$work/before" && grep -q 'no repository of tacplus-dev has a build.lock or a tacplus.lock' "$work/err" &&
  ok "no pinned repository at all fails update, which would delete every schedule" || fail "none pinned: $(cat "$work/out" "$work/err")"
! run && grep -q usage "$work/err" && ok "no command: its usage" || fail "no command: $(cat "$work/err")"

grep -qF '"$here/nightly-builds.sh" check' "$here/ci/drift.sh" && ok "the drift job runs check" || fail "ci/drift.sh does not run ci/nightly-builds.sh check"
grep -qF 'yamldecode(file("${path.module}/pinned-repositories.yaml"))' "$here/stacks/gitlab/main.tf" &&
  ok "the gitlab stack's schedules are the file's" || fail "stacks/gitlab/main.tf does not read pinned-repositories.yaml"

[ "$failed" = 0 ] && echo "nightly_builds_test: all passed" || { echo "nightly_builds_test: failed"; exit 1; }
