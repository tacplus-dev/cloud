# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The gitlab stack's plan against a stub GitLab and stub secrets (mock providers: no token, no cloud): the stack
# plans, and its module, with the stack's inputs, gives protected settings, variables from Secret Manager by
# version, runners whose tokens go to Secret Manager only (the pools' to the ci project's, the in-cluster infra
# runner's to the dev project's gitlab-runner-infra, #64, the kick runner's to gitlab-runner-kick, #81, the build-report runner's to gitlab-runner-build-report, #93, the build-light runner's to gitlab-runner-build-light, #100, and the manager runner's to gitlab-runner-manager, #106), infra taking the jobs the paused cluster and deploy pools took (#66), and memberships of other projects that read only (Reporter,
# 20, at most) and expire (#12). (A test sees a module's resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_project" {
    defaults = { billing_account = "000000-111111-222222", number = "333" }
  }
  mock_data "google_secret_manager_secret_version" {
    defaults = { secret_data = "stub-value" }
  }
}

mock_provider "gitlab" {
  mock_data "gitlab_project" {
    defaults = { id = "77" }
  }
  mock_data "gitlab_group" {
    defaults = { group_id = 88 }
  }
  mock_data "gitlab_user" {
    defaults = { user_id = 99 }
  }
  # A runner's id is GitLab's number (gitlab_project_runner_enablement takes it as one).
  mock_resource "gitlab_user_runner" {
    defaults = { id = "4242" }
  }
}

