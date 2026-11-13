#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The drift job's pool check (#53): why a runner pool makes no VM, where a report can read it. Only the pipeline
# reads the ci project's instance groups; on 2026-11-13 the build pool made no VM from 10:25Z, every build stalled,
# and nobody else could see why (a zone out of spot t2a, a quota, a recreation stuck in its zone). So each group of
# PROJECT, zonal or regional, is read: each VM its group cannot make (a creation or a recreation whose last attempt
# failed: its action, its status, the error) and each stopped VM it keeps; the group's errors of the last 24 hours
# (Compute's own list of them), counted by error and zone, with the last one's time and message; then each quota of
# REGION and of the project that is 80% used or more. One line per finding, "pools <project>: ...", on stdout; a read
# it cannot make is a finding too. It only reads, and exits 0 when it finds something: ci/drift.sh files what it
# prints. POOLS_NOW (an ISO 8601 time, default now) is when the 24 hours end, for tests/pools_test.sh.
#
#   ci/pools.sh PROJECT REGION    # needs gcloud (signed in: ci/lib.sh ci_gcp), jq and date
set -uo pipefail
[ $# = 2 ] || { echo "usage: ci/pools.sh PROJECT REGION" >&2; exit 2; }
project=$1 region=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
now=$(date -u -d "${POOLS_NOW:-now}" +%s) || exit 2
since=$((now - 86400))
say() { echo "pools $project: $*"; }
# read WHAT FILE GCLOUD-ARGS...: gcloud's JSON into FILE, or a finding saying what it cannot read.
read_json() {
  local what=$1 file=$2; shift 2
  gcloud "$@" --project="$project" --format=json < /dev/null > "$file" 2> "$tmp/err" && return
  say "cannot $what: $(grep -m1 '^ERROR' "$tmp/err" || head -c 300 "$tmp/err" | tr '\n' ' ')"
  return 1
}

if read_json "list the groups" "$tmp/groups.json" compute instance-groups managed list; then
  jq -r '.[] | "\(.name) \(if .region then "--region=\(.region | sub(".*/"; ""))" else "--zone=\(.zone | sub(".*/"; ""))" end)"' "$tmp/groups.json" > "$tmp/groups"
  while read -r group where; do
    if read_json "list the VMs of $group" "$tmp/vms.json" compute instance-groups managed list-instances "$group" "$where"; then
      jq -r --arg g "$group" '.[] | (.lastAttempt.errors.errors // [])[0] as $e | (.instanceStatus // "") as $s
        | select($e != null or ($s | IN("STOPPED", "TERMINATED", "SUSPENDED")))
        | (.instance | capture("/zones/(?<z>[^/]+)/instances/(?<n>[^/]+)$")) as $vm
        | "group \($g): VM \($vm.n) in \($vm.z) is \(.currentAction // "NONE")\(if $s != "" then " (\($s))" else "" end)\(if $e then ": \($e.code): \($e.message)" else "" end)"' \
        "$tmp/vms.json" | while IFS= read -r line; do say "$line"; done
    fi
    if read_json "list the errors of $group" "$tmp/errors.json" compute instance-groups managed list-errors "$group" "$where"; then
      jq -r --arg g "$group" --argjson since "$since" '
        def epoch: capture("^(?<t>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
          | (.t + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else (.z[0:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end);
        [.[] | (.timestamp | epoch) as $at | select($at >= $since)
          | {at: $at, code: .error.code, message: .error.message, zone: ((.instanceActionDetails.instance // "") | capture("/zones/(?<z>[^/]+)/").z // "?")}]
        | group_by([.code, .zone])[] | max_by(.at) as $last
        | "group \($g): \(length) error\(if length > 1 then "s" else "" end) since \($since | todate), the last at \($last.at | todate): \($last.code) in \($last.zone): \($last.message)"' \
        "$tmp/errors.json" | while IFS= read -r line; do say "$line"; done
    fi
  done < "$tmp/groups"
fi

# usage FILE [WHERE]: each quota of FILE 80% used or more.
usage() { jq -r --arg w "${2:-}" '.quotas[]? | select(.limit > 0 and .usage >= 0.8 * .limit)
  | "quota \(.metric)\(if $w != "" then " in \($w)" else "" end): \(.usage | floor) of \(.limit | floor) used"' "$1" | while IFS= read -r line; do say "$line"; done; }
read_json "read the quotas of $region" "$tmp/region.json" compute regions describe "$region" && usage "$tmp/region.json" "$region"
read_json "read the project's quotas" "$tmp/project.json" compute project-info describe && usage "$tmp/project.json"
exit 0
