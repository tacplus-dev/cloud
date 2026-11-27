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
# protection (Maintainers push and merge, no force push) and GCP_WIF_PROVIDER with no change, and tacplus-dev/build's
# .gitlab-ci.yml, made tacplus-dev/looper's (#26); it creates the build trigger, its BUILD_TRIGGER_TOKEN, one nightly
# schedule that builds every pinned repository (#67, tacplus-dev/looper#164) and the two branch release schedules (#112), and tacplus-dev/cloud's hourly audit
# schedule, audit, which sets no variable (#77); it adopts tacplus-dev/build itself with no change, group runners on and shared
# runners off (#35), and with group runners off, as before the hub's hand change, it turns them on and changes nothing
# else; it creates the in-cluster infra runner, a tacplus-dev group runner of protected refs, unpaused since the
# switch-over (#66), and its token's version in the dev project's gitlab-runner-infra (#64), the kick runner, a
# tacplus-dev group runner of any ref, unpaused, and its token's version in gitlab-runner-kick (#81), the build-report
# runner, the same but tags arm64 and build-report, and its token's version in gitlab-runner-build-report (#93), the
# build-light runner, the same but tags arm64 and build-light, and its token's version in gitlab-runner-build-light
# (#100), the manager runner, the same but tags arm64 and manager, and its token's version in gitlab-runner-manager
# (#106), the nightly runner, the same but tags arm64 and build-nightly, and its token's version in
# gitlab-runner-nightly (#116), and tacplus-dev/build's job token allowlist entry for tacplus-dev/fleet-seatrials (#117),
# and no tacplus-ci pool's runner (#113); it replaces, changes or deletes nothing else; the old form of the protection is
# refused, as gitlab.com refused it. The fixture is built from the GitLab and Google APIs' documented answers, not recorded: the looper's token cannot
# read tacplus-dev/cloud's settings. Needs bin/ (ci/tools.sh), go, jq, and the registry for the google provider (as ci/checks.sh's init).
#
#   tests/gitlab_plan_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
source "$here/ci/tofurc.sh"
work=$(mktemp -d)
stub='' stub_before=''
trap '[ -n "$stub" ] && kill "$stub" 2>/dev/null; [ -n "$stub_before" ] && kill "$stub_before" 2>/dev/null; rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

