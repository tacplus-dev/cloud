#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/handoff.sh (#54), the cloud pipeline's handoff job, against a stub GitLab API (tests/stub/handoff), on the
# handoff of 2026-11-13 in small: jobs left `running` and `canceling` on the old managers, jobs they failed as
# runner_interrupted. It finds the fleet's runners (those its own manager runs, over pages), not another's; on each,
# for each other manager, it cancels a job still running (by force once canceling) and runs it again, and runs again
# a job cut (runner_interrupted) since its pipeline began that is still its pipeline's (not retried yet); nothing of
# its own manager's, no other failure, no older cut, no job already retried, and it reads no further back than a day
# before its pipeline; nor anything of a manager gone before its pipeline (#57: one not in this handoff). GitLab's rate
# limit (HTTP 429) is waited out, as its Retry-After says or backing off, and the call made again, within the job's
# time limit (#57). The token goes in a header file only. A failed call fails it, after the rest is done; and it
# refuses to run without its token, or without knowing its own manager. Needs bash, jq.
#
#   tests/handoff_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_HANDOFF=$work/api PATH=$here/tests/stub/handoff:$PATH
export GITLAB_TOKEN=glpat-the-token CI_PROJECT_ID=10 CI_JOB_ID=900 CI_PIPELINE_CREATED_AT=2026-11-13T12:00:00Z
export CI_JOB_STARTED_AT CI_JOB_TIMEOUT=3600
CI_JOB_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run() { : > "$STUB_HANDOFF/calls"; : > "$STUB_HANDOFF/headers"; "$here/ci/handoff.sh" > "$work/out" 2>&1; }
called() { grep -qxF "$1" "$STUB_HANDOFF/calls"; }

# The world: this job (project 10) on the new manager s_new. Runners 1 (shared) and 2 (build) are the fleet's, run by
# s_new and before it by s_old (and, for 2, s_older, gone the day before the pipeline, s_gone, which contacted GitLab
# last just over an hour before it, and s_never, which never did: no managers of this handoff); 3 is another's (the
# cluster's own), 4 the cluster pool's, which only s_new has run. The group runners come over two pages.
# job JSON ID PROJECT PIPELINE CREATED FINISHED [REASON]: a job as a runner's job list gives it.
job() { jq -nc --argjson id "$1" --argjson p "$2" --argjson pl "$3" --arg c "$4" --arg f "$5" --arg r "${6:-}" \
  '{id: $id, project: {id: $p}, pipeline: {id: $pl}, created_at: $c, finished_at: (if $f == "" then null else $f end)} + (if $r == "" then {} else {failure_reason: $r} end)'; }