run "stack" {
  command = plan
  variables {
    import_existing = false
  }
  assert {
    condition     = output.project_ids == { "tacplus-dev/cloud" = "77" }
    error_message = "The stack manages more projects than tacplus-dev/cloud."
  }
  # The hub's audit (#77): one schedule of tacplus-dev/cloud's own, hourly on main, its pipeline the audit job alone.
  assert {
    condition     = output.schedules == { "tacplus-dev/cloud:audit" = { description = "audit", ref = "refs/heads/main", cron = "7 * * * *", cron_timezone = "UTC", active = true } }
    error_message = "tacplus-dev/cloud has not exactly the hourly schedule audit on main."
  }
  assert {
    condition     = toset(keys(output.runner_ids)) == toset(["shared", "build", "deploy", "cluster", "infra", "kick", "build-report", "build-light", "manager"])
    error_message = "The stack does not register one runner per pool, shared, build, deploy and cluster, and the in-cluster infra (#64), kick (#81), build-report (#93), build-light (#100) and manager (#106) runners."
  }
  # The infra runner (#64; tacplus-dev/cluster#25, its gitlab-runner/runners/infra.yaml): a tacplus-dev group runner for
  # the cloud, cluster and deploy pipelines, those three tags and no other, untagged off, protected refs only, unpaused
  # at the switch-over (#66), its token the dev project's gitlab-runner-infra (version 1, the first of an empty secret),
  # which no person types.
  assert {
    condition     = output.runners["infra"].type == "group_type" && output.runners["infra"].group_id == 88
    error_message = "The infra runner is not a group runner of tacplus-dev."
  }
  assert {
    condition     = output.runners["infra"].tags == toset(["cloud", "cluster", "deploy"]) && !output.runners["infra"].untagged
    error_message = "The infra runner's tags are not cloud, cluster and deploy, and no other, or it takes untagged jobs."
  }
  assert {
    condition     = output.runners["infra"].access_level == "ref_protected" && !output.runners["infra"].paused
    error_message = "The infra runner takes unprotected refs, or is paused: it takes the cloud, cluster and deploy jobs since the switch-over (#66)."
  }
  assert {
    condition     = output.runners["infra"].token_secret == "projects/tacplus-dev/secrets/gitlab-runner-infra"
    error_message = "The infra runner's token is not written to the dev project's gitlab-runner-infra, tacplus-dev/cluster's tacplus.token."
  }
  # The kick runner (#81; tacplus-dev/cluster#36, its gitlab-runner/runners/kick.yaml): a tacplus-dev group runner for
  # the looper's kicker and plan alone, tags arm64 and kick and no other (not control: GitLab gives a runner every job
  # whose tags are a subset of its own, so one holding control would take the reports too), untagged off, any ref (the
  # kicker and plan run on main's schedules), unpaused (no job carries kick until tacplus-dev/looper moves them to it),
  # its token the dev project's gitlab-runner-kick (version 1, the first of an empty secret), which no person types.
  assert {
    condition     = output.runners["kick"].type == "group_type" && output.runners["kick"].group_id == 88
    error_message = "The kick runner is not a group runner of tacplus-dev."
  }
  assert {
    condition     = output.runners["kick"].tags == toset(["arm64", "kick"]) && !output.runners["kick"].untagged
    error_message = "The kick runner's tags are not arm64 and kick, and no other, or it takes untagged jobs."
  }
  assert {
    condition     = output.runners["kick"].access_level == "not_protected" && !output.runners["kick"].paused
    error_message = "The kick runner takes protected refs only, or is paused: the kicker and plan run on main's schedules, and take it once tacplus-dev/looper tags them kick."
  }
  assert {
    condition     = output.runners["kick"].token_secret == "projects/tacplus-dev/secrets/gitlab-runner-kick"
    error_message = "The kick runner's token is not written to the dev project's gitlab-runner-kick, tacplus-dev/cluster's tacplus.token."
  }
  # No other runner carries kick: its jobs (the kicker and plan) go to kick alone.
  assert {
    condition     = [for k, r in output.runners : k if contains(r.tags, "kick")] == ["kick"]
    error_message = "A runner besides kick carries the tag kick."
  }
  # The build-report runner (#93; tacplus-dev/cluster#42, its gitlab-runner/runners/build-report.yaml): a tacplus-dev
  # group runner for the report builds alone (tacplus-dev/build's BUILD_REPORT_TAGS, tacplus-dev/looper#209), whose pods
  # a land's build preempts; tags arm64 and build-report and no other (not build: GitLab gives a runner every job whose
  # tags are a subset of its own, so one holding build would take a land's jobs too, at the report builds' priority),
  # untagged off, any ref, unpaused (no job carries build-report until the hub sets BUILD_REPORT_TAGS), its token the dev
  # project's gitlab-runner-build-report (version 1, the first of an empty secret), which no person types.
  assert {
    condition     = output.runners["build-report"].type == "group_type" && output.runners["build-report"].group_id == 88
    error_message = "The build-report runner is not a group runner of tacplus-dev."
  }
  assert {
    condition     = output.runners["build-report"].tags == toset(["arm64", "build-report"]) && !output.runners["build-report"].untagged
    error_message = "The build-report runner's tags are not arm64 and build-report, and no other, or it takes untagged jobs."
  }
  assert {
    condition     = output.runners["build-report"].access_level == "not_protected" && !output.runners["build-report"].paused
    error_message = "The build-report runner takes protected refs only, or is paused: report builds run on any ref, and take it once the hub sets BUILD_REPORT_TAGS."
  }
  assert {
    condition     = output.runners["build-report"].token_secret == "projects/tacplus-dev/secrets/gitlab-runner-build-report"
    error_message = "The build-report runner's token is not written to the dev project's gitlab-runner-build-report, tacplus-dev/cluster's tacplus.token."
  }
  # No other runner carries build-report, and build-report carries no build: a land's jobs never go to it.
  assert {
    condition     = [for k, r in output.runners : k if contains(r.tags, "build-report")] == ["build-report"] && !contains(output.runners["build-report"].tags, "build")
    error_message = "A runner besides build-report carries the tag build-report, or build-report carries build."
  }
  # The build-light runner (#100; tacplus-dev/cluster#51, its gitlab-runner/runners/build-light.yaml): a tacplus-dev
  # group runner on the normal pool for tacplus-dev/build's light jobs alone (pending, plan, report-pass and
  # report-fail, tacplus-dev/looper#224), so a build runner's slot goes only to the gates and security jobs; tags arm64
  # and build-light and no other (not build: GitLab gives a runner every job whose tags are a subset of its own, so one
  # holding build would take the gates and security jobs onto the normal pool), untagged off, any ref, unpaused (no job
  # carries build-light until this repository's copy of the build pipeline's CI file tags them so), its token the dev
  # project's gitlab-runner-build-light (version 1, the first of an empty secret), which no person types.
  assert {
    condition     = output.runners["build-light"].type == "group_type" && output.runners["build-light"].group_id == 88
    error_message = "The build-light runner is not a group runner of tacplus-dev."
  }
  assert {
    condition     = output.runners["build-light"].tags == toset(["arm64", "build-light"]) && !output.runners["build-light"].untagged
    error_message = "The build-light runner's tags are not arm64 and build-light, and no other, or it takes untagged jobs."
  }
  assert {
    condition     = output.runners["build-light"].access_level == "not_protected" && !output.runners["build-light"].paused
    error_message = "The build-light runner takes protected refs only, or is paused: builds run on any ref, and take it once the build pipeline's CI file tags its light jobs build-light."
  }
  assert {
    condition     = output.runners["build-light"].token_secret == "projects/tacplus-dev/secrets/gitlab-runner-build-light"
    error_message = "The build-light runner's token is not written to the dev project's gitlab-runner-build-light, tacplus-dev/cluster's tacplus.token."
  }
  # No other runner carries build-light, and build-light carries no build: the gates and security jobs never go to it.
  assert {
    condition     = [for k, r in output.runners : k if contains(r.tags, "build-light")] == ["build-light"] && !contains(output.runners["build-light"].tags, "build")
    error_message = "A runner besides build-light carries the tag build-light, or build-light carries build."
  }
  # The manager runner (#106; tacplus-dev/cluster#60, its gitlab-runner/runners/manager.yaml): a tacplus-dev group
  # runner on the normal (always-on) pool for the looper's managers alone (tacplus-dev/looper#236's .manager), so a
  # manager never waits for a slot behind the reports on control; tags arm64 and manager and no other (not control:
  # GitLab gives a runner every job whose tags are a subset of its own, so one holding control would take the reports
  # too and fill up as control does), untagged off, any ref, unpaused (no job carries manager until tacplus-dev/looper
  # tags its managers so), its token the dev project's gitlab-runner-manager (version 1, the first of an empty secret),
  # which no person types.
  assert {
    condition     = output.runners["manager"].type == "group_type" && output.runners["manager"].group_id == 88
    error_message = "The manager runner is not a group runner of tacplus-dev."
  }
  assert {
    condition     = output.runners["manager"].tags == toset(["arm64", "manager"]) && !output.runners["manager"].untagged
    error_message = "The manager runner's tags are not arm64 and manager, and no other, or it takes untagged jobs."
  }
  assert {
    condition     = output.runners["manager"].access_level == "not_protected" && !output.runners["manager"].paused
    error_message = "The manager runner takes protected refs only, or is paused: managers take it once tacplus-dev/looper tags them manager."
  }
  assert {
    condition     = output.runners["manager"].token_secret == "projects/tacplus-dev/secrets/gitlab-runner-manager"
    error_message = "The manager runner's token is not written to the dev project's gitlab-runner-manager, tacplus-dev/cluster's tacplus.token."
  }
  # No other runner carries manager, and manager carries no control: the reports never go to it.
  assert {
    condition     = [for k, r in output.runners : k if contains(r.tags, "manager")] == ["manager"] && !contains(output.runners["manager"].tags, "control")
    error_message = "A runner besides manager carries the tag manager, or manager carries control."
  }
  # The build pool's runner (#70): arm64 and build, which it keeps until #11 removes it, and build-docker, which
  # tacplus-dev/looper#172's BUILD_DOCKER_TAGS asks for, so a job that still needs host Docker never lands on the
  # in-cluster build runner (no socket) once it takes arm64 and build too.
  assert {
    condition     = output.runners["build"].tags == toset(["arm64", "build", "build-docker"]) && !output.runners["build"].untagged
    error_message = "The build pool's runner's tags are not arm64, build and build-docker (#70), or it takes untagged jobs."
  }
  # The switch-over (#66): the cluster and deploy pools' runners are paused, infra taking their jobs, until #11 removes
  # them; shared and build keep taking jobs. Each pool's token goes to its own secret of the ci project.
  assert {
    condition     = toset([for k, r in output.runners : k if r.paused]) == toset(["cluster", "deploy"])
    error_message = "The paused runners are not the cluster and deploy pools' (#66): infra, kick, build-report, build-light, manager, shared and build take jobs."
  }
  assert {
    condition     = alltrue([for k, r in output.runners : r.token_secret == "projects/tacplus-ci/secrets/runner-token-${k}" if !contains(["infra", "kick", "build-report", "build-light", "manager"], k)])
    error_message = "A pool's token does not go to the ci project's runner-token-<pool>."
  }
  # The cluster and deploy pools carry the tags infra takes over, and no other runner does: the switch-over paused them
  # as it unpaused infra, so no unpaused runner but infra takes a cloud, cluster or deploy job.
  assert {
    condition     = toset([for k, r in output.runners : k if length(setintersection(r.tags, toset(["cloud", "cluster", "deploy"]))) > 0]) == toset(["cluster", "deploy", "infra"])
    error_message = "A runner besides the cluster and deploy pools and infra carries cloud, cluster or deploy."
  }
  # The looper's recap reads tacplus-dev/build as tacplus-looper-bot, through every looper job's GITLAB_TOKEN (#12,
  # option B): Reporter, nothing higher, and an expiry.
  assert {
    condition     = keys(output.members) == ["tacplus-dev/build:tacplus-looper-bot", "tacplus-dev/cluster:tacplus-looper-bot"]
    error_message = "The stack makes other members than tacplus-looper-bot of tacplus-dev/build and tacplus-dev/cluster."
  }
  assert {
    condition     = output.members["tacplus-dev/build:tacplus-looper-bot"].access_level == "reporter" && output.members["tacplus-dev/build:tacplus-looper-bot"].user_id == 99 && output.members["tacplus-dev/build:tacplus-looper-bot"].project == "77"
    error_message = "tacplus-looper-bot is not a Reporter (20) of tacplus-dev/build."
  }
  assert {
    condition     = can(regex("^20[0-9]{2}-[01][0-9]-[0-3][0-9]$", output.members["tacplus-dev/build:tacplus-looper-bot"].expires_at))
    error_message = "tacplus-looper-bot's membership of tacplus-dev/build has no expiry."
  }
  # tacplus-dev/build (#26): its trigger's token is the looper project's (88136765) BUILD_TRIGGER_TOKEN, and one nightly
  # schedule that builds every pinned repository (#67; tacplus-dev/looper#164: the input nightly and no repo, the
  # pipeline lists them itself), in place of #65's ten, one per repository, of the ten GitLab allows a project.
  assert {
    condition     = output.build.project == "77" && output.build.variable == { project = "88136765", key = "BUILD_TRIGGER_TOKEN" }
    error_message = "The build trigger's token is not tacplus-dev/looper's (88136765) BUILD_TRIGGER_TOKEN."
  }
  # Its jobs are tagged build, which only tacplus-dev's group runners take: group runners on, shared off (#35).
  assert {
    condition     = output.build_runners == { group_runners_enabled = true, shared_runners_enabled = false }
    error_message = "tacplus-dev/build does not take group runners, or takes gitlab.com's shared runners (#35): no tacplus-dev runner takes its build jobs."
  }
  assert {
    condition     = output.build.schedules == { nightly = { cron = "0 3 * * *", inputs = { nightly = "true" } } }
    error_message = "tacplus-dev/build's schedules are not the one nightly of every pinned repository (#67: 03:00 UTC, the input nightly: true and no repo)."
  }
  # fleet-seatrials reads tacplus-dev/build's release records with its own JOB-TOKEN (#117; tacplus-dev/looper#262,
  # tacplus-dev/fleet-seatrials#82): build's job token allowlist admits it, and no other project. Its trigger, whose
  # token is build's BUILD_SEATRIALS_TRIGGER_TOKEN, waits for fleet-seatrials#82 to be live: none yet.
  assert {
    condition     = output.build.job_token_readers == { "tacplus-dev/fleet-seatrials" = 77 }
    error_message = "tacplus-dev/build's job token allowlist does not admit tacplus-dev/fleet-seatrials alone (#117)."
  }
  assert {
    condition     = output.build.downstream_triggers == {}
    error_message = "The stack makes a downstream trigger before tacplus-dev/fleet-seatrials#82 is live (#117)."
  }
}

