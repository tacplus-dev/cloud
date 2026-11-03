#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What no change here may do, checked twice: in the source on every push (the validate job), and in each saved
# plan before it is applied (ci/tofu.sh plan). Refused:
#   - a service-account key (google_service_account_key): every identity is keyless;
#   - allUsers or allAuthenticatedUsers, in any binding, member list or policy document: nothing is public;
#   - in the source only, what a commit does not fix, so that the same commit gives the same plan
#     (tacplus-dev/roadmap decisions/deterministic-deployments-2026-11-02.md): timestamp(), plantimestamp(),
#     uuid(), bcrypt(), and an image at :latest.
#
#   ci/policy.sh source DIR...      # every *.tf and *.tftpl under each DIR
#   ci/policy.sh plan PLAN.json...  # `tofu show -json` of saved plans: what they create or update
set -uo pipefail
die() { echo "policy: $*" >&2; exit 2; }
refused=0
refuse() { echo "policy: refused: $*" >&2; refused=1; }

source_check() {
  local dir f n line
  local -A why=(
    ['\bgoogle_service_account_key\b']="creates a service-account key (google_service_account_key)"
    ['\ballUsers\b']="names allUsers: nothing is public"
    ['\ballAuthenticatedUsers\b']="names allAuthenticatedUsers: nothing is public"
    ['\b(timestamp|plantimestamp|uuid|bcrypt)\(']="calls a function whose value no commit fixes (timestamp(), plantimestamp(), uuid(), bcrypt())"
    [':latest\b']="names an image at :latest: pin it by digest"
  )
  for dir in "$@"; do
    [ -d "$dir" ] || die "no such directory: $dir"
    while IFS= read -r -d '' f; do
      for re in "${!why[@]}"; do
        while IFS=: read -r n line; do
          [ -n "$n" ] && refuse "$f:$n: ${why[$re]}: ${line#"${line%%[![:space:]]*}"}"
        done < <(grep -nE "$re" "$f" 2>/dev/null)
      done
    done < <(find "$dir" -type d -name .terraform -prune -o -type f \( -name '*.tf' -o -name '*.tftpl' \) -print0 | sort -z)
  done
}

plan_check() {
  local p out
  for p in "$@"; do
    jq -e '.resource_changes | type == "array"' "$p" >/dev/null 2>&1 || { refuse "$p is not a plan (tofu show -json of a saved plan)"; continue; }
    out=$(jq -r '
      .resource_changes[]
      | select(.change.actions | any(. == "create" or . == "update"))
      | (select(.type == "google_service_account_key") | "\(.address) creates a service-account key"),
        (.address as $a | .change.after | paths(strings) as $p | getpath($p) as $v
         | ["allUsers", "allAuthenticatedUsers"][] as $who | select($v | test("\\b" + $who + "\\b"))
         | "\($a) grants \($who) (\($p | map(tostring) | join(".")))")' "$p") || { refuse "$p: cannot read its changes"; continue; }
    while IFS= read -r line; do [ -n "$line" ] && refuse "$p: $line"; done <<< "$out"
  done
}

mode=${1:-}
[ $# -ge 2 ] || die "usage: ci/policy.sh source DIR... | plan PLAN.json..."
shift
case $mode in
  source) source_check "$@" ;;
  plan) plan_check "$@" ;;
  *) die "usage: ci/policy.sh source DIR... | plan PLAN.json..." ;;
esac
[ "$refused" = 0 ] || exit 1
echo "policy: $mode: $# checked, nothing refused"