world() {
  mkdir -p "$STUB_HANDOFF"
  jq -n \
    --argjson j101 "$(job 101 20 500 2026-11-13T08:00:00.000Z '')" \
    --argjson j102 "$(job 102 20 500 2026-11-13T08:00:00.000Z '')" \
    --argjson j103 "$(job 103 30 501 2026-11-13T11:00:00.000Z '')" \
    --argjson j110 "$(job 110 20 500 2026-11-13T09:00:00.000Z 2026-11-13T12:37:12.345Z runner_interrupted)" \
    --argjson j111 "$(job 111 20 500 2026-11-13T09:00:00.000Z 2026-11-13T12:36:00.000Z script_failure)" \
    --argjson j112 "$(job 112 20 499 2026-11-13T06:00:00.000Z 2026-11-13T11:59:00.000Z runner_interrupted)" \
    --argjson j113 "$(job 113 20 400 2026-11-11T09:00:00.000Z 2026-11-11T10:00:00.000Z runner_interrupted)" \
    --argjson j120 "$(job 120 30 501 2026-11-13T10:00:00.000Z 2026-11-13T12:37:00.000Z runner_interrupted)" '
  {
    "GET /projects/10/jobs/900": {body: {id: 900, runner_manager: {system_id: "s_new"}}},
    "GET /runners?type=group_type&per_page=100&page=1": {body: [{id: 1}, {id: 2}], next: "2"},
    "GET /runners?type=group_type&per_page=100&page=2": {body: [{id: 3}]},
    "GET /runners?type=project_type&per_page=100&page=1": {body: [{id: 4}]},
    "GET /runners/1/managers": {body: [{system_id: "s_old", contacted_at: "2026-11-13T12:37:20.000Z"}, {system_id: "s_new", contacted_at: "2026-11-13T13:20:00.000Z"}]},
    "GET /runners/2/managers": {body: [{system_id: "s_older", contacted_at: "2026-11-12T09:00:00.000Z"}, {system_id: "s_gone", contacted_at: "2026-11-13T10:59:59.000Z"},
      {system_id: "s_never", contacted_at: null}, {system_id: "s_old", contacted_at: "2026-11-13T11:30:00Z"}, {system_id: "s_new", contacted_at: "2026-11-13T13:20:00.000Z"}]},
    "GET /runners/3/managers": {body: [{system_id: "s_cluster", contacted_at: "2026-11-13T13:20:00.000Z"}]},
    "GET /runners/4/managers": {body: [{system_id: "s_new", contacted_at: "2026-11-13T13:20:00.000Z"}]},
    "GET /runners/1/jobs?system_id=s_old&status=running&per_page=100&page=1": {body: [$j101]},
    "GET /runners/1/jobs?system_id=s_old&status=canceling&per_page=100&page=1": {body: [$j102]},
    "GET /runners/2/jobs?system_id=s_old&status=running&per_page=100&page=1": {body: [$j103]},
    "GET /runners/2/jobs?system_id=s_old&status=canceling&per_page=100&page=1": {body: []},
    "GET /runners/1/jobs?system_id=s_old&status=failed&order_by=id&sort=desc&per_page=100&page=1": {body: [$j110, $j111, $j112], next: "2"},
    "GET /runners/1/jobs?system_id=s_old&status=failed&order_by=id&sort=desc&per_page=100&page=2": {body: [$j113], next: "3"},
    "GET /runners/2/jobs?system_id=s_old&status=failed&order_by=id&sort=desc&per_page=100&page=1": {body: [$j120]},
    "POST /projects/20/jobs/101/cancel": {body: {id: 101, status: "canceling"}},
    "POST /projects/20/jobs/101/cancel?force=true": {body: {id: 101, status: "canceled"}},
    "POST /projects/20/jobs/101/retry": {body: {id: 201}},
    "POST /projects/20/jobs/102/cancel?force=true": {body: {id: 102, status: "canceled"}},
    "POST /projects/20/jobs/102/retry": {body: {id: 202}},
    "POST /projects/30/jobs/103/cancel": {body: {id: 103, status: "canceled"}},
    "POST /projects/30/jobs/103/retry": {body: {id: 203}},
    "GET /projects/20/pipelines/500/jobs?scope[]=failed&per_page=100&page=1": {body: [{id: 110}, {id: 111}]},
    "GET /projects/30/pipelines/501/jobs?scope[]=failed&per_page=100&page=1": {body: []},
    "POST /projects/20/jobs/110/retry": {body: {id: 210}}
  }' > "$STUB_HANDOFF/api.json"
}
world

run && ok "the handoff exits 0" || fail "exit: $(cat "$work/out")"
called "POST /projects/20/jobs/101/cancel" && called "POST /projects/20/jobs/101/cancel?force=true" && called "POST /projects/20/jobs/101/retry" &&
  [ "$(grep -n 101 "$STUB_HANDOFF/calls" | cut -d: -f2- | tr '\n' ,)" = "POST /projects/20/jobs/101/cancel,POST /projects/20/jobs/101/cancel?force=true,POST /projects/20/jobs/101/retry," ] &&
  grep -qxF "handoff.sh: job 101 (project 20) still running on the old manager s_old, now canceled: run again as job 201" "$work/out" &&
  ok "a job still running on an old manager: cancelled, by force once canceling, then run again" || fail "running: $(cat "$work/out" "$STUB_HANDOFF/calls")"
! called "POST /projects/20/jobs/102/cancel" && called "POST /projects/20/jobs/102/cancel?force=true" && called "POST /projects/20/jobs/102/retry" &&
  ok "a job left canceling: cancelled by force, then run again" || fail "canceling: $(cat "$work/out" "$STUB_HANDOFF/calls")"
