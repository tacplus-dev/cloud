# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# GitLab settings. The provider's token is GITLAB_TOKEN, which ci/tofu.sh reads from Secret Manager
# (module.settings.bootstrap.gitlab_token_secret, by version) for this stack alone.

module "settings" {
  source = "../../modules/settings"
}

provider "google" {
  region = module.settings.region
}

provider "gitlab" {}

data "google_project" "bootstrap" {
  project_id = module.settings.bootstrap.project
}

locals {
  cloud   = module.settings.gitlab_project
  secrets = "projects/${module.settings.bootstrap.project}/secrets"
  # The tacplus-dev/looper commit whose ci/build.gitlab-ci.yml files/build.gitlab-ci.yml is (ci/build-ci.sh).
  build_ci_commit = "09316ea026e47d31a9926750c3ad07598727af15"
}

module "gitlab" {
  source = "../../modules/gitlab"
  projects = {
    (local.cloud) = {
      create                 = false
      protected_branches     = ["main"]
      protected_environments = ["folder", "ci", "dev", "gitlab"]
      variables = {
        GCP_WIF_PROVIDER = {
          value = "projects/${data.google_project.bootstrap.number}/locations/global/workloadIdentityPools/${module.settings.bootstrap.wif_pool}/providers/${module.settings.bootstrap.wif_provider}"
        }
        TACPLUS_READER_APP_ID          = { secret = "${local.secrets}/tacplus-reader-app-id/versions/1" }
        TACPLUS_READER_INSTALLATION_ID = { secret = "${local.secrets}/tacplus-reader-installation-id/versions/1" }
      }
    }
  }
  # The looper's nightly recap reads tacplus-dev/build's pipelines as tacplus-looper-bot, a free bot account, with
  # every looper job's GITLAB_TOKEN (#12, Jody's option B: tacplus-dev/build's code is public and its jobs and
  # artifacts hold no secret, so Reporter read for every looper job adds little; if its artifacts ever carry anything
  # sensitive, this becomes a bot of the recap's own). Free gitlab.com has no project access tokens. Reporter (20),
  # nothing higher; the expiry is the bot's token's (looper-jobs, 2027-10-01), renewed by a commit with it.
  members = {
    "tacplus-dev/build:tacplus-looper-bot" = { access_level = "reporter", expires_at = "2027-10-01" }
  }
  # tacplus-dev/build (#26; tacplus-dev/looper#71, #84): its .gitlab-ci.yml, tacplus-dev/looper's
  # ci/build.gitlab-ci.yml at local.build_ci_commit (files/, which ci/build-ci.sh checks and lints before every plan);
  # its pipeline trigger, whose token is the looper project's (88136765, tacplus-dev/looper) protected, masked
  # BUILD_TRIGGER_TOKEN, for its reports' and managers' build jobs; and a nightly schedule per pinned repository
  # (nightly-builds.yaml). The trigger rotates every 90 days: the drift job's expiry check reports its rotate_by from 30
  # days before, and a commit of a date 90 days later replaces it.
  build = {
    project = "tacplus-dev/build"
    ci_file = {
      content        = file("${path.module}/files/build.gitlab-ci.yml")
      commit_message = "ci/build.gitlab-ci.yml at tacplus-dev/looper@${local.build_ci_commit}, by tacplus-dev/cloud's gitlab stack"
    }
    trigger   = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
    schedules = yamldecode(file("${path.module}/nightly-builds.yaml"))
  }
  # Every pool takes jobs (2026-11-10, Jody: nothing stays in the thescottsweb.com org): shared (the loopers' three
  # always-on nodes), build (spot), deploy (fleet-seatrials') and cluster (tacplus-dev/cluster's and this
  # repository's own pipeline), replacing jody1-328023's runners.
  runners = {
    for k, p in module.settings.runner_pools : k => merge(p.runner, {
      paused       = false
      token_secret = "projects/${module.settings.projects.ci.project}/secrets/runner-token-${k}"
    })
  }
}

# What the hub set before the pipeline's first run (README, Before the first pipeline): adopted, not created. Imported by
# the project's numeric ID, the module's: imported by its path, the state's project would differ from the config's, and
# the first apply would replace what it adopts (#17; tests/gitlab_plan_test.sh).
variable "import_existing" {
  description = "Adopt the settings the hub made by hand (the import blocks below). False only in the tests: a mock provider cannot import."
  type        = bool
  default     = true
}

import {
  for_each = var.import_existing ? toset(["main"]) : toset([])
  to       = module.gitlab.gitlab_branch_protection.branch["${local.cloud}:${each.key}"]
  id       = "${module.gitlab.project_ids[local.cloud]}:${each.key}"
}

import {
  for_each = var.import_existing ? toset(["GCP_WIF_PROVIDER"]) : toset([])
  to       = module.gitlab.gitlab_project_variable.variable["${local.cloud}:${each.key}"]
  id       = "${module.gitlab.project_ids[local.cloud]}:${each.key}:*"
}

# tacplus-dev/build's .gitlab-ci.yml, which the hub copied by hand (tacplus-dev/looper README, Build pipeline): adopted,
# by the project's ID, and from then on this stack's.
import {
  for_each = var.import_existing ? toset([".gitlab-ci.yml"]) : toset([])
  to       = module.gitlab.gitlab_repository_file.build_ci["build"]
  id       = "${module.gitlab.build.project}:main:${each.key}"
}

output "project_ids" {
  value = module.gitlab.project_ids
}

output "runner_ids" {
  value = module.gitlab.runner_ids
}

output "members" {
  value = module.gitlab.members
}

output "build" {
  value = module.gitlab.build
}