run "gitlab" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {
      "tacplus-dev/cloud" = {
        create                 = false
        protected_branches     = ["main"]
        protected_environments = ["folder", "ci", "dev", "gitlab", "anthropic"]
        variables = {
          PLAIN  = { value = "projects/333/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-cloud" }
          SECRET = { secret = "projects/tacplus-bootstrap/secrets/tacplus-reader-app-id/versions/1" }
        }
      }
    }
    runners = {
      group = { type = "group_type", group = "tacplus-dev", tags = ["arm64", "autoscale"], protected = false, paused = true, token_secret = "projects/tacplus-ci/secrets/runner-token-group" }
      proj  = { type = "project_type", project = "tacplus-dev/cloud", tags = ["cluster"], protected = true, paused = true, token_secret = "projects/tacplus-ci/secrets/runner-token-proj" }
      infra = { type = "group_type", group = "tacplus-dev", tags = ["cloud", "cluster", "deploy"], protected = true, paused = true, token_secret = "projects/tacplus-dev/secrets/gitlab-runner-infra", description = "tacplus-dev infra (in the cluster)" }
    }
    members = {
      "tacplus-dev/build:tacplus-looper-bot" = { access_level = "reporter", expires_at = "2027-10-01" }
    }
    build = {
      project           = "tacplus-dev/build"
      ci_file           = { content = "stages: [build]\n", commit_message = "ci/build.gitlab-ci.yml at tacplus-dev/looper@abc" }
      trigger           = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules         = { looper = { cron = "0 5 * * *", inputs = { repo = "looper", nightly = "true" } } }
      job_token_readers = ["tacplus-dev/fleet-seatrials"]
      downstream_triggers = {
        seatrials = { project = "tacplus-dev/fleet-seatrials", description = "BUILD_SEATRIALS_TRIGGER_TOKEN of tacplus-dev/build", rotate_by = "2027-02-24", variable_key = "BUILD_SEATRIALS_TRIGGER_TOKEN", environment_scope = "seatrials-trigger" }
      }
    }
  }

  assert {
    condition     = [for a in gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allowed_to_push : a.access_level] == ["maintainer"] && [for a in gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allowed_to_merge : a.access_level] == ["maintainer"] && !gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allow_force_push
    error_message = "main is not protected: Maintainers push and merge, nobody force-pushes."
  }
  assert {
    condition     = toset(keys(gitlab_project_protected_environment.environment)) == toset(["tacplus-dev/cloud:folder", "tacplus-dev/cloud:ci", "tacplus-dev/cloud:dev", "tacplus-dev/cloud:gitlab", "tacplus-dev/cloud:anthropic"])
    error_message = "The protected environments are not one per stack."
  }
  assert {
    condition     = alltrue([for v in gitlab_project_variable.variable : v.protected && v.environment_scope == "*" && v.project == "77"])
    error_message = "A variable is not a protected project variable."
  }
  assert {
    condition     = gitlab_project_variable.variable["tacplus-dev/cloud:SECRET"].value == "stub-value" && data.google_secret_manager_secret_version.variable["tacplus-dev/cloud:SECRET"].version == "1" && data.google_secret_manager_secret_version.variable["tacplus-dev/cloud:SECRET"].secret == "projects/tacplus-bootstrap/secrets/tacplus-reader-app-id"
    error_message = "A secret variable's value is not its Secret Manager version's."
  }
  assert {
    condition     = alltrue([for r in gitlab_user_runner.runner : r.paused && !r.untagged])
    error_message = "A runner takes jobs (paused), or untagged ones."
  }
  assert {
    condition     = gitlab_user_runner.runner["group"].group_id == 88 && gitlab_user_runner.runner["proj"].project_id == 77 && gitlab_user_runner.runner["proj"].access_level == "ref_protected" && gitlab_user_runner.runner["proj"].locked
    error_message = "The runners are not registered where, and for the refs, their pools say."
  }
  assert {
    condition     = google_secret_manager_secret_version.runner_token["proj"].secret == "projects/tacplus-ci/secrets/runner-token-proj" && google_secret_manager_secret_version.runner_token["infra"].secret == "projects/tacplus-dev/secrets/gitlab-runner-infra"
    error_message = "A runner's token does not go to its own secret."
  }
  # A group runner of protected refs (#64), described as given; a pool's description is the manager's, by default.
  assert {
    condition     = gitlab_user_runner.runner["infra"].runner_type == "group_type" && gitlab_user_runner.runner["infra"].group_id == 88 && gitlab_user_runner.runner["infra"].access_level == "ref_protected" && !gitlab_user_runner.runner["infra"].locked && gitlab_user_runner.runner["infra"].description == "tacplus-dev infra (in the cluster)"
    error_message = "The infra runner is not a protected-refs group runner of tacplus-dev with the description given."
  }
  assert {
    condition     = gitlab_user_runner.runner["group"].description == "tacplus-ci group (tacplus-dev/cloud: runner-manager in the ci project)"
    error_message = "A pool's runner is not described as the ci project's runner manager's."
  }
  assert {
    condition     = gitlab_project_membership.member["tacplus-dev/build:tacplus-looper-bot"].project == "77" && gitlab_project_membership.member["tacplus-dev/build:tacplus-looper-bot"].user_id == 99 && data.gitlab_user.member["tacplus-looper-bot"].username == "tacplus-looper-bot"
    error_message = "A membership is not the user's of the project its key names."
  }
  assert {
    condition     = alltrue([for m in gitlab_project_membership.member : contains(["guest", "reporter"], m.access_level) && m.expires_at != null])
    error_message = "A membership is higher than Reporter (20), or does not expire."
  }
  # tacplus-dev/build (#26): the trigger on it, its token the protected, masked variable of the project named, its
  # rotation keyed on rotate_by; the schedules on its main, in UTC, with their inputs; its .gitlab-ci.yml, as given.
  assert {
    condition     = gitlab_pipeline_trigger.build["build"].project == "77" && terraform_data.build_trigger_rotation["build"].input == "2027-02-05"
    error_message = "The build trigger is not on tacplus-dev/build, or its rotation is not keyed on rotate_by."
  }
  assert {
    condition     = gitlab_project_variable.build_trigger["build"].project == "88136765" && gitlab_project_variable.build_trigger["build"].key == "BUILD_TRIGGER_TOKEN" && gitlab_project_variable.build_trigger["build"].protected && gitlab_project_variable.build_trigger["build"].masked && gitlab_project_variable.build_trigger["build"].environment_scope == "*"
    error_message = "BUILD_TRIGGER_TOKEN is not the looper project's protected, masked variable."
  }
  assert {
    condition     = gitlab_pipeline_schedule.build["looper"].project == "77" && gitlab_pipeline_schedule.build["looper"].ref == "refs/heads/main" && gitlab_pipeline_schedule.build["looper"].cron_timezone == "UTC" && gitlab_pipeline_schedule.build["looper"].active && toset([for i in gitlab_pipeline_schedule.build["looper"].inputs : "${i.name}=${i.value}"]) == toset(["repo=looper", "nightly=true"])
    error_message = "The looper's nightly schedule is not on tacplus-dev/build's main, in UTC, with the inputs repo and nightly."
  }
  assert {
    condition     = gitlab_repository_file.build_ci["build"].project == "77" && gitlab_repository_file.build_ci["build"].branch == "main" && gitlab_repository_file.build_ci["build"].file_path == ".gitlab-ci.yml" && gitlab_repository_file.build_ci["build"].content == "stages: [build]\n"
    error_message = "tacplus-dev/build's .gitlab-ci.yml is not the content given, on its main."
  }
  assert {
    condition     = gitlab_project.build["build"].name == "build" && gitlab_project.build["build"].group_runners_enabled && !gitlab_project.build["build"].shared_runners_enabled
    error_message = "tacplus-dev/build's runner settings are not group runners on and shared runners off (#35)."
  }
  # The job token allowlist (#117): one entry per reader, on tacplus-dev/build, its target the reader's project ID.
  assert {
    condition     = keys(gitlab_project_job_token_scope.build) == ["tacplus-dev/fleet-seatrials"] && gitlab_project_job_token_scope.build["tacplus-dev/fleet-seatrials"].project == "77" && gitlab_project_job_token_scope.build["tacplus-dev/fleet-seatrials"].target_project_id == 77
    error_message = "tacplus-dev/build's job token allowlist does not admit the reader's project, by its ID."
  }
  # A downstream trigger (#117): on the project it starts, rotated by rotate_by; its token tacplus-dev/build's protected,
  # masked variable, scoped to its environment alone, and that environment protected (Maintainers deploy), so that no
  # other job of build, the gates job running a repository's own code least of all, receives it.
  assert {
    condition     = gitlab_pipeline_trigger.downstream["seatrials"].project == "77" && terraform_data.downstream_trigger_rotation["seatrials"].input == "2027-02-24" && gitlab_pipeline_trigger.downstream["seatrials"].description == "BUILD_SEATRIALS_TRIGGER_TOKEN of tacplus-dev/build (tacplus-dev/cloud, rotated by 2027-02-24)"
    error_message = "The downstream trigger is not on the project it starts, or its rotation is not keyed on rotate_by."
  }
  assert {
    condition     = gitlab_project_variable.downstream_trigger["seatrials"].project == "77" && gitlab_project_variable.downstream_trigger["seatrials"].key == "BUILD_SEATRIALS_TRIGGER_TOKEN" && gitlab_project_variable.downstream_trigger["seatrials"].protected && gitlab_project_variable.downstream_trigger["seatrials"].masked && gitlab_project_variable.downstream_trigger["seatrials"].raw && gitlab_project_variable.downstream_trigger["seatrials"].environment_scope == "seatrials-trigger"
    error_message = "BUILD_SEATRIALS_TRIGGER_TOKEN is not tacplus-dev/build's protected, masked variable scoped to seatrials-trigger."
  }
  assert {
    condition     = gitlab_project_protected_environment.downstream["seatrials"].project == "77" && gitlab_project_protected_environment.downstream["seatrials"].environment == "seatrials-trigger" && [for a in gitlab_project_protected_environment.downstream["seatrials"].deploy_access_levels_attribute : a.access_level] == ["maintainer"]
    error_message = "seatrials-trigger is not a protected environment of tacplus-dev/build, deployable by Maintainers."
  }
}

