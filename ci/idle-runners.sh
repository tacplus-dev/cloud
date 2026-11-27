#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# plan:ci's check that the tacplus-ci pools' runners are idle (#113), before the apply that deletes the pools and their
# manager: nothing has run on them for a day (the issue's confirmation, from each runner's job history, with the
# pipeline's own GitLab token). The pools' runners are the token's group and project runners described "tacplus-ci
# <pool> ...", the description the gitlab stack gave them; for each, its last job and any job running. It says each
# one's last job (or none), and fails when one has a job running or created within IDLE_HOURS (24) hours, or when a
# call fails: then no plan, so no apply, until a person looks. Once the gitlab stack has deleted them it finds none and
# passes, saying so; it then goes in a later commit with the manager's removed block (PROPOSALS.md).
#
#   ci/idle-runners.sh      # GITLAB_TOKEN (ci/lib.sh ci_gitlab); IDLE_NOW (an ISO 8601 time, default now) for the
#                           # tests; needs bash, curl, jq, GNU date
set -uo pipefail
api_url=${GITLAB_API_URL:-https://gitlab.com/api/v4}
say() { echo "idle-runners.sh: $*"; }
die() { say "$*" >&2; exit 1; }
[ -n "${GITLAB_TOKEN:-}" ] || die "no GITLAB_TOKEN (ci/lib.sh ci_gitlab)"
hours=${IDLE_HOURS:-24}
now=$(date -u -d "${IDLE_NOW:-now}" +%s) || die "IDLE_NOW is no time: [${IDLE_NOW:-}]"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
( umask 077; printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" > "$tmp/auth" )

# api PATH: GitLab's answer to a GET on stdout; fails, saying why, unless it is a 2xx.
api() {
  local code
  code=$(curl -gsS -X GET -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' -H @"$tmp/auth" "$api_url$1") ||
    { say "cannot reach $api_url$1" >&2; return 1; }
  [[ $code == 2?? ]] || { say "GitLab answered GET $1 with HTTP $code: $(head -c 300 "$tmp/body")" >&2; return 1; }
  cat "$tmp/body"
}
# pages PATH: every page of a list (PATH has a query), one array on stdout.
pages() {
  local page=1 next
  : > "$tmp/pages"
  while :; do
    api "$1&per_page=100&page=$page" >> "$tmp/pages" || return 1
    next=$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Xx]-[Nn]ext-[Pp]age: *//p')
    [ -n "$next" ] || break
    page=$next
  done
  jq -s 'add // []' "$tmp/pages"
}

group=$(pages "/runners?type=group_type") && project=$(pages "/runners?type=project_type") || die "cannot list the runners"
pools=$(jq -n --argjson g "$group" --argjson p "$project" '$g + $p | map(select(.description // "" | startswith("tacplus-ci "))) | unique_by(.id)')
n=$(jq length <<< "$pools")
[ "$n" -gt 0 ] || { say "no tacplus-ci pool's runner is registered: nothing left to confirm"; exit 0; }
busy=0
while read -r id description; do
  what="runner $id ($description)"
  running=$(api "/runners/$id/jobs?status=running&per_page=1") || die "cannot read $what's running jobs"
  last=$(api "/runners/$id/jobs?order_by=id&sort=desc&per_page=1") || die "cannot read $what's last job"
  if jq -e 'length > 0' <<< "$running" > /dev/null; then
    say "$what: job $(jq -r '.[0].id' <<< "$running") is running: not idle"
    busy=1
  elif jq -e 'length == 0' <<< "$last" > /dev/null; then
    say "$what: no job: idle"
  else
    job=$(jq -r '.[0] | "job \(.id) (\(.project.path_with_namespace // .project.id)), \(.status), created \(.created_at)"' <<< "$last")
    at=$(jq -r '.[0].created_at | sub("\\.[0-9]+"; "") | fromdateiso8601' <<< "$last") || die "$what: its last job's created_at is no time"
    if [ $((now - at)) -lt $((hours * 3600)) ]; then
      say "$what: its last job, $job, is within $hours hours: not idle"
      busy=1
    else
      say "$what: idle, its last job $job"
    fi
  fi
done < <(jq -r '.[] | "\(.id) \(.description)"' <<< "$pools")
[ "$busy" = 0 ] || die "a tacplus-ci pool's runner has run a job within $hours hours (above): its pool is not deleted under it (#113)"
say "every tacplus-ci pool's runner ($n) idle for $hours hours"