called "POST /projects/30/jobs/103/cancel" && ! called "POST /projects/30/jobs/103/cancel?force=true" && called "POST /projects/30/jobs/103/retry" &&
  ok "a job a plain cancel ends: no force, run again" || fail "plain cancel: $(cat "$work/out" "$STUB_HANDOFF/calls")"
called "POST /projects/20/jobs/110/retry" &&
  grep -qxF "handoff.sh: job 110 (project 20) cut on the old manager s_old (runner_interrupted): run again as job 210" "$work/out" &&
  ok "a job cut (runner_interrupted) since the pipeline began, still its pipeline's: run again" || fail "cut: $(cat "$work/out" "$STUB_HANDOFF/calls")"
! called "POST /projects/30/jobs/120/retry" && grep -qxF "handoff.sh: job 120 (project 30) cut on the old manager s_old: already run again" "$work/out" &&
  ok "a cut job already run again (no longer its pipeline's): left alone" || fail "retried: $(cat "$work/out" "$STUB_HANDOFF/calls")"
! grep -qE '^POST /projects/20/jobs/11[123]/' "$STUB_HANDOFF/calls" &&
  ok "no other failure, no cut from before the pipeline, run again" || fail "others: $(cat "$STUB_HANDOFF/calls")"
! grep -qF 'page=3' "$STUB_HANDOFF/calls" && called "GET /runners?type=group_type&per_page=100&page=2" &&
  called "GET /runners/1/jobs?system_id=s_old&status=failed&order_by=id&sort=desc&per_page=100&page=2" &&
  ok "the lists followed over their pages, and the failures no further back than a day before the pipeline" || fail "pages: $(cat "$STUB_HANDOFF/calls")"
! grep -qE 'system_id=s_new|^GET /runners/[34]/jobs|s_cluster' "$STUB_HANDOFF/calls" &&
  ok "nothing of its own manager's, nor of a runner it does not run" || fail "own or other: $(cat "$STUB_HANDOFF/calls")"
! grep -qE 'system_id=s_(older|gone|never)' "$STUB_HANDOFF/calls" && [ "$(grep -c '^GET /runners/[0-9]*/jobs' "$STUB_HANDOFF/calls")" = 7 ] &&
  ok "only the managers of this handoff asked about (contacted GitLab since an hour before the pipeline)" ||
  fail "managers: $(cat "$STUB_HANDOFF/calls")"
! grep -q '^sleep' "$STUB_HANDOFF/calls" && ok "no rate limit: no wait" || fail "waited: $(cat "$STUB_HANDOFF/calls")"
[ "$(sort -u "$STUB_HANDOFF/headers")" = "PRIVATE-TOKEN: glpat-the-token" ] && ! grep -q glpat "$STUB_HANDOFF/calls" "$work/out" &&
  ok "the token in a header file only, never printed" || fail "token: $(cat "$STUB_HANDOFF/headers")"

# A call that fails: the rest still done, then the job fails, saying so.
jq '.["POST /projects/20/jobs/101/retry"] = {status: 403, body: {message: "403 Forbidden"}}' "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
! run && called "POST /projects/30/jobs/103/retry" && called "POST /projects/20/jobs/110/retry" &&
  grep -qF "GitLab answered POST /projects/20/jobs/101/retry with HTTP 403" "$work/out" && grep -qF "1 call(s) failed" "$work/out" &&
  ok "a call that fails: the others done, then it fails, saying which" || fail "403: $(cat "$work/out")"

# GitLab's rate limit (#57): a 429 is waited out (its Retry-After, or backing off when it has none) and the call made
# again; nothing is counted failed.
world
jq '.["GET /runners/1/managers"] = {status: 429, retry_after: "7", body: {message: "Rate limit exceeded"}, then: .["GET /runners/1/managers"]} |
  .["GET /runners/2/jobs?system_id=s_old&status=running&per_page=100&page=1"] as $ok |
  .["GET /runners/2/jobs?system_id=s_old&status=running&per_page=100&page=1"] =
    {status: 429, body: {message: "Rate limit exceeded"}, then: {status: 429, body: {message: "Rate limit exceeded"}, then: $ok}}' \
  "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
