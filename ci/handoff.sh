#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The end of a manager handoff (#54), the cloud pipeline's handoff job, after apply:ci, on the new manager: no job
# stays `running` on an old manager, and the jobs the handoff cut run again, with no person. On 2026-11-13 (the
# handoff after the re-pin to a9ee214) the old manager's cut failed 20 looper jobs as runner_interrupted, which their
# retry does not name, and left 31 looper and 8 build jobs `running` (the ones it did not report before it exited,
# and the ones still waiting for a VM, which gitlab-runner's abort does not reach): they held their resource groups
# until the hub cancelled them, by force, and ran them again by hand.
#
# The runners this job's manager runs (the fleet's: every runner whose managers include this job's) have one manager
# alive, this one: a new one starts its gitlab-runner only once every older one is gone (README, No job lost to a new
# manager). So on each of them, for each other manager (its system ID) of this handoff, one that contacted GitLab since
# an hour before this pipeline began (an hour for GitLab's cache of it; a runner keeps every manager it ever had, and on
# 2026-11-14 asking about each of them took this job into GitLab's rate limit, #57):
#   - a job still `running` or `canceling` there is an orphan: cancelled (by force once `canceling`: GitLab otherwise
#     waits for a runner that is gone), then run again;
#   - a job failed there as runner_interrupted (the cut) since this pipeline began, and not run again yet (by its own
#     retry, or a person), is run again.
# A job run again runs as this token's user (a retry's); it starts behind its resource group like any other.
#
#   ci/handoff.sh       # GITLAB_TOKEN (ci/lib.sh ci_gitlab), CI_PROJECT_ID, CI_JOB_ID, CI_PIPELINE_CREATED_AT,
#                       # CI_JOB_STARTED_AT, CI_JOB_TIMEOUT
#
# GitLab's rate limit (HTTP 429) is waited out and the call made again, within the job's time limit (#57). Fails,
# having done all it could, when any call fails. Needs bash 5, curl, jq.
set -uo pipefail
api_url=${GITLAB_API_URL:-https://gitlab.com/api/v4}
say() { echo "handoff.sh: $*"; }
die() { say "$*" >&2; exit 1; }
[ -n "${GITLAB_TOKEN:-}" ] || die "no GITLAB_TOKEN (ci/lib.sh ci_gitlab)"
for v in CI_PROJECT_ID CI_JOB_ID CI_PIPELINE_CREATED_AT CI_JOB_STARTED_AT CI_JOB_TIMEOUT; do [ -n "${!v:-}" ] || die "no $v (a GitLab job's)"; done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
( umask 077; printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" > "$tmp/auth" )
errors=0

# api METHOD PATH: GitLab's answer on stdout; fails, saying why, unless it is a 2xx. Its rate limit (HTTP 429) is
# waited out, as its Retry-After says or, when it says nothing (or 0), backing off (1, 2, 4 ... 60 seconds), and the call made
# again, as long as the wait ends by the deadline.
api() {
  local code wait backoff=1
  while :; do
    code=$(curl -gsS -X "$1" -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' -H @"$tmp/auth" "$api_url$2") ||
      { say "cannot reach $api_url$2" >&2; return 1; }
    [ "$code" = 429 ] || break
    wait=$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9][0-9]*\) *$/\1/p')
    if [ "${wait:-0}" -eq 0 ]; then
      wait=$backoff backoff=$((backoff * 2 > 60 ? 60 : backoff * 2))
    fi
    [ $((EPOCHSECONDS + wait)) -le "$deadline" ] || { say "GitLab's rate limit (HTTP 429) on $1 $2: no time left to wait $wait second(s)" >&2; break; }
    say "GitLab's rate limit (HTTP 429) on $1 $2: waiting $wait second(s)" >&2
    sleep "$wait"
  done
  [[ $code == 2?? ]] || { say "GitLab answered $1 $2 with HTTP $code: $(head -c 300 "$tmp/body")" >&2; return 1; }
  cat "$tmp/body"
}
# pages PATH: every page of a list (PATH has a query), one array on stdout. STOP, a jq condition on the last page's
# items, ends it early.
pages() {
  local page=1 next stop=${2:-false}
  : > "$tmp/pages"
  while :; do
    api GET "$1&per_page=100&page=$page" >> "$tmp/pages" || return 1
    next=$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Xx]-[Nn]ext-[Pp]age: *//p')
    [ -n "$next" ] && ! jq -e "$stop" "$tmp/body" > /dev/null || break
    page=$next
  done
  jq -s 'add // []' "$tmp/pages"
}
# epoch: a UTC time as GitLab gives it (ISO 8601, Z, with or without its milliseconds) in seconds since the epoch.
epoch='sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601'
since=$(jq -rn --arg t "$CI_PIPELINE_CREATED_AT" "\$t | $epoch") || die "CI_PIPELINE_CREATED_AT is no time: [$CI_PIPELINE_CREATED_AT]"
# deadline: the last a wait for the rate limit may end, 5 minutes before the job's time limit, for the rest.
started=$(jq -rn --arg t "$CI_JOB_STARTED_AT" "\$t | $epoch") || die "CI_JOB_STARTED_AT is no time: [$CI_JOB_STARTED_AT]"
[[ $CI_JOB_TIMEOUT =~ ^[0-9]+$ ]] || die "CI_JOB_TIMEOUT is no number of seconds: [$CI_JOB_TIMEOUT]"
deadline=$((started + CI_JOB_TIMEOUT - 300))
# again PROJECT JOB WHAT: the job run again, said with WHAT.
again() {
  local new
  if new=$(api POST "/projects/$1/jobs/$2/retry" | jq -r .id); then
    say "job $2 (project $1) $3: run again as job $new"
  else
    errors=$((errors + 1))
  fi
}

