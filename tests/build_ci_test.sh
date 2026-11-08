#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/build-ci.sh (#26), which the plan job of the gitlab stack runs before its plan, against a stub curl
# (tests/stub/curl): check passes only when stacks/gitlab/files/build.gitlab-ci.yml is tacplus-dev/looper's
# ci/build.gitlab-ci.yml at the commit the stack names, from GitHub; lint sends it to GitLab's lint of
# tacplus-dev/build (POST /projects/:id/ci/lint, the token in a header file, never on a command line) and fails on an
# invalid file or a refusal; the stack names a full commit and copies the file, and the pipeline runs both before
# plan:gitlab. Needs bash, jq.
#
#   tests/build_ci_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_CURL=$work/curl PATH=$here/tests/stub/curl:$PATH
file=$here/stacks/gitlab/files/build.gitlab-ci.yml
commit=$(sed -n 's/^ *build_ci_commit *= *"\([0-9a-f]*\)"$/\1/p' "$here/stacks/gitlab/main.tf")
reset() { rm -rf "$STUB_CURL"; mkdir -p "$STUB_CURL"; }

[[ $commit =~ ^[0-9a-f]{40}$ ]] && ok "the stack names tacplus-dev/looper's commit in full ($commit)" || fail "build_ci_commit: [$commit]"
grep -qF 'content        = file("${path.module}/files/build.gitlab-ci.yml")' "$here/stacks/gitlab/main.tf" &&
  ok "the stack copies files/build.gitlab-ci.yml as is" || fail "stacks/gitlab/main.tf does not copy files/build.gitlab-ci.yml"

reset
cp "$file" "$STUB_CURL/raw"
"$here/ci/build-ci.sh" check > "$work/out" 2>&1 &&
  grep -qxF "GET https://raw.githubusercontent.com/tacplus-dev/looper/$commit/ci/build.gitlab-ci.yml" "$STUB_CURL/calls" &&
  ok "check: the copy is tacplus-dev/looper's ci/build.gitlab-ci.yml at that commit" || fail "check, same: $(cat "$work/out" "$STUB_CURL/calls")"
reset
{ cat "$file"; echo "# changed"; } > "$STUB_CURL/raw"
! "$here/ci/build-ci.sh" check > "$work/out" 2>&1 && grep -q 'is not tacplus-dev/looper' "$work/out" &&
  ok "check: a copy that differs is refused" || fail "check, differs: $(cat "$work/out")"
reset
! "$here/ci/build-ci.sh" check > "$work/out" 2>&1 && grep -q 'HTTP 404' "$work/out" &&
  ok "check: a file GitHub does not give is refused" || fail "check, 404: $(cat "$work/out")"

reset
echo '{"valid": true, "errors": [], "warnings": []}' > "$STUB_CURL/answer"
GITLAB_TOKEN=glpat-secret-stub "$here/ci/build-ci.sh" lint > "$work/out" 2>&1 &&
  grep -qxF "POST https://gitlab.com/api/v4/projects/tacplus-dev%2Fbuild/ci/lint" "$STUB_CURL/calls" &&
  jq -e --rawfile f "$file" '.content == $f' "$STUB_CURL/body" > /dev/null &&
  ok "lint: GitLab's lint of tacplus-dev/build gets the file, valid passes" || fail "lint, valid: $(cat "$work/out" "$STUB_CURL/calls")"
grep -qxF 'PRIVATE-TOKEN: glpat-secret-stub' "$STUB_CURL/headers" && ! grep -q glpat-secret-stub "$STUB_CURL/calls" "$work/out" &&
  ok "lint: the token in a header file, on no command line and in no output" || fail "lint, token: $(cat "$STUB_CURL/calls" "$work/out")"
reset
echo '{"valid": false, "errors": ["jobs:plan config contains unknown keys: scrip"], "warnings": []}' > "$STUB_CURL/answer"
! GITLAB_TOKEN=x "$here/ci/build-ci.sh" lint > "$work/out" 2>&1 && grep -qF 'unknown keys: scrip' "$work/out" &&
  ok "lint: an invalid file is refused, with GitLab's errors" || fail "lint, invalid: $(cat "$work/out")"
reset
echo '{"message": "403 Forbidden"}' > "$STUB_CURL/answer"
echo 403 > "$STUB_CURL/code"
! GITLAB_TOKEN=x "$here/ci/build-ci.sh" lint > "$work/out" 2>&1 && grep -qF 'HTTP 403' "$work/out" &&
  ok "lint: a refusal fails it" || fail "lint, 403: $(cat "$work/out")"
reset
! env -u GITLAB_TOKEN "$here/ci/build-ci.sh" lint > "$work/out" 2>&1 && [ ! -s "$STUB_CURL/calls" ] &&
  ok "lint: no GITLAB_TOKEN, no call" || fail "lint, no token: $(cat "$work/out")"

# A bump, on a copy of the repository: the copy becomes looper's file at the new commit, and the stack names it.
reset
mkdir -p "$work/repo/stacks/gitlab/files" && cp -r "$here/ci" "$work/repo/" && cp "$here/stacks/gitlab/main.tf" "$work/repo/stacks/gitlab/"
echo "stages: [new]" > "$STUB_CURL/raw"
new=0123456789abcdef0123456789abcdef01234567
"$work/repo/ci/build-ci.sh" update "$new" > "$work/out" 2>&1 && cmp -s "$STUB_CURL/raw" "$work/repo/stacks/gitlab/files/build.gitlab-ci.yml" &&
  grep -qxF "  build_ci_commit = \"$new\"" "$work/repo/stacks/gitlab/main.tf" && [ "$(diff "$here/stacks/gitlab/main.tf" "$work/repo/stacks/gitlab/main.tf" | grep -c '^[<>]')" = 2 ] &&
  grep -qxF "GET https://raw.githubusercontent.com/tacplus-dev/looper/$new/ci/build.gitlab-ci.yml" "$STUB_CURL/calls" &&
  ok "update: the copy and build_ci_commit become the new commit's, nothing else" || fail "update: $(cat "$work/out")"
! "$work/repo/ci/build-ci.sh" update main > "$work/out" 2>&1 && ok "update: a commit not in full is refused" || fail "update main: $(cat "$work/out")"

# The pipeline: plan:gitlab checks and lints the copy before its plan, so a bad one is never applied.
grep -qF 'ci_gcp && ci_gitlab && ci/build-ci.sh check && ci/build-ci.sh lint && ci/tofu.sh plan "$STACK"' "$here/ci/gitlab-project.gitlab-ci.yml" &&
  ok "plan:gitlab checks and lints it before the plan" || fail "ci/gitlab-project.gitlab-ci.yml: plan:gitlab does not run ci/build-ci.sh check and lint first"
exit "$failed"
