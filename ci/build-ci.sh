#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# tacplus-dev/build's .gitlab-ci.yml (#26): the gitlab stack writes stacks/gitlab/files/build.gitlab-ci.yml to that
# project's main, and the file is tacplus-dev/looper's ci/build.gitlab-ci.yml at the commit the stack names
# (build_ci_commit), copied as is. The plan job of the gitlab stack runs check and lint before its plan, so a copy
# that differs, or that GitLab cannot read, is never applied (tacplus-dev/looper#94: one GitLab could not read failed
# every pipeline of its project).
#
#   ci/build-ci.sh check            # the copy is looper's file at build_ci_commit (from GitHub, no credential)
#   ci/build-ci.sh lint             # GitLab's lint of the copy in tacplus-dev/build (POST /projects/:id/ci/lint), with
#                                   # GITLAB_TOKEN (ci/lib.sh ci_gitlab): fails on an invalid file or a refusal
#   ci/build-ci.sh update COMMIT    # a bump: the copy becomes looper's file at COMMIT, and build_ci_commit COMMIT
#
# Needs curl, jq.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
stack=$here/stacks/gitlab/main.tf
copy=$here/stacks/gitlab/files/build.gitlab-ci.yml
project=tacplus-dev%2Fbuild
die() { echo "build-ci.sh: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch COMMIT FILE: looper's ci/build.gitlab-ci.yml at COMMIT into FILE.
fetch() {
  local url=https://raw.githubusercontent.com/tacplus-dev/looper/$1/ci/build.gitlab-ci.yml code
  code=$(curl -sS -o "$2" -w '%{http_code}' "$url") || die "cannot fetch $url"
  [ "$code" = 200 ] || die "GitHub answered $url with HTTP $code"
}

commit=$(sed -n 's/^ *build_ci_commit *= *"\([0-9a-f]*\)"$/\1/p' "$stack")
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "stacks/gitlab/main.tf names no full build_ci_commit: [$commit]"

case ${1:-} in
  check)
    fetch "$commit" "$tmp/looper"
    cmp -s "$tmp/looper" "$copy" ||
      die "stacks/gitlab/files/build.gitlab-ci.yml is not tacplus-dev/looper's ci/build.gitlab-ci.yml at $commit (ci/build-ci.sh update $commit)"
    echo "build-ci.sh: stacks/gitlab/files/build.gitlab-ci.yml is tacplus-dev/looper's ci/build.gitlab-ci.yml at $commit"
    ;;
  lint)
    [ -n "${GITLAB_TOKEN:-}" ] || die "no GITLAB_TOKEN (ci/lib.sh ci_gitlab)"
    ( umask 077; printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" > "$tmp/auth" )
    jq -n --rawfile c "$copy" '{content: $c}' > "$tmp/req"
    url=https://gitlab.com/api/v4/projects/$project/ci/lint
    code=$(curl -sS -o "$tmp/answer" -w '%{http_code}' -H @"$tmp/auth" -H 'Content-Type: application/json' \
      --data-binary @"$tmp/req" "$url") || die "cannot reach $url"
    [[ $code == 2?? ]] || die "GitLab answered POST $url with HTTP $code: $(head -c 300 "$tmp/answer")"
    jq -e '.valid == true' "$tmp/answer" > /dev/null ||
      die "GitLab's lint refuses stacks/gitlab/files/build.gitlab-ci.yml: $(jq -r '(.errors // []) | join("; ")' "$tmp/answer")"
    jq -r '(.warnings // [])[] | "build-ci.sh: warning: \(.)"' "$tmp/answer"
    echo "build-ci.sh: GitLab's lint of tacplus-dev/build: stacks/gitlab/files/build.gitlab-ci.yml is valid"
    ;;
  update)
    [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] || die "usage: ci/build-ci.sh update COMMIT (tacplus-dev/looper's, in full)"
    fetch "$2" "$tmp/looper"
    cp "$tmp/looper" "$copy"
    sed -i "s/^\( *build_ci_commit *= *\"\)[0-9a-f]*\"$/\1$2\"/" "$stack"
    echo "build-ci.sh: stacks/gitlab/files/build.gitlab-ci.yml is tacplus-dev/looper's ci/build.gitlab-ci.yml at $2"
    ;;
  *) die "usage: ci/build-ci.sh check | lint | update COMMIT" ;;
esac
