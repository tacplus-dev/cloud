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
  # Registered paused: moving the runners off jody1-328023 is a later issue, which unpauses them.
  runners = {
    for k, p in module.settings.runner_pools : k => merge(p.runner, {
      paused       = true
      token_secret = "projects/${module.settings.projects.ci.project}/secrets/runner-token-${k}"
    })
  }
}

# What the hub set before the pipeline's first run (README, Before the first pipeline): adopted, not created.
variable "import_existing" {
  description = "Adopt the settings the hub made by hand (the import blocks below). False only in the tests: a mock provider cannot import."
  type        = bool
  default     = true
}

import {
  for_each = var.import_existing ? toset(["main"]) : toset([])
  to       = module.gitlab.gitlab_branch_protection.branch["${local.cloud}:${each.key}"]
  id       = "${local.cloud}:${each.key}"
}

import {
  for_each = var.import_existing ? toset(["GCP_WIF_PROVIDER"]) : toset([])
  to       = module.gitlab.gitlab_project_variable.variable["${local.cloud}:${each.key}"]
  id       = "${local.cloud}:${each.key}:*"
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