run "latest_secret_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {
      "tacplus-dev/cloud" = {
        create                 = false
        protected_branches     = []
        protected_environments = []
        variables              = { X = { secret = "projects/tacplus-bootstrap/secrets/x/versions/latest" } }
      }
    }
    runners = {}
  }
  expect_failures = [var.projects]
}

# A membership higher than Reporter (20), or with no expiry, or not PROJECT:USER, is refused before any plan (#12).
run "member_above_reporter_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    members  = { "tacplus-dev/build:tacplus-looper-bot" = { access_level = "developer", expires_at = "2027-10-01" } }
  }
  expect_failures = [var.members]
}

run "member_without_expiry_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    members  = { "tacplus-dev/build:tacplus-looper-bot" = { access_level = "reporter", expires_at = null } }
  }
  expect_failures = [var.members]
}

run "member_key_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    members  = { "tacplus-looper-bot" = { access_level = "reporter", expires_at = "2027-10-01" } }
  }
  expect_failures = [var.members]
}

# A build trigger's rotate_by is a date in the commit, and a schedule has a five-field cron and inputs (#26).
run "build_rotate_by_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    build = {
      project   = "tacplus-dev/build"
      trigger   = { description = "x", rotate_by = "90d", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules = {}
    }
  }
  expect_failures = [var.build]
}

