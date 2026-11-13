#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/pools.sh, the drift job's pool check (#53), against a stub gcloud over JSON fixtures (tests/stub/pools,
# tests/fixtures/pools): of the runner pools' groups, zonal or regional, it reports each VM its group cannot make (its
# action, its status and its last attempt's error: a creation or a recreation stuck on capacity or quota) and each
# stopped one, then each group's errors of the last 24 hours, counted by error and zone with the last one's time and
# message, then each quota of the region and of the project that is 80% used or more; nothing for a VM still creating
# with no error, a running one, an older error, or a quota with room or none at all. It reports a read it cannot make,
# exits 0 when it finds something, and only reads. The drift job checks the ci project, in its region. Needs bash and jq.
#
#   tests/pools_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_POOLS=$here/tests/fixtures/pools STUB_LOG=$work/log PATH=$here/tests/stub/pools:$PATH
export POOLS_NOW=2026-11-13T12:00:00Z

check() { : > "$STUB_LOG"; "$here/ci/pools.sh" "$@" > "$work/out" 2> "$work/err"; }
reports() { # reports WHAT EXPECTED-LINE...: each line is exactly one line of the report
  local what=$1 line n; shift
  for line in "$@"; do
    n=$(grep -cxF -- "$line" "$work/out")
    [ "$n" = 1 ] || { fail "$what: [$line] is $n lines of: $(cat "$work/out" "$work/err")"; return; }
  done
  ok "$what"
}

zone_out="The zone 'projects/tacplus-ci/zones/us-central1-a' does not have enough resources available to fulfill the request."
quota_out="Quota 'T2A_CPUS' exceeded.  Limit: 24.0 in region us-central1."
check stalled us-central1 && ok "the check exits 0 when it finds something (drift reports, it does not fail)" ||
  fail "the check failed: $(cat "$work/err")"
reports "a recreation stuck on capacity" \
  "pools stalled: group runner-build-region: VM runner-build-1a2b in us-central1-a is RECREATING (TERMINATED): ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS: $zone_out"
reports "a creation stuck on quota" \
  "pools stalled: group runner-build-region: VM runner-build-3c4d in us-central1-f is CREATING: QUOTA_EXCEEDED: $quota_out"
reports "a stopped VM its group keeps" "pools stalled: group runner-shared: VM runner-shared-0003 in us-central1-b is NONE (STOPPED)"
reports "the group's errors of the last 24 hours, by error and zone" \
  "pools stalled: group runner-build-region: 2 errors since 2026-11-12T12:00:00Z, the last at 2026-11-13T10:45:00Z: ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS in us-central1-a: $zone_out" \
  "pools stalled: group runner-build-region: 1 error since 2026-11-12T12:00:00Z, the last at 2026-11-13T11:00:00Z: QUOTA_EXCEEDED in us-central1-f: $quota_out"
reports "a quota of the region, and of the project, 80% used or more" \
  "pools stalled: quota T2A_CPUS in us-central1: 24 of 24 used" "pools stalled: quota CPUS_ALL_REGIONS: 41 of 48 used"
[ "$(wc -l < "$work/out")" = 7 ] && ok "nothing else is reported (a VM creating with no error, running ones, an older error, quotas with room or none)" ||
  fail "the report is not those 7 lines: $(cat "$work/out")"
grep -vE '^gcloud compute (instance-groups managed (list|list-instances [a-z0-9-]+ --(region|zone)=[a-z0-9-]+|list-errors [a-z0-9-]+ --(region|zone)=[a-z0-9-]+)|regions describe [a-z0-9-]+|project-info describe) --project=[a-z-]+ --format=json$' "$STUB_LOG" &&
  fail "the check runs more than the reads" || ok "the check only reads"

check clean us-central1 && [ ! -s "$work/out" ] && ok "a pool that makes its VMs, with room: nothing reported" || fail "clean: $(cat "$work/out" "$work/err")"
check missing us-central1 && reports "a read it cannot make is reported" "pools missing: cannot list the groups: ERROR: (gcloud.compute) PERMISSION_DENIED: stub: no groups.json in missing" \
  "pools missing: cannot read the quotas of us-central1: ERROR: (gcloud.compute) PERMISSION_DENIED: stub: no region-us-central1.json in missing" \
  "pools missing: cannot read the project's quotas: ERROR: (gcloud.compute) PERMISSION_DENIED: stub: no project.json in missing"
"$here/ci/pools.sh" stalled > /dev/null 2>&1 && fail "no region: passed" || ok "no region: usage"

# The drift job checks the ci project, in the region, as modules/settings names them, after the DNS check.
# shellcheck source=ci/lib.sh
pools=$(ci_tmp=$work && source "$here/ci/lib.sh" && ci_pools)
[ "$pools" = "tacplus-ci us-central1" ] && ok "ci_pools: the ci project and the region modules/settings names" || fail "ci_pools: [$pools]"
grep -qF '"$here/pools.sh" $(ci_pools)' "$here/ci/drift.sh" && ok "drift runs the pool check on them" || fail "ci/drift.sh does not run ci/pools.sh on ci_pools"
exit "$failed"
