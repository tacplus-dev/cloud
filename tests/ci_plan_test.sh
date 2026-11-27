#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Plans the ci stack with its real providers (our google build) against a stub API (tests/stubapi), from the state the
# runner manager is in before #113's apply: tests/fixtures/ci/manager.tfstate, runner-manager-d510c62b as #46 and #48
# made it, create_before_destroy and destroy = false, which OpenTofu keeps in the state (its skip_destroy). The
# stack's tests plan from an empty state, with mock providers: they never see what the state holds, and there a
# resource taken out of the configuration whose state says destroy = false is forgotten, not destroyed, so the manager
# would bill on outside every state. So: the plan destroys the manager (its removed block, destroy = true); ci/policy.sh
# admits it; it only reads; and the stack without that block forgets the manager, the trap the block is for. The fixture
# is built from the Compute and Resource Manager APIs' documented answers, not recorded. Needs bin/ (ci/tools.sh), go,
# jq.
#
#   tests/ci_plan_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
source "$here/ci/tofurc.sh"
work=$(mktemp -d)
stub=''
trap '[ -n "$stub" ] && kill "$stub" 2>/dev/null; rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

go build -o "$work/stubapi" "$here/tests/stubapi/main.go" || { echo "FAIL cannot build tests/stubapi"; exit 1; }
"$work/stubapi" "$here/tests/fixtures/ci/api.json" "$work/requests" "$work/addr" &
stub=$!
for _ in $(seq 50); do [ -s "$work/addr" ] && break; sleep 0.1; done
[ -s "$work/addr" ] || { echo "FAIL the stub API does not listen"; exit 1; }
api=http://$(cat "$work/addr")

# The stack as it is, but its state local, from the fixture, and its provider on the stub.
cp -r "$here/stacks" "$here/modules" "$work/" && ln -s "$here/bin" "$work/bin"
find "$work/stacks" -name .terraform -prune -exec rm -rf {} +
stack=$work/stacks/ci
cat > "$stack/stub_override.tf" <<EOF
terraform {
  backend "local" {}
}
provider "google" {
  access_token                        = "stub"
  resource_manager_custom_endpoint    = "$api/rm/v1/"
  resource_manager_v3_custom_endpoint = "$api/rm/v3/"
  cloud_billing_custom_endpoint       = "$api/billing/v1/"
  compute_custom_endpoint             = "$api/compute/v1/"
}
EOF
# Nothing but the stub: a call to Google itself fails.
plan() {
  (cd "$stack" && rm -f p.tfplan && cp "$here/tests/fixtures/ci/manager.tfstate" terraform.tfstate &&
    HTTPS_PROXY=http://127.0.0.1:1 tofu plan -input=false -no-color -var parent_folder=111111111111 -out=p.tfplan > "$work/plan.txt" 2>&1)
}
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) ||
  { echo "FAIL init: $(cat "$work/init.txt")"; exit 1; }

if plan; then
  ok "the stack plans from the runner manager's state"
  (cd "$stack" && tofu show -json p.tfplan) > "$work/plan.json"
  changes() { jq -c --arg a "$1" '[.resource_changes[] | select(.address == $a) | {deposed, actions: .change.actions}] | sort_by(.deposed)' "$work/plan.json"; }
  [ "$(changes module.ci.google_compute_instance.manager)" = '[{"deposed":null,"actions":["delete"]}]' ] &&
    ok "the manager: destroyed, not forgotten, though its state says destroy = false (#113)" ||
    fail "the manager: $(changes module.ci.google_compute_instance.manager)"
  [ -z "$(jq -r '.resource_changes[] | select(.change.actions == ["forget"]) | .address' "$work/plan.json")" ] &&
    ok "nothing forgotten" || fail "the plan forgets: $(jq -r '.resource_changes[] | select(.change.actions == ["forget"]) | .address' "$work/plan.json")"
  "$here/ci/policy.sh" plan "$work/plan.json" > "$work/policy.txt" 2>&1 && ok "ci/policy.sh admits the plan" ||
    fail "ci/policy.sh refuses the plan: $(cat "$work/policy.txt")"
else
  fail "the stack does not plan from the runner manager's state: $(grep -A4 '^Error' "$work/plan.txt" | cut -c1-400)"
fi
! grep -v '^GET ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# The stack without the manager's removed block: the manager is forgotten (its state's destroy = false), and its VM and
# disk would bill on outside every state. The test sees what the block guards against.
awk '/^removed \{/ { skip = 1 } !skip { print } skip && /^\}/ { skip = 0 }' "$here/modules/projects/ci/main.tf" > "$work/modules/projects/ci/main.tf"
grep -qE '^removed \{' "$work/modules/projects/ci/main.tf" && fail "the test cannot remove the removed block from its copy"
if plan; then
  (cd "$stack" && tofu show -json p.tfplan) > "$work/plan.json"
  [ "$(changes module.ci.google_compute_instance.manager)" = '[{"deposed":null,"actions":["forget"]}]' ] &&
    ok "without its removed block, the manager is forgotten, not destroyed: the trap the block is for" ||
    fail "without its removed block, the manager: $(changes module.ci.google_compute_instance.manager)"
else
  fail "the stack without the removed block does not plan: $(grep -A4 '^Error' "$work/plan.txt" | cut -c1-400)"
fi

[ "$failed" = 0 ] && echo "ci_plan_test: all passed" || { echo "ci_plan_test: failed"; exit 1; }