go build -o "$work/stubapi" "$here/tests/stubapi/main.go" || { echo "FAIL cannot build tests/stubapi"; exit 1; }
"$work/stubapi" "$here/tests/fixtures/gitlab/api.json" "$work/requests" "$work/addr" &
stub=$!
for _ in $(seq 50); do [ -s "$work/addr" ] && break; sleep 0.1; done
[ -s "$work/addr" ] || { echo "FAIL the stub API does not listen"; exit 1; }
api=http://$(cat "$work/addr")
# A second stub (#35): tacplus-dev/build as it was before the hub's hand change, group runners off.
jq '."GET /api/v4/projects/4003".group_runners_enabled = false' "$here/tests/fixtures/gitlab/api.json" > "$work/before.json"
"$work/stubapi" "$work/before.json" "$work/requests-before" "$work/addr-before" &
stub_before=$!
for _ in $(seq 50); do [ -s "$work/addr-before" ] && break; sleep 0.1; done
[ -s "$work/addr-before" ] || { echo "FAIL the second stub API does not listen"; exit 1; }

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
  ci=$(change 'module.gitlab.gitlab_repository_file.build_ci["build"]')
  jq -e --rawfile f "$here/stacks/gitlab/files/build.gitlab-ci.yml" '.actions == ["update"] and .importing.id == "4003:main:.gitlab-ci.yml" and
    .after.content == $f and .after.branch == "main" and .after.project == "4003"' <<< "$ci" > /dev/null &&
    ok "tacplus-dev/build's .gitlab-ci.yml: adopted (by the project's ID) and made tacplus-dev/looper's ci/build.gitlab-ci.yml (#26)" ||
    fail "tacplus-dev/build's .gitlab-ci.yml: $(jq -c 'del(.before, .after)' <<< "$ci")"
  others=$(jq -r '.resource_changes[] | select(.change.actions != ["create"] and .change.actions != ["no-op"])
    | select(.address != "module.gitlab.gitlab_repository_file.build_ci[\"build\"]") | "\(.address) \(.change.actions)"' "$work/plan.json")
  [ -z "$others" ] && ok "nothing else replaced, changed or deleted: adoptions and creates only" || fail "the plan also: $others"
  trigger=$(change 'module.gitlab.gitlab_pipeline_trigger.build["build"]')
  variable=$(change 'module.gitlab.gitlab_project_variable.build_trigger["build"]')
  jq -e '.actions == ["create"] and .after.project == "4003"' <<< "$trigger" > /dev/null &&
    jq -e '.actions == ["create"] and .after.project == "88136765" and .after.key == "BUILD_TRIGGER_TOKEN" and .after.protected and .after.masked and .after_unknown.value' <<< "$variable" > /dev/null &&
    ok "a trigger of tacplus-dev/build, its token the looper project's protected, masked BUILD_TRIGGER_TOKEN (#26)" ||
    fail "the build trigger: $trigger; its variable: $(jq -c 'del(.before)' <<< "$variable")"
  # tacplus's gates job's size (#82, tacplus-dev/looper#202): its plan reads the build project's variable, a setting
  # and no secret, on every ref the build runs; no other variable of the build project, so every other repository's
  # gates job keeps the runner's defaults. Its limits are the runner's ceilings, 3500m 12Gi (#83: 2 CPU slowed the
  # timing-bound gates), and its requests 3 CPU 10Gi, what a c4a-standard-4 spot node has after its DaemonSets (#87).
  variable=$(change 'module.gitlab.gitlab_project_variable.build["BUILD_GATES_REQUESTS_tacplus"]')
  jq -e '.actions == ["create"] and .after.project == "4003" and .after.key == "BUILD_GATES_REQUESTS_tacplus" and
    .after.value == "3 10Gi 3500m 12Gi" and (.after.protected | not) and (.after.masked | not) and .after.raw and .after.environment_scope == "*"' <<< "$variable" > /dev/null &&
    [ "$(jq -c '[.resource_changes[] | select(.type == "gitlab_project_variable" and .change.after.project == "4003") | .change.after.key]' "$work/plan.json")" = '["BUILD_GATES_REQUESTS_tacplus"]' ] &&
    ok "tacplus-dev/build's BUILD_GATES_REQUESTS_tacplus: tacplus's gates job requests 3 CPU 10Gi, limits 3500m 12Gi, no other repository's (#82, #83, #87)" ||
    fail "BUILD_GATES_REQUESTS_tacplus: $variable"
  schedule=$(change 'module.gitlab.gitlab_pipeline_schedule.build["nightly"]')
  jq -e '.actions == ["create"] and .after.project == "4003" and .after.ref == "refs/heads/main" and .after.active and
    .after.description == "nightly" and .after.cron == "0 3 * * *" and .after.cron_timezone == "UTC" and
    ([.after.inputs[] | "\(.name)=\(.value)"] | sort) == ["nightly=true"]' <<< "$schedule" > /dev/null &&
    ok "one nightly schedule on tacplus-dev/build, of every pinned repository: nightly and no repo (#67, tacplus-dev/looper#164)" || fail "the nightly schedule: $schedule"
  # The branch releases (#112, tacplus-dev/looper#252): every pinned repository's main-green at 08:00 UTC, after the
  # nightly, and each release/X.Y branch with something new every 3 hours at :30; no repo. Created after the build
  # file (depends_on), which declares their input.
  for s in "release-main|0 8 * * *|release=main" "release-branches|30 1-23/3 * * *|release=branches"; do
    IFS='|' read -r name cron input <<< "$s"
    schedule=$(change "module.gitlab.gitlab_pipeline_schedule.build[\"$name\"]")
    jq -e --arg name "$name" --arg cron "$cron" --arg input "$input" '.actions == ["create"] and .after.project == "4003" and
      .after.ref == "refs/heads/main" and .after.active and .after.description == $name and .after.cron == $cron and
      .after.cron_timezone == "UTC" and ([.after.inputs[] | "\(.name)=\(.value)"] | sort) == [$input]' <<< "$schedule" > /dev/null &&
      ok "the schedule $name on tacplus-dev/build: $cron UTC, $input and no repo (#112, tacplus-dev/looper#252)" || fail "the schedule $name: $schedule"
  done
  schedules=$(jq -c '[.resource_changes[] | select(.type == "gitlab_pipeline_schedule" and .change.actions != ["delete"]) | .change.after.project] | group_by(.) | map({(.[0]): length}) | add' "$work/plan.json")
  [ "$schedules" = '{"4001":1,"4003":3}' ] &&
    ok "no other schedule on tacplus-dev/build (#67: #65's ten go; #112's two), and tacplus-dev/cloud's audit alone (#77)" || fail "the schedules by project: $schedules"
  # The hub's audit (#77): hourly on tacplus-dev/cloud's main, its pipeline the audit job alone (by its description),
  # with no variable (the project allows pipeline variables to the Owner role only).
  schedule=$(change 'module.gitlab.gitlab_pipeline_schedule.project["tacplus-dev/cloud:audit"]')
  jq -e '.actions == ["create"] and .after.project == "4001" and .after.ref == "refs/heads/main" and .after.active and
    .after.description == "audit" and .after.cron == "7 * * * *" and .after.cron_timezone == "UTC"' <<< "$schedule" > /dev/null &&
    [ -z "$(jq -r '.resource_changes[] | select(.type == "gitlab_pipeline_schedule_variable") | .address' "$work/plan.json")" ] &&
    ok "tacplus-dev/cloud's hourly schedule audit, with no variable (#77)" || fail "the audit schedule: $schedule"
  project=$(change 'module.gitlab.gitlab_project.build["build"]')
  jq -e '.actions == ["no-op"] and .importing.id == "4003" and .after.group_runners_enabled == true and .after.shared_runners_enabled == false' <<< "$project" > /dev/null &&
    ok "tacplus-dev/build: adopted (by its ID) with no change, group runners on and shared runners off as the hub set them (#35)" ||
    fail "tacplus-dev/build's runner settings: $(jq -c 'del(.before, .after) + {after: (.after | {group_runners_enabled, shared_runners_enabled})}' <<< "$project")"
  # The infra runner (#64; tacplus-dev/cluster#25): a group runner of tacplus-dev (the fixture's 3003), tags cloud,
  # cluster and deploy, untagged off, protected refs only, unpaused since the switch-over (#66); its token, known only
  # at apply, the first version of the dev project's gitlab-runner-infra.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["infra"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["cloud", "cluster", "deploy"] and .after.untagged == false and .after.paused == false and .after.access_level == "ref_protected"' <<< "$runner" > /dev/null &&
    ok "the infra runner: a tacplus-dev group runner, tags cloud, cluster and deploy, untagged off, protected refs only, unpaused (#64, #66)" ||
    fail "the infra runner: $(jq -c 'del(.before)' <<< "$runner")"
  # The kick runner (#81; tacplus-dev/cluster#36): a group runner of tacplus-dev, tags arm64 and kick, untagged off, any
  # ref (the looper's kicker and plan run on main's schedules), unpaused; its token the first version of the dev
  # project's gitlab-runner-kick.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["kick"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["arm64", "kick"] and .after.untagged == false and .after.paused == false and .after.access_level == "not_protected"' <<< "$runner" > /dev/null &&
    ok "the kick runner: a tacplus-dev group runner, tags arm64 and kick, untagged off, any ref, unpaused (#81)" ||
    fail "the kick runner: $(jq -c 'del(.before)' <<< "$runner")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["kick"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-kick" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-kick, known only at apply (#81)" || fail "the kick runner's token: $(jq -c 'del(.before)' <<< "$token")"
  # The build-report runner (#93; tacplus-dev/cluster#42): a group runner of tacplus-dev, tags arm64 and build-report
  # (not build: it would take a land's jobs too), untagged off, any ref, unpaused; its token the first version of the
  # dev project's gitlab-runner-build-report.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["build-report"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["arm64", "build-report"] and .after.untagged == false and .after.paused == false and .after.access_level == "not_protected"' <<< "$runner" > /dev/null &&
    ok "the build-report runner: a tacplus-dev group runner, tags arm64 and build-report, untagged off, any ref, unpaused (#93)" ||
    fail "the build-report runner: $(jq -c 'del(.before)' <<< "$runner")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["build-report"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-build-report" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-build-report, known only at apply (#93)" || fail "the build-report runner's token: $(jq -c 'del(.before)' <<< "$token")"
  # The build-light runner (#100; tacplus-dev/cluster#51): a group runner of tacplus-dev, tags arm64 and build-light
  # (not build: it would take the gates and security jobs too), untagged off, any ref, unpaused; its token the first
  # version of the dev project's gitlab-runner-build-light.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["build-light"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["arm64", "build-light"] and .after.untagged == false and .after.paused == false and .after.access_level == "not_protected"' <<< "$runner" > /dev/null &&
    ok "the build-light runner: a tacplus-dev group runner, tags arm64 and build-light, untagged off, any ref, unpaused (#100)" ||
    fail "the build-light runner: $(jq -c 'del(.before)' <<< "$runner")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["build-light"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-build-light" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-build-light, known only at apply (#100)" || fail "the build-light runner's token: $(jq -c 'del(.before)' <<< "$token")"
  # The manager runner (#106; tacplus-dev/cluster#60): a group runner of tacplus-dev, tags arm64 and manager (not
  # control: it would take the reports too), untagged off, any ref, unpaused; its token the first version of the dev
  # project's gitlab-runner-manager.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["manager"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["arm64", "manager"] and .after.untagged == false and .after.paused == false and .after.access_level == "not_protected"' <<< "$runner" > /dev/null &&
    ok "the manager runner: a tacplus-dev group runner, tags arm64 and manager, untagged off, any ref, unpaused (#106)" ||
    fail "the manager runner: $(jq -c 'del(.before)' <<< "$runner")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["manager"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-manager" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-manager, known only at apply (#106)" || fail "the manager runner's token: $(jq -c 'del(.before)' <<< "$token")"
  # The nightly runner (#116; tacplus-dev/cluster#46): a group runner of tacplus-dev, tags arm64 and build-nightly (not
  # build: it would take a land's jobs too), untagged off, any ref, unpaused; its token the first version of the dev
  # project's gitlab-runner-nightly.
  runner=$(change 'module.gitlab.gitlab_user_runner.runner["nightly"]')
  jq -e '.actions == ["create"] and .after.runner_type == "group_type" and .after.group_id == 3003 and
    (.after.tag_list | sort) == ["arm64", "build-nightly"] and .after.untagged == false and .after.paused == false and .after.access_level == "not_protected"' <<< "$runner" > /dev/null &&
    ok "the nightly runner: a tacplus-dev group runner, tags arm64 and build-nightly, untagged off, any ref, unpaused (#116)" ||
    fail "the nightly runner: $(jq -c 'del(.before)' <<< "$runner")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["nightly"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-nightly" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-nightly, known only at apply (#116)" || fail "the nightly runner's token: $(jq -c 'del(.before)' <<< "$token")"
  token=$(change 'module.gitlab.google_secret_manager_secret_version.runner_token["infra"]')
  jq -e '.actions == ["create"] and .after.secret == "projects/tacplus-dev/secrets/gitlab-runner-infra" and .after_unknown.secret_data == true' <<< "$token" > /dev/null &&
    ok "its token: a version of the dev project's gitlab-runner-infra, known only at apply (#64)" || fail "the infra runner's token: $(jq -c 'del(.before)' <<< "$token")"
  # The in-cluster runners alone, none paused: no tacplus-ci pool's runner is registered (#113).
  paused=$(jq -cS '[.resource_changes[] | select(.type == "gitlab_user_runner") | {(.index): .change.after.paused}] | add' "$work/plan.json")
  [ "$paused" = '{"build-light":false,"build-report":false,"infra":false,"kick":false,"manager":false,"nightly":false}' ] &&
    ok "the runners: infra, kick, build-report, build-light, manager and nightly, none paused, and no pool's (#64, #81, #93, #100, #106, #116, #113)" || fail "the runners' paused: $paused"
  member=$(change 'module.gitlab.gitlab_project_membership.member["tacplus-dev/build:tacplus-looper-bot"]')
  jq -e '.actions == ["create"] and .after.access_level == "reporter" and .after.project == "4003" and .after.user_id == 2002' <<< "$member" > /dev/null &&
    ok "tacplus-looper-bot: a Reporter of tacplus-dev/build (#12)" || fail "the membership: $member"
  # fleet-seatrials reads tacplus-dev/build's release records with its own JOB-TOKEN (#117; tacplus-dev/looper#262):
  # build's (4003) job token allowlist admits fleet-seatrials (4004); its trigger waits for tacplus-dev/fleet-seatrials#82.
  scope=$(change 'module.gitlab.gitlab_project_job_token_scope.build["tacplus-dev/fleet-seatrials"]')
  jq -e '.actions == ["create"] and .after.project == "4003" and .after.target_project_id == 4004' <<< "$scope" > /dev/null &&
    [ "$(jq -c '[.resource_changes[] | select(.type == "gitlab_project_job_token_scope") | .index]' "$work/plan.json")" = '["tacplus-dev/fleet-seatrials"]' ] &&
    ok "tacplus-dev/build's job token allowlist admits tacplus-dev/fleet-seatrials, and no other project (#117)" || fail "the job token allowlist: $scope"
  [ -z "$(jq -r '.resource_changes[] | select(.address | startswith("module.gitlab.gitlab_pipeline_trigger.downstream")) | .address' "$work/plan.json")" ] &&
    ok "no downstream trigger before tacplus-dev/fleet-seatrials#82 is live (#117)" || fail "a downstream trigger is planned"
else
  fail "the stack does not plan against gitlab.com's answers: $(grep -A4 '^Error' "$work/plan.txt")"
fi
! grep -v '^GET ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# tacplus-dev/build with group runners off, as it was until the hub's hand change of 2026-11-09 (#35): every build job
# found no runner. The plan turns them back on, and changes nothing else of the project.
sed -i "s|$api/|http://$(cat "$work/addr-before")/|" "$stack/stub_override.tf"
if plan; then
  (cd "$stack" && tofu show -json p.tfplan) > "$work/plan-before.json"
  project=$(jq -c '.resource_changes[] | select(.address == "module.gitlab.gitlab_project.build[\"build\"]") | .change' "$work/plan-before.json")
  changed=$(jq -c '[.before as $b | .after | to_entries[] | select(.value != $b[.key]) | .key]' <<< "$project")
  jq -e '.actions == ["update"] and .after.group_runners_enabled == true and .after.shared_runners_enabled == false' <<< "$project" > /dev/null &&
    [ "$changed" = '["group_runners_enabled"]' ] &&
    ok "tacplus-dev/build with group runners off: the plan turns them on, and nothing else (#35)" ||
    fail "tacplus-dev/build with group runners off: $(jq -c '.actions' <<< "$project"), changed $changed"
else
  fail "the stack does not plan against tacplus-dev/build with group runners off: $(grep -A4 '^Error' "$work/plan.txt")"
fi
! grep -v '^GET ' "$work/requests-before" > /dev/null && ok "that plan only reads too" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests-before")"
sed -i "s|http://$(cat "$work/addr-before")/|$api/|" "$stack/stub_override.tf"

# The form gitlab.com refused (#17): the fixture makes the provider see an Enterprise instance, so the plan fails here
# as it failed there.
sed -i 's/allowed_to_push *= \[{ access_level = "maintainer" }\]/push_access_level = "maintainer"/; s/allowed_to_merge *= \[{ access_level = "maintainer" }\]/merge_access_level = "maintainer"/' \
  "$work/modules/gitlab/main.tf"
grep -q 'push_access_level = "maintainer"' "$work/modules/gitlab/main.tf" || fail "the test cannot write the old form into its copy"
! plan && grep -qF 'feature unavailable `push_access_level`' "$work/plan.txt" && grep -qF 'feature unavailable `merge_access_level`' "$work/plan.txt" &&
  ok "push_access_level and merge_access_level: refused, as on gitlab.com" || fail "the old form: $(tail -5 "$work/plan.txt")"

[ "$failed" = 0 ] && echo "gitlab_plan_test: all passed" || { echo "gitlab_plan_test: failed"; exit 1; }
