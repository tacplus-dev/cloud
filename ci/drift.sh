#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The nightly drift check (the drift job, on a schedule): a plan of each stack (ci/tofu.sh drift: not saved, no
# state lock), and when anything differs, an issue on github.com/tacplus-dev/cloud saying what, filed through the
# tacplus-reader app (github_app_token in ci/lib.sh, issues: write on this repository alone). One open issue at a
# time: while it is open, a new drift is a comment on it, and the same drift again is nothing. It never applies.
# A plan sees only what is in a stack's state, so the live audit (ci/audit.sh) then checks everything the projects
# hold, hand-made or not, against the network rules ci/policy.sh refuses in a plan (#7), and the DNS check (ci/dns.sh)
# what the public resolvers answer against tacplus.dev's zone (#13): their findings are drift too.
# (tacplus-dev/cluster ci/drift.sh is the pattern.)
#
#   ci/drift.sh STACK...    # sources ci/lib.sh; needs what ci/tofu.sh needs, and curl, jq, openssl
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: ci/drift.sh STACK..." >&2; exit 1; }
# shellcheck source=ci/lib.sh
source "$here/lib.sh"
repo=${GITHUB_REPOSITORY:-tacplus-dev/cloud}
api=${GITHUB_API:-https://api.github.com}
title="Drift in the cloud accounts"
die() { echo "drift: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/summary"
for stack in "$@"; do
  PLAN_SUMMARY=$tmp/summary "$here/tofu.sh" drift "$stack"
done
# shellcheck disable=SC2046 # one project ID a word
"$here/audit.sh" $(ci_projects) | tee -a "$tmp/summary" || echo "live: the audit failed: see the job's log" | tee -a "$tmp/summary"
# shellcheck disable=SC2046 # the project and the zone, a word each
"$here/dns.sh" $(ci_zone) | tee -a "$tmp/summary" || echo "dns: the check failed: see the job's log" | tee -a "$tmp/summary"
[ -s "$tmp/summary" ] || { echo "drift: none"; exit 0; }

mark="drift-sha256:$(sha256sum < "$tmp/summary" | cut -c1-16)"
{
  echo "The nightly drift check found the cloud accounts differ from $repo@${CLOUD_COMMIT:-unknown} (what an apply of each stack would change, and, as \`live\`, what the projects hold against the network rules, and, as \`dns\`, what the public resolvers answer against the zone):"
  echo
  echo '```'
  cat "$tmp/summary"
  echo '```'
  echo
  echo "Pipeline: ${CI_PIPELINE_URL:-unknown}. The drift job never applies: a change made by hand is either captured as a commit here, which the pipeline applies, or reverted (README, Drift)."
  echo
  echo "<!-- $mark -->"
} > "$tmp/body"

token=$(github_app_token "${repo#*/}" '{"issues":"write"}') || die "no GitHub token to file the drift: it is in this job's log only"
( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth" )
gh_api() { # gh_api METHOD PATH [BODY_FILE]
  local code
  code=$(curl -sS -o "$tmp/answer" -w '%{http_code}' -X "$1" -H @"$tmp/auth" -H 'Accept: application/vnd.github+json' \
    ${3:+--data-binary @"$3"} "$api$2") || return 1
  [[ $code == 2?? ]] || { echo "drift: GitHub answered $1 $2 with HTTP $code: $(head -c 300 "$tmp/answer")" >&2; return 1; }
  cat "$tmp/answer"
}

open=$(gh_api GET "/repos/$repo/issues?state=open&per_page=100" |
  jq -r --arg t "$title" '[.[] | select(.title == $t and (has("pull_request") | not))][0].number // empty') || die "cannot list the issues of $repo"
if [ -z "$open" ]; then
  jq -n --arg t "$title" --rawfile b "$tmp/body" '{title: $t, body: $b}' > "$tmp/req"
  n=$(gh_api POST "/repos/$repo/issues" "$tmp/req" | jq -r '.number') || die "cannot file the issue"
  echo "drift: filed $repo#$n"
elif { gh_api GET "/repos/$repo/issues/$open" | jq -r '.body // ""'
       gh_api GET "/repos/$repo/issues/$open/comments?per_page=100" | jq -r '.[].body'; } | grep -qF "$mark"; then
  echo "drift: the same drift is already on $repo#$open"
else
  jq -n --rawfile b "$tmp/body" '{body: $b}' > "$tmp/req"
  gh_api POST "/repos/$repo/issues/$open/comments" "$tmp/req" >/dev/null || die "cannot comment on $repo#$open"
  echo "drift: commented on $repo#$open"
fi
