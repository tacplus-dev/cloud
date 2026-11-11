# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The gitlab stack's plan against a stub GitLab and stub secrets (mock providers: no token, no cloud): the stack
# plans, and its module, with the stack's inputs, gives protected settings, variables from Secret Manager by
# version, paused runners whose tokens go to Secret Manager only, and memberships of other projects that read
# only (Reporter, 20, at most) and expire (#12). (A test sees a module's resources only when it runs that module
# itself.)

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
  assert {
    condition     = toset(keys(output.runner_ids)) == toset(["shared", "build", "deploy", "cluster"])
    error_message = "The stack does not register one runner per pool: shared, build, deploy and cluster."
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
  # tacplus-dev/build (#26): its trigger's token is the looper project's (88136765) BUILD_TRIGGER_TOKEN, and a nightly
  # schedule per repository of nightly-builds.yaml, tacplus-dev/looper first, then tacplus-dev/website (#31), each at
  # its own hour, with the inputs repo and nightly.
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
    condition     = output.build.schedules["looper"] == { cron = "0 5 * * *", inputs = { repo = "looper", nightly = "true" } }
    error_message = "tacplus-dev/looper has no nightly schedule on tacplus-dev/build with the inputs repo and nightly: true."
  }
  assert {
    condition     = output.build.schedules["website"] == { cron = "0 6 * * *", inputs = { repo = "website", nightly = "true" } }
    error_message = "tacplus-dev/website (pinned by build.lock, website#2) has no nightly schedule on tacplus-dev/build (#31)."
  }
  assert {
    condition     = length(distinct([for s in output.build.schedules : s.cron])) == length(output.build.schedules)
    error_message = "Two nightly schedules share a cron: each repository's nightly takes an hour of its own."
  }
  assert {
    condition     = alltrue([for k, s in output.build.schedules : s.inputs == { repo = k, nightly = "true" }])
    error_message = "A nightly schedule's inputs are not its repository and nightly: true."
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
    }
    members = {
      "tacplus-dev/build:tacplus-looper-bot" = { access_level = "reporter", expires_at = "2027-10-01" }
    }
    build = {
      project   = "tacplus-dev/build"
      ci_file   = { content = "stages: [build]\n", commit_message = "ci/build.gitlab-ci.yml at tacplus-dev/looper@abc" }
      trigger   = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
      schedules = { looper = { cron = "0 5 * * *", inputs = { repo = "looper", nightly = "true" } } }
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
    condition     = google_secret_manager_secret_version.runner_token["proj"].secret == "projects/tacplus-ci/secrets/runner-token-proj"
    error_message = "A runner's token does not go to its pool's secret."
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
