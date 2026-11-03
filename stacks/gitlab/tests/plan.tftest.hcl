# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The gitlab stack's plan against a stub GitLab and stub secrets (mock providers: no token, no cloud): the stack
# plans, and its module, with the stack's inputs, gives protected settings, variables from Secret Manager by
# version, and paused runners whose tokens go to Secret Manager only. (A test sees a module's resources only when
# it runs that module itself.)

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
  }

  assert {
    condition     = gitlab_branch_protection.branch["tacplus-dev/cloud:main"].push_access_level == "maintainer" && gitlab_branch_protection.branch["tacplus-dev/cloud:main"].merge_access_level == "maintainer" && !gitlab_branch_protection.branch["tacplus-dev/cloud:main"].allow_force_push
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