mine=$(api GET "/projects/$CI_PROJECT_ID/jobs/$CI_JOB_ID" | jq -r '.runner_manager.system_id // empty') && [ -n "$mine" ] ||
  die "cannot tell which runner manager runs this job (job $CI_JOB_ID of project $CI_PROJECT_ID)"
say "this job's runner manager: $mine"
runners=$(pages "/runners?type=group_type" && pages "/runners?type=project_type") || die "cannot list the runners"
fleet=0
for r in $(jq -rs 'add | map(.id) | unique | .[]' <<< "$runners"); do
  managers=$(api GET "/runners/$r/managers") || { errors=$((errors + 1)); continue; }
  jq -e --arg me "$mine" 'any(.[]; .system_id == $me)' <<< "$managers" > /dev/null || continue
  fleet=$((fleet + 1))
  for old in $(jq -r --arg me "$mine" --argjson after "$((since - 3600))" \
    ".[] | select(.system_id != \$me and .contacted_at != null and (.contacted_at | $epoch) >= \$after) | .system_id" <<< "$managers"); do
    # Orphans: still running, or canceling, on a manager that is gone.
    for status in running canceling; do
      jobs=$(pages "/runners/$r/jobs?system_id=$old&status=$status") || { errors=$((errors + 1)); continue; }
      while read -r p j; do
        [ -n "$j" ] || continue
        state=$status
        if [ "$state" = running ]; then
          state=$(api POST "/projects/$p/jobs/$j/cancel" | jq -r .status) || { errors=$((errors + 1)); continue; }
        fi
        if [ "$state" = canceling ]; then
          state=$(api POST "/projects/$p/jobs/$j/cancel?force=true" | jq -r .status) || { errors=$((errors + 1)); continue; }
        fi
        case $state in
          canceled | failed) again "$p" "$j" "still $status on the old manager $old, now $state" ;;
          *) say "job $j (project $p) still $status on the old manager $old is $state after its cancel: not run again" >&2; errors=$((errors + 1)) ;;
        esac
      done < <(jq -r '.[] | "\(.project.id) \(.id)"' <<< "$jobs")
    done
    # The cut: failed as runner_interrupted since this pipeline began. The list is newest first; a job created a day
    # before it ends it (no job runs that long).
    jobs=$(pages "/runners/$r/jobs?system_id=$old&status=failed&order_by=id&sort=desc" \
      "any(.[]; (.created_at | $epoch) < $since - 86400)") || { errors=$((errors + 1)); continue; }
    while read -r p pl j; do
      [ -n "$j" ] || continue
      # Not run again yet: still among its pipeline's jobs, which list no job that was retried.
      current=$(pages "/projects/$p/pipelines/$pl/jobs?scope[]=failed") || { errors=$((errors + 1)); continue; }
      if jq -e --argjson j "$j" 'any(.[]; .id == $j)' <<< "$current" > /dev/null; then
        again "$p" "$j" "cut on the old manager $old (runner_interrupted)"
      else
        say "job $j (project $p) cut on the old manager $old: already run again"
      fi
    done < <(jq -r --argjson since "$since" ".[] | select(.failure_reason == \"runner_interrupted\" and .finished_at != null and (.finished_at | $epoch) >= \$since) | \"\(.project.id) \(.pipeline.id) \(.id)\"" <<< "$jobs")
  done
done
[ "$fleet" -gt 0 ] || die "no runner of this job's manager ($mine) among the token's runners"
[ "$errors" = 0 ] || die "$errors call(s) failed (above): the jobs they name are still to fail back or run again, by hand (README, A handoff with jobs in flight)"
say "no job left running on an old manager of the fleet's $fleet runners"
