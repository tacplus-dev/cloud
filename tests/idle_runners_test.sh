#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/idle-runners.sh (#113), plan:ci's check that the tacplus-ci pools' runners are idle before the apply that
# deletes the pools and their manager, against a stub GitLab API (tests/stub/gitlab): it finds the pools' runners among
# the token's group and project runners (over pages) by their description, not the in-cluster ones; it passes when
# each one's last job is more than 24 hours old, or it has none, and says each one's; it fails on a job created within
# the 24 hours, on a job running, and on a failed call; it passes, saying so, once no pool's runner is registered; and
# it refuses to run without its token, which goes in a header file only. Needs bash, jq, GNU date.
#
#   tests/idle_runners_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_GITLAB=$work/api PATH=$here/tests/stub/gitlab:$PATH
export GITLAB_TOKEN=glpat-the-token IDLE_NOW=2026-11-26T15:00:00Z
mkdir -p "$STUB_GITLAB"
run() { : > "$STUB_GITLAB/calls"; : > "$STUB_GITLAB/headers"; "$here/ci/idle-runners.sh" > "$work/out" 2>&1; }
called() { grep -qxF "$1" "$STUB_GITLAB/calls"; }
said() { grep -qF "$1" "$work/out"; }

# job ID CREATED STATUS: a job as a runner's job list gives it.
job() { jq -nc --argjson id "$1" --arg c "$2" --arg s "$3" '{id: $id, status: $s, created_at: $c, project: {id: 20, path_with_namespace: "tacplus-dev/looper"}}'; }
last() { echo "GET /runners/$1/jobs?order_by=id&sort=desc&per_page=1"; }
running() { echo "GET /runners/$1/jobs?status=running&per_page=1"; }
# The world of the audit of 2026-11-26: the shared pool's runner (1), whose last job was 2026-11-25T09:43Z; the build
# pool's (2), paused since 2026-11-25; the deploy and cluster pools' (3, 4), paused since #66, one never used here; and
# the in-cluster infra runner (5), busy, which is not a pool's. The group runners come over two pages.
world() {
  jq -n --arg l1 "$(last 1)" --arg l2 "$(last 2)" --arg l3 "$(last 3)" --arg l4 "$(last 4)" \
    --arg r1 "$(running 1)" --arg r2 "$(running 2)" --arg r3 "$(running 3)" --arg r4 "$(running 4)" \
    --argjson j1 "$(job 101 2026-11-25T09:43:00.123Z success)" --argjson j2 "$(job 102 2026-11-24T20:00:00.000Z failed)" \
    --argjson j4 "$(job 104 2026-11-16T08:00:00.000Z success)" '{
    "GET /runners?type=group_type&per_page=100&page=1": {body: [{id: 1, description: "tacplus-ci shared (tacplus-dev/cloud: runner-manager in the ci project)"},
      {id: 5, description: "tacplus-dev infra (tacplus-dev/cloud: the cluster, ci namespace, normal pool; protected refs; cloud, cluster and deploy pipelines)"}], next: "2"},
    "GET /runners?type=group_type&per_page=100&page=2": {body: [{id: 2, description: "tacplus-ci build (tacplus-dev/cloud: runner-manager in the ci project)"}]},
    "GET /runners?type=project_type&per_page=100&page=1": {body: [{id: 3, description: "tacplus-ci deploy (tacplus-dev/cloud: runner-manager in the ci project)"},
      {id: 4, description: "tacplus-ci cluster (tacplus-dev/cloud: runner-manager in the ci project)"}]},
    ($l1): {body: [$j1]}, ($l2): {body: [$j2]}, ($l3): {body: []}, ($l4): {body: [$j4]},
    ($r1): {body: []}, ($r2): {body: []}, ($r3): {body: []}, ($r4): {body: []}
  }' > "$STUB_GITLAB/api.json"
}
# set KEY JSON: the stub's answer to KEY.
set_answer() { jq --arg k "$1" --argjson a "$2" '.[$k] = $a' "$STUB_GITLAB/api.json" > "$work/api.next" && mv "$work/api.next" "$STUB_GITLAB/api.json"; }

world
if run; then
  ok "the four pools' runners idle for 24 hours: passes"
else
  fail "idle pools' runners: $(cat "$work/out")"
fi
said "runner 1 (tacplus-ci shared" && said "job 101 (tacplus-dev/looper), success, created 2026-11-25T09:43:00.123Z" &&
  said "runner 3 (tacplus-ci deploy" && said "no job" && said "every tacplus-ci pool's runner (4) idle for 24 hours" &&
  ok "it says each runner's last job, or none" || fail "what it says: $(cat "$work/out")"
called "GET /runners?type=group_type&per_page=100&page=2" && ! grep -q '^GET /runners/5/' "$STUB_GITLAB/calls" &&
  ok "the pools' runners alone, over pages: not the in-cluster infra runner" || fail "the calls: $(cat "$STUB_GITLAB/calls")"
grep -qxF 'PRIVATE-TOKEN: glpat-the-token' "$STUB_GITLAB/headers" && ! grep -q glpat "$STUB_GITLAB/calls" "$work/out" &&
  ok "the token goes in a header file only" || fail "the token: headers $(cat "$STUB_GITLAB/headers")"

world
set_answer "$(last 1)" "{\"body\": [$(job 111 2026-11-26T10:00:00Z success)]}"
if run; then fail "a job within the 24 hours: passed: $(cat "$work/out")"; else
  said "runner 1 (tacplus-ci shared" && said "job 111" && said "not idle" &&
    ok "a job created within the 24 hours: fails, naming its runner and job" || fail "a recent job: $(cat "$work/out")"
fi

world
set_answer "$(running 4)" "{\"body\": [$(job 114 2026-11-16T07:00:00Z running)]}"
if run; then fail "a running job: passed: $(cat "$work/out")"; else
  said "runner 4 (tacplus-ci cluster" && said "job 114" && ok "a job running: fails" || fail "a running job: $(cat "$work/out")"
fi

world
set_answer "$(last 2)" '{"status": 500, "body": {"message": "500 Internal Server Error"}}'
if run; then fail "a failed call: passed: $(cat "$work/out")"; else
  said "HTTP 500" && ok "a failed call: fails, saying it" || fail "a failed call: $(cat "$work/out")"
fi

world
set_answer "GET /runners?type=group_type&per_page=100&page=1" '{"body": [{"id": 5, "description": "tacplus-dev infra"}]}'
set_answer "GET /runners?type=project_type&per_page=100&page=1" '{"body": []}'
if run && said "no tacplus-ci pool's runner is registered"; then
  ok "no pool's runner left (after the gitlab stack's apply): passes, saying so"
else
  fail "no pool's runner: $(cat "$work/out")"
fi

world
GITLAB_TOKEN='' run && fail "without a token: passed" || { said "no GITLAB_TOKEN" && ok "without a token: refused" || fail "without a token: $(cat "$work/out")"; }

[ "$failed" = 0 ] && echo "idle_runners_test: all passed" || { echo "idle_runners_test: failed"; exit 1; }
