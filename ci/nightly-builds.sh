#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pinned repositories of tacplus-dev (#33): each repository of the GitHub organization, not archived, whose main
# holds a build.lock or a tacplus.lock. The gitlab stack makes one nightly build schedule of tacplus-dev/build per name
# of stacks/gitlab/pinned-repositories.yaml, which update writes from GitHub and nobody edits: the plan stays the
# commit's alone (tacplus-dev/roadmap decisions/deterministic-deployments-2026-11-02.md), and the drift job's check
# reports a repository pinned (or unpinned) since, so none is missed. Public repositories, read with no credential, as
# the build pipeline reads them. Any answer but a found or a missing file fails: an error is never read as "not pinned".
#
#   ci/nightly-builds.sh list      # prints them from GitHub, one a line, sorted
#   ci/nightly-builds.sh update    # writes them to stacks/gitlab/pinned-repositories.yaml: commit it
#   ci/nightly-builds.sh check     # the drift's: a line per repository the file and GitHub disagree on; exit 0 when
#                                  # it finds some (drift reports, it does not fail), 1 when GitHub cannot say
#
# Needs curl, jq. GITHUB_API and GITHUB_RAW set GitHub's API and raw file hosts (the tests' stub).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
file=$here/stacks/gitlab/pinned-repositories.yaml
org=tacplus-dev
api=${GITHUB_API:-https://api.github.com}
raw=${GITHUB_RAW:-https://raw.githubusercontent.com}
die() { echo "nightly-builds.sh: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# get URL: the HTTP status of a GET of URL, its body in $tmp/body.
get() { curl -sS -o "$tmp/body" -w '%{http_code}' "$1" || die "cannot reach $1"; }

# pinned: the pinned repositories into $tmp/pinned, one a line, sorted.
pinned() {
  local page=1 url code repo lock
  : > "$tmp/repos"
  while :; do
    url="$api/orgs/$org/repos?per_page=100&page=$page"
    code=$(get "$url")
    [ "$code" = 200 ] || die "GitHub answered $url with HTTP $code: $(head -c 300 "$tmp/body")"
    jq -e 'type == "array"' "$tmp/body" > /dev/null || die "GitHub answered $url with no list of repositories"
    jq -r '.[] | select(.archived | not) | .name' "$tmp/body" >> "$tmp/repos"
    [ "$(jq length "$tmp/body")" = 100 ] || break
    page=$((page + 1))
  done
  : > "$tmp/found"
  while read -r repo; do
    for lock in build.lock tacplus.lock; do
      url="$raw/$org/$repo/main/$lock"
      code=$(get "$url")
      case $code in
        200) echo "$repo" >> "$tmp/found"; break ;;
        404) ;;
        *) die "GitHub answered $url with HTTP $code" ;;
      esac
    done
  done < "$tmp/repos"
  [ -s "$tmp/found" ] || die "no repository of $org has a build.lock or a tacplus.lock on main"
  LC_ALL=C sort -u "$tmp/found" > "$tmp/pinned"
}

case ${1:-} in
  list)
    pinned
    cat "$tmp/pinned"
    ;;
  update)
    pinned
    {
      echo "# Copyright (c) 2026 Jody Scott"
      echo "# SPDX-License-Identifier: Apache-2.0"
      echo "#"
      echo "# The pinned repositories of tacplus-dev, written by ci/nightly-builds.sh update from GitHub (#33): never edit it."
      echo "# The gitlab stack makes one nightly build schedule of tacplus-dev/build per name (stacks/gitlab/main.tf)."
      sed 's/^/- /' "$tmp/pinned"
    } > "$file"
    echo "nightly-builds.sh: stacks/gitlab/pinned-repositories.yaml: $(wc -l < "$tmp/pinned") pinned repositories"
    ;;
  check)
    pinned
    sed -n 's/^- \(.*\)$/\1/p' "$file" | LC_ALL=C sort -u > "$tmp/scheduled"
    LC_ALL=C comm -23 "$tmp/pinned" "$tmp/scheduled" | while read -r repo; do
      echo "nightly-builds: $org/$repo is pinned and has no nightly build schedule (ci/nightly-builds.sh update)"
    done
    LC_ALL=C comm -13 "$tmp/pinned" "$tmp/scheduled" | while read -r repo; do
      echo "nightly-builds: $org/$repo has a nightly build schedule and is no longer pinned (ci/nightly-builds.sh update)"
    done
    ;;
  *) die "usage: ci/nightly-builds.sh list | update | check" ;;
esac
