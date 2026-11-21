#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Plans the dev stack's quota preferences with their real provider (our google build) against a stub API
# (tests/stubapi), from a state that holds them (tests/fixtures/dev-quotas): their calls count against tacplus-dev, the
# project they are of, whose module enables the Cloud Quotas API, never the caller's (#90: apply:dev's first create
# was refused, the API off in the pipeline's own tacplus-bootstrap, which bootstrap/bootstrap.sh enables only when it
# is run again by hand). The stack's tests plan with mock providers, which never call: here the refresh of each
# preference asks the stub, which logs the project the request names (X-Goog-User-Project). The plan only reads; and
# the stack as #88 left it (no billing project on the preferences' provider) names none, so the test sees what it
# guards against. The fixture is built from the Cloud Quotas, Compute and Resource Manager APIs' documented answers,
# not recorded. Needs bin/ (ci/tools.sh), go, jq.
#
#   tests/quotas_plan_test.sh
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
"$work/stubapi" "$here/tests/fixtures/dev-quotas/api.json" "$work/requests" "$work/addr" &
stub=$!
for _ in $(seq 50); do [ -s "$work/addr" ] && break; sleep 0.1; done
[ -s "$work/addr" ] || { echo "FAIL the stub API does not listen"; exit 1; }
api=http://$(cat "$work/addr")

# The stack as it is, but its state local, from the fixture, and both its google providers on the stub.
cp -r "$here/stacks" "$here/modules" "$work/" && ln -s "$here/bin" "$work/bin"
find "$work/stacks" -name .terraform -prune -exec rm -rf {} +
stack=$work/stacks/dev
endpoints="access_token                        = \"stub\"
  resource_manager_custom_endpoint    = \"$api/rm/v1/\"
  resource_manager_v3_custom_endpoint = \"$api/rm/v3/\"
  cloud_billing_custom_endpoint       = \"$api/billing/v1/\"
  compute_custom_endpoint             = \"$api/compute/v1/\"
  cloud_quotas_custom_endpoint        = \"$api/quotas/v1/\""
cat > "$stack/stub_override.tf" <<EOF
terraform {
  backend "local" {}
}
provider "google" {
  $endpoints
}
provider "google" {
  alias = "quotas"
  $endpoints
}
EOF
quotas='module.dev.google_cloud_quotas_quota_preference.pools'
# Nothing but the stub: a call to Google itself fails. The preferences alone, and what they depend on.
plan() {
  : > "$work/requests"
  (cd "$stack" && rm -f p.tfplan && cp "$here/tests/fixtures/dev-quotas/quotas.tfstate" terraform.tfstate &&
    HTTPS_PROXY=http://127.0.0.1:1 tofu plan -input=false -no-color -var parent_folder=111111111111 \
      -var quota_contact=jody@example.com -target="$quotas" -out=p.tfplan > "$work/plan.txt" 2>&1)
}
reads() { grep -E "^GET /quotas/v1/projects/tacplus-dev/locations/global/quotaPreferences/dev-pools-(c4a-cpus|hdb-gb)-us-central1 200" "$work/requests"; }
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) ||
  { echo "FAIL init: $(cat "$work/init.txt")"; exit 1; }

if plan; then
  ok "the stack plans its quota preferences from a state that holds them"
  [ "$(reads | wc -l)" = 2 ] && ! reads | grep -qv ' user-project=tacplus-dev$' &&
    ok "both quota preferences' calls count against tacplus-dev (X-Goog-User-Project), not the caller's project (#90)" ||
    fail "the quota preferences' calls: $(reads | tr '\n' ';') (all requests: $(tr '\n' ';' < "$work/requests"))"
  ! grep '^GET ' "$work/requests" | grep -v '^GET /quotas/' | grep -q ' user-project=' &&
    ok "the stack's other calls name no project: only the preferences' provider counts its calls against tacplus-dev" ||
    fail "other calls name a project: $(grep -v '^GET /quotas/' "$work/requests" | grep ' user-project=' | tr '\n' ';')"
else
  fail "the stack does not plan its quota preferences: $(grep -A4 '^Error' "$work/plan.txt" | cut -c1-400)"
fi
! grep -v '^GET ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# The stack as #88 left it (2b6258f): the preferences' provider without a billing project, whose calls count against
# the caller's, tacplus-bootstrap (apply:dev, job 18249246303).
sed -i -E '/^ *(user_project_override|billing_project) *=/d' "$stack/main.tf"
grep -qE '^ *(user_project_override|billing_project) *=' "$stack/main.tf" && fail "the test cannot remove the billing project from its copy"
if plan; then
  [ "$(reads | wc -l)" = 2 ] && ! reads | grep -q ' user-project=' &&
    ok "without the billing project, as after #88: the preferences' calls name no project (the caller's counts)" ||
    fail "as after #88: $(reads | tr '\n' ';')"
else
  fail "as after #88, the stack does not plan: $(grep -A4 '^Error' "$work/plan.txt" | cut -c1-400)"
fi

[ "$failed" = 0 ] && echo "quotas_plan_test: all passed" || { echo "quotas_plan_test: failed"; exit 1; }