running2="GET /runners/2/jobs?system_id=s_old&status=running&per_page=100&page=1"
run && called "POST /projects/20/jobs/101/retry" && called "POST /projects/30/jobs/103/retry" && called "POST /projects/20/jobs/110/retry" &&
  [ "$(grep -xF -e "GET /runners/1/managers" -e "sleep 7" "$STUB_HANDOFF/calls" | tr '\n' ,)" = "GET /runners/1/managers,sleep 7,GET /runners/1/managers," ] &&
  [ "$(grep -xF -e "$running2" -e "sleep 1" -e "sleep 2" "$STUB_HANDOFF/calls" | tr '\n' ,)" = "$running2,sleep 1,$running2,sleep 2,$running2," ] &&
  grep -qF "GitLab's rate limit (HTTP 429) on GET /runners/1/managers: waiting 7 second(s)" "$work/out" && ! grep -qF "call(s) failed" "$work/out" &&
  ok "HTTP 429 then 200: waited out (its Retry-After, else backing off 1, 2, ...), the call made again, nothing failed" ||
  fail "429: $(cat "$work/out" "$STUB_HANDOFF/calls")"
# ... but no further than the job's time limit: a wait that would end past it fails the call, the rest still done.
world
jq '.["GET /runners/1/managers"] = {status: 429, retry_after: "60", body: {message: "Rate limit exceeded"}, then: .["GET /runners/1/managers"]}' \
  "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
CI_JOB_STARTED_AT=$(date -u -d '-58 minutes' +%Y-%m-%dT%H:%M:%SZ) run; [ $? != 0 ] && ! grep -q '^sleep' "$STUB_HANDOFF/calls" &&
  called "POST /projects/30/jobs/103/retry" && grep -qF "GitLab answered GET /runners/1/managers with HTTP 429" "$work/out" &&
  grep -qF "1 call(s) failed" "$work/out" &&
  ok "a 429 whose wait would end past the job's time limit: that call failed, the others done" || fail "429 late: $(cat "$work/out" "$STUB_HANDOFF/calls")"

# A cancel that does not end the job: it is not run again, and the handoff fails.
world
jq '.["POST /projects/30/jobs/103/cancel"] = {body: {id: 103, status: "running"}}' "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
! run && ! called "POST /projects/30/jobs/103/retry" && grep -qF "job 103 (project 30) still running on the old manager s_old is running after its cancel: not run again" "$work/out" &&
  ok "a job its cancel does not end: not run again, the handoff fails" || fail "not ended: $(cat "$work/out" "$STUB_HANDOFF/calls")"

# Its own manager unknown, or no runner of it: refused before any job is touched.
world
jq '.["GET /projects/10/jobs/900"] = {body: {id: 900, runner_manager: null}}' "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
! run && grep -qF "cannot tell which runner manager runs this job" "$work/out" && ! grep -q '^POST' "$STUB_HANDOFF/calls" &&
  ok "its own manager unknown: refused, nothing touched" || fail "no manager: $(cat "$work/out")"
world
jq '.["GET /projects/10/jobs/900"] = {body: {id: 900, runner_manager: {system_id: "s_elsewhere"}}}' "$STUB_HANDOFF/api.json" > "$work/api.new" && mv "$work/api.new" "$STUB_HANDOFF/api.json"
! run && grep -qF "no runner of this job's manager (s_elsewhere)" "$work/out" && ! grep -q '^POST' "$STUB_HANDOFF/calls" &&
  ok "a manager that runs none of the token's runners: refused, nothing touched" || fail "no fleet: $(cat "$work/out")"
world
GITLAB_TOKEN='' run; [ $? != 0 ] && grep -qF "no GITLAB_TOKEN" "$work/out" && [ ! -s "$STUB_HANDOFF/calls" ] &&
  ok "no token: refused, nothing asked" || fail "no token: $(cat "$work/out")"

[ "$failed" = 0 ] || exit 1
