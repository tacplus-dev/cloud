#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Plans the ci stack with its real providers (our google build) against a stub API (tests/stubapi), from the state the
# crashed apply of 2026-11-12 left (#47): tests/fixtures/ci/deposed.tfstate, the manager runner-manager as the config
# before #46 made it (its stored dependencies name terraform_data.manager_config, its old replace_triggered_by), a
# deposed object of it (01338cc8), and terraform_data.manager_config, which #46 removed. The stack's tests plan from an
# empty state, with mock providers: they never see what the state adds to the graph, and there the deposed manager's
# destroy (create_before_destroy), the removed terraform_data's destroy and the pools' templates and groups closed a
# cycle, and plan:ci failed. So: the plan has no cycle; it forgets terraform_data.manager_config (it has no remote
# object) and destroys nothing of it; it destroys the deposed manager and replaces runner-manager create-before-destroy,
# by runner-manager-<hash>; ci/policy.sh admits it; it only reads; and the stack with the terraform_data destroyed
# again, as #46 left it, fails with the cycle, as plan:ci did. The fixture is built from the Compute and Resource
# Manager APIs' documented answers, not recorded. Needs bin/ (ci/tools.sh), go, jq.
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

# The stack as it is, but its state local, from the fixture, and its provider on the stub; bin/manager the tools job's.
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
  (cd "$stack" && rm -f p.tfplan && cp "$here/tests/fixtures/ci/deposed.tfstate" terraform.tfstate &&
    HTTPS_PROXY=http://127.0.0.1:1 tofu plan -input=false -no-color -var parent_folder=111111111111 -out=p.tfplan > "$work/plan.txt" 2>&1)
}
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) ||
  { echo "FAIL init: $(cat "$work/init.txt")"; exit 1; }

if plan; then
  ok "the stack plans from a deposed manager and the removed terraform_data.manager_config, with no cycle (#47)"
  (cd "$stack" && tofu show -json p.tfplan) > "$work/plan.json"
  changes() { jq -c --arg a "$1" '[.resource_changes[] | select(.address == $a) | {deposed, actions: .change.actions}] | sort_by(.deposed)' "$work/plan.json"; }
  [ "$(changes module.ci.terraform_data.manager_config)" = '[{"deposed":null,"actions":["forget"]}]' ] &&
    ok "terraform_data.manager_config: forgotten, not destroyed (it has no remote object)" ||
    fail "terraform_data.manager_config: $(changes module.ci.terraform_data.manager_config)"
  [ "$(changes module.ci.google_compute_instance.manager)" = '[{"deposed":null,"actions":["create","delete"]},{"deposed":"01338cc8","actions":["delete"]}]' ] &&
    ok "the manager: replaced create-before-destroy, and the deposed one destroyed" ||
    fail "the manager: $(changes module.ci.google_compute_instance.manager)"
  jq -e '.resource_changes[] | select(.address == "module.ci.google_compute_instance.manager" and .deposed == null) | .change.after.name | test("^runner-manager-[0-9a-f]{8}$")' "$work/plan.json" > /dev/null &&
    ok "the new manager is runner-manager-<its build's hash> (#46)" ||
    fail "the new manager's name: $(jq -c '.resource_changes[] | select(.address == "module.ci.google_compute_instance.manager") | .change.after.name' "$work/plan.json")"
  "$here/ci/policy.sh" plan "$work/plan.json" > "$work/policy.txt" 2>&1 && ok "ci/policy.sh admits the plan" ||
    fail "ci/policy.sh refuses the plan: $(cat "$work/policy.txt")"
else
  fail "the stack does not plan from a deposed manager and the removed terraform_data.manager_config: $(grep -A4 '^Error' "$work/plan.txt" | cut -c1-400)"
fi
! grep -v '^GET ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# The stack as #46 left it (b15a1c9): terraform_data.manager_config destroyed, not forgotten. The plan fails with the
# cycle plan:ci met (job 17961392097), so the test sees what it guards against.
awk '/^removed \{/ { skip = 1 } !skip { print } skip && /^\}/ { skip = 0 }' "$here/modules/projects/ci/runners.tf" > "$work/modules/projects/ci/runners.tf"
grep -q '^removed {' "$work/modules/projects/ci/runners.tf" && fail "the test cannot remove the removed block from its copy"
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) || fail "init: $(cat "$work/init.txt")"
! plan && grep '^Error: Cycle: ' "$work/plan.txt" | grep -F 'module.ci.google_compute_instance.manager (destroy deposed 01338cc8)' |
  grep -qF 'module.ci.terraform_data.manager_config (destroy)' &&
  ok "the removed terraform_data destroyed, as after #46: the cycle, as on plan:ci" || fail "as after #46: $(grep -E '^Error|^Plan:' "$work/plan.txt" | cut -c1-400)"

[ "$failed" = 0 ] && echo "ci_plan_test: all passed" || { echo "ci_plan_test: failed"; exit 1; }
