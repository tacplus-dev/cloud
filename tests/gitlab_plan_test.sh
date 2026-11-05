#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Plans the gitlab stack with its real providers (our gitlab build, the locked google) against a stub API
# (tests/stubapi) that answers as gitlab.com and Google do for the settings the hub made before the first pipeline
# (README, Before the first pipeline): tests/fixtures/gitlab/api.json. Mock providers cannot see what #17 broke:
# gitlab.com says it is an Enterprise instance (/metadata), on Free too, and there the provider refuses a branch
# protection's push_access_level and merge_access_level at plan; and an import by the project's path, whose state
# then differs from the config's numeric project ID, replaces what it adopts. So: the plan succeeds; it adopts main's
# protection (Maintainers push and merge, no force push) and GCP_WIF_PROVIDER with no change; it replaces, changes
# or deletes nothing; the old form of the protection is refused, as gitlab.com refused it. The fixture is built from
# the GitLab and Google APIs' documented answers, not recorded: the looper's token cannot read tacplus-dev/cloud's
# settings. Needs bin/ (ci/tools.sh), go, jq, and the registry for the google provider (as ci/checks.sh's init).
#
#   tests/gitlab_plan_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
source "$here/ci/tofurc.sh"
work=$(mktemp -d)
stub=
trap '[ -n "$stub" ] && kill "$stub" 2>/dev/null; rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

go build -o "$work/stubapi" "$here/tests/stubapi/main.go" || { echo "FAIL cannot build tests/stubapi"; exit 1; }
"$work/stubapi" "$here/tests/fixtures/gitlab/api.json" "$work/requests" "$work/addr" &
stub=$!
for _ in $(seq 50); do [ -s "$work/addr" ] && break; sleep 0.1; done
[ -s "$work/addr" ] || { echo "FAIL the stub API does not listen"; exit 1; }
api=http://$(cat "$work/addr")

# The stack as it is, but its state local and its providers on the stub.
cp -r "$here/stacks" "$here/modules" "$work/"
find "$work/stacks" -name .terraform -prune -exec rm -rf {} +
stack=$work/stacks/gitlab
cat > "$stack/stub_override.tf" <<EOF
terraform {
  backend "local" {}
}
provider "google" {
  access_token                     = "stub"
  resource_manager_custom_endpoint = "$api/rm/v1/"
  cloud_billing_custom_endpoint    = "$api/billing/v1/"
  secret_manager_custom_endpoint   = "$api/sm/v1/"
}
provider "gitlab" {
  token    = "stub"
  base_url = "$api/api/v4/"
}
EOF
plan() { (cd "$stack" && rm -f p.tfplan && tofu plan -input=false -no-color -out=p.tfplan > "$work/plan.txt" 2>&1); }
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) ||
  { echo "FAIL init: $(cat "$work/init.txt")"; exit 1; }

if plan; then
  ok "the stack plans against gitlab.com's answers (an Enterprise instance)"
  (cd "$stack" && tofu show -json p.tfplan) > "$work/plan.json"
  change() { jq -c --arg a "$1" '.resource_changes[] | select(.address == $a) | .change' "$work/plan.json"; }
  protection=$(change 'module.gitlab.gitlab_branch_protection.branch["tacplus-dev/cloud:main"]')
  [ "$(jq -c '.actions' <<< "$protection")" = '["no-op"]' ] && [ "$(jq -r '.importing.id' <<< "$protection")" = 4001:main ] &&
    ok "main's protection: adopted (by the project's ID) with no change" || fail "main's protection: $protection"
  jq -e '.after | ([.allowed_to_push[] | [.access_level, .user_id, .group_id, .deploy_key_id]] == [["maintainer", null, null, null]]) and
    ([.allowed_to_merge[] | [.access_level, .user_id, .group_id]] == [["maintainer", null, null]]) and .allow_force_push == false and .push_access_level == null and .merge_access_level == null' <<< "$protection" > /dev/null &&
    ok "main: Maintainers push and merge, nobody force-pushes" || fail "main's protection after: $protection"
  variable=$(change 'module.gitlab.gitlab_project_variable.variable["tacplus-dev/cloud:GCP_WIF_PROVIDER"]')
  [ "$(jq -c '.actions' <<< "$variable")" = '["no-op"]' ] && [ "$(jq -r '.importing.id' <<< "$variable")" = '4001:GCP_WIF_PROVIDER:*' ] &&
    ok "GCP_WIF_PROVIDER: adopted (by the project's ID) with no change" || fail "GCP_WIF_PROVIDER: $variable"
  others=$(jq -r '.resource_changes[] | select(.change.actions != ["create"] and .change.actions != ["no-op"]) | "\(.address) \(.change.actions)"' "$work/plan.json")
  [ -z "$others" ] && ok "nothing replaced, changed or deleted: adoptions and creates only" || fail "the plan also: $others"
  member=$(change 'module.gitlab.gitlab_project_membership.member["tacplus-dev/build:tacplus-looper-bot"]')
  jq -e '.actions == ["create"] and .after.access_level == "reporter" and .after.project == "4003" and .after.user_id == 2002' <<< "$member" > /dev/null &&
    ok "tacplus-looper-bot: a Reporter of tacplus-dev/build (#12)" || fail "the membership: $member"
else
  fail "the stack does not plan against gitlab.com's answers: $(grep -A4 '^Error' "$work/plan.txt")"
fi
! grep -v '^GET ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# The form gitlab.com refused (#17): the fixture makes the provider see an Enterprise instance, so the plan fails here
# as it failed there.
sed -i 's/allowed_to_push *= \[{ access_level = "maintainer" }\]/push_access_level = "maintainer"/; s/allowed_to_merge *= \[{ access_level = "maintainer" }\]/merge_access_level = "maintainer"/' \
  "$work/modules/gitlab/main.tf"
grep -q 'push_access_level = "maintainer"' "$work/modules/gitlab/main.tf" || fail "the test cannot write the old form into its copy"
! plan && grep -qF 'feature unavailable `push_access_level`' "$work/plan.txt" && grep -qF 'feature unavailable `merge_access_level`' "$work/plan.txt" &&
  ok "push_access_level and merge_access_level: refused, as on gitlab.com" || fail "the old form: $(tail -5 "$work/plan.txt")"

[ "$failed" = 0 ] && echo "gitlab_plan_test: all passed" || { echo "gitlab_plan_test: failed"; exit 1; }