run "build_schedule_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    build = {
      project   = "tacplus-dev/build"
      trigger   = { description = "x", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules = { looper = { cron = "@daily", inputs = {} } }
    }
  }
  expect_failures = [var.build]
}

# GitLab allows a project 10 pipeline schedules (#65): an 11th fails the apply, so the plan refuses it.
run "build_schedules_capped" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    build = {
      project   = "tacplus-dev/build"
      trigger   = { description = "x", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules = { for r in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"] : r => { cron = "0 5 * * *", inputs = { repo = r, nightly = "true" } } }
    }
  }
  expect_failures = [var.build]
}

# A downstream trigger's token is scoped to one environment (#117): unscoped (*) or empty, it would reach every job of
# tacplus-dev/build, the gates job, which runs a repository's own code, too.
run "downstream_trigger_unscoped_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    build = {
      project             = "tacplus-dev/build"
      trigger             = { description = "x", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules           = {}
      downstream_triggers = { seatrials = { project = "tacplus-dev/fleet-seatrials", description = "x", rotate_by = "2027-02-24", variable_key = "BUILD_SEATRIALS_TRIGGER_TOKEN", environment_scope = "*" } }
    }
  }
  expect_failures = [var.build]
}

# Nor empty.
run "downstream_trigger_empty_refused" {
  command = plan
  module {
    source = "../../modules/gitlab"
  }
  variables {
    projects = {}
    runners  = {}
    build = {
      project             = "tacplus-dev/build"
      trigger             = { description = "x", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules           = {}
      downstream_triggers = { seatrials = { project = "tacplus-dev/fleet-seatrials", description = "x", rotate_by = "2027-02-24", variable_key = "BUILD_SEATRIALS_TRIGGER_TOKEN", environment_scope = "" } }
    }
  }
  expect_failures = [var.build]
}
