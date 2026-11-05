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
    condition     = toset(keys(output.runner_ids)) == toset(["shared", "deploy", "cluster"])
    error_message = "The stack does not register one runner per pool: shared, deploy and cluster."
  }
  # The looper's recap reads tacplus-dev/build as tacplus-looper-bot, through every looper job's GITLAB_TOKEN (#12,
  # option B): Reporter, nothing higher, and an expiry.
  assert {
    condition     = keys(output.members) == ["tacplus-dev/build:tacplus-looper-bot"]
    error_message = "The stack makes other members than tacplus-looper-bot of tacplus-dev/build."
  }
  assert {
    condition     = output.members["tacplus-dev/build:tacplus-looper-bot"].access_level == "reporter" && output.members["tacplus-dev/build:tacplus-looper-bot"].user_id == 99 && output.members["tacplus-dev/build:tacplus-looper-bot"].project == "77"
    error_message = "tacplus-looper-bot is not a Reporter (20) of tacplus-dev/build."
  }
  assert {
    condition     = can(regex("^20[0-9]{2}-[01][0-9]-[0-3][0-9]$", output.members["tacplus-dev/build:tacplus-looper-bot"].expires_at))
    error_message = "tacplus-looper-bot's membership of tacplus-dev/build has no expiry."
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
        protected_environments = ["folder", "ci", "dev", "gitlab"]
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
  }

  assert {
    condition     = [for a in gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allowed_to_push : a.access_level] == ["maintainer"] && [for a in gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allowed_to_merge : a.access_level] == ["maintainer"] && !gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allow_force_push
    error_message = "main is not protected: Maintainers push and merge, nobody force-pushes."
  }
  assert {
    condition     = toset(keys(gitlab_project_protected_environment.environment)) == toset(["tacplus-dev/cloud:folder", "tacplus-dev/cloud:ci", "tacplus-dev/cloud:dev", "tacplus-dev/cloud:gitlab"])
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
