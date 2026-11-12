#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# OpenTofu for one stack (stacks/STACK), as the pipeline runs it. The plan job saves the plan; the apply job applies
# exactly that saved plan, and nothing else: it refuses a plan file whose SHA-256 is not the one the plan job
# recorded, and OpenTofu itself refuses a saved plan that is stale (the state changed since). Every init is
# -lockfile=readonly: the providers are the lock file's, by hash, or nothing runs.
#
#   ci/tofu.sh plan STACK     # plans/STACK.tfplan, and beside it .json (tofu show -json), .txt (what a person
#                             # reads), .sha256; refused if ci/policy.sh refuses the plan
#   ci/tofu.sh apply STACK    # applies plans/STACK.tfplan, its log in plans/STACK.apply.log
#   ci/tofu.sh drift STACK    # plans without saving or locking; what differs appended to $PLAN_SUMMARY; exit 0
#
# A check the plan finds failing (a check block's assert, a condition: the anthropic stack's bootstrap rule, #34) does
# not stop a plan, as OpenTofu has it: the plan says it, and the drift lists it as drift.
#
# Needs bin/tofu (ci/tools.sh), jq, sha256sum; the credentials (ci/lib.sh: ci_gcp, and ci_gitlab for gitlab).
# PLANS sets where the plans go (default plans/ at the repository's root).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
source "$here/ci/tofurc.sh"
die() { echo "tofu.sh: $*" >&2; exit 1; }
[ $# = 2 ] || die "usage: ci/tofu.sh plan|apply|drift STACK"
cmd=$1 stack=$2
[[ $stack =~ ^[a-z][a-z0-9-]*$ ]] && [ -f "$here/stacks/$stack/versions.tf" ] || die "no stack [$stack] (stacks/*)"
plans=${PLANS:-$here/plans}
plan=$plans/$stack.tfplan
cd "$here/stacks/$stack"

init() { tofu init -input=false -lockfile=readonly -no-color >/dev/null || die "init of $stack failed"; }

# summary JSON: one line per change, "<stack>: <action> <address>".
summary() {
  jq -r --arg s "$stack" '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | "\($s): \(.change.actions | join("+")) \(.address)"' "$1"
}
# failed JSON: one line per failing check, "<stack>: check <address> failed: <its messages>".
failed() {
  jq -r --arg s "$stack" '.checks[]? | .instances[]? | select(.status == "fail" or .status == "error")
    | "\($s): check \(.address.to_display) failed: \([.problems[]?.message] | join("; "))"' "$1"
}

case $cmd in
  plan)
    mkdir -p "$plans"
    init
    tofu plan -input=false -lock-timeout=10m -no-color -out="$plan" >/dev/null || die "plan of $stack failed"
    tofu show -json "$plan" > "$plans/$stack.json"
    tofu show -no-color "$plan" > "$plans/$stack.txt"
    "$here/ci/policy.sh" plan "$plans/$stack.json" || die "the plan of $stack is refused (ci/policy.sh): nothing will be applied"
    (cd "$plans" && sha256sum "$stack.tfplan" > "$stack.tfplan.sha256")
    cat "$plans/$stack.txt"
    failed "$plans/$stack.json"
    n=$(summary "$plans/$stack.json" | wc -l)
    echo "tofu.sh: $stack: $n change(s), saved as plans/$stack.tfplan ($(cut -c1-16 "$plans/$stack.tfplan.sha256"))"
    ;;
  apply)
    [ -f "$plan" ] && [ -f "$plan.sha256" ] || die "no saved plan plans/$stack.tfplan: apply runs only the plan job's"
    (cd "$plans" && sha256sum -c --quiet "$stack.tfplan.sha256") || die "plans/$stack.tfplan is not the plan the plan job saved"
    init
    echo "tofu.sh: applying plans/$stack.tfplan ($(cut -c1-16 "$plan.sha256")), the plan job's"
    # Its log beside the plan, in the apply job's artifacts (#46): OpenTofu's core at DEBUG, which says how a provider
    # that stops answering ended (a panic, a signal), and the providers at INFO, not DEBUG, which would log every
    # request's body (the gitlab stack's are secret values).
    TF_LOG_CORE=DEBUG TF_LOG_PROVIDER=INFO TF_LOG_PATH="$plans/$stack.apply.log" \
      tofu apply -input=false -lock-timeout=10m -no-color "$plan"
    ;;
  drift)
    : "${PLAN_SUMMARY:?PLAN_SUMMARY is not set}"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    init
    rc=0
    tofu plan -input=false -lock=false -no-color -detailed-exitcode -out="$tmp/plan" >/dev/null || rc=$?
    case $rc in
      0|2) tofu show -json "$tmp/plan" > "$tmp/plan.json"
           { summary "$tmp/plan.json"; failed "$tmp/plan.json"; } > "$tmp/drift"
           if [ -s "$tmp/drift" ]; then tee -a "$PLAN_SUMMARY" < "$tmp/drift"; else echo "tofu.sh: $stack: no drift"; fi ;;
      *) echo "$stack: the plan failed (exit $rc): see the job's log" | tee -a "$PLAN_SUMMARY" ;;
    esac
    ;;
  *) die "usage: ci/tofu.sh plan|apply|drift STACK" ;;
esac
