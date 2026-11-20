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
  build_ci_commit = "e87715023ffb33b8cca97a35611deadfe935ae69"
}

module "gitlab" {
  source = "../../modules/gitlab"
  projects = {
    (local.cloud) = {
      create                 = false
      protected_branches     = ["main"]
      protected_environments = ["folder", "ci", "dev", "gitlab", "anthropic"]
      variables = {
        GCP_WIF_PROVIDER = {
          value = "projects/${data.google_project.bootstrap.number}/locations/global/workloadIdentityPools/${module.settings.bootstrap.wif_pool}/providers/${module.settings.bootstrap.wif_provider}"
        }
        TACPLUS_READER_APP_ID          = { secret = "${local.secrets}/tacplus-reader-app-id/versions/1" }
        TACPLUS_READER_INSTALLATION_ID = { secret = "${local.secrets}/tacplus-reader-installation-id/versions/1" }
      }
      # The hub's audit (#77): hourly, a pipeline of the audit job alone (the CI file's rules read its description,
      # audit), whose report is the artifact the hub reads (README, The hub's audit). The nightly drift schedule is
      # still the hub's, by hand.
      schedules = {
        audit = { cron = "7 * * * *" }
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
    # tacplus-dev/cluster#18: the recap reads cluster's pipelines and jobs too (it got a 404).
    "tacplus-dev/cluster:tacplus-looper-bot" = { access_level = "reporter", expires_at = "2027-10-01" }
  }
  # tacplus-dev/build (#26; tacplus-dev/looper#71, #84): its runner settings (group runners on, shared off, #35: its jobs
  # are tagged build, which only tacplus-dev's group runners take); its .gitlab-ci.yml, tacplus-dev/looper's
  # ci/build.gitlab-ci.yml at local.build_ci_commit (files/, which ci/build-ci.sh checks and lints before every plan);
  # its pipeline trigger, whose token is the looper project's (88136765, tacplus-dev/looper) protected, masked
  # BUILD_TRIGGER_TOKEN, for its reports' and managers' build jobs; and one nightly schedule that builds every pinned
  # repository (local.nightly_builds, #67). The trigger rotates every 90 days: the drift job's expiry check reports its
  # rotate_by from 30 days before, and a commit of a date 90 days later replaces it.
  build = {
    project = "tacplus-dev/build"
    ci_file = {
      content        = file("${path.module}/files/build.gitlab-ci.yml")
      commit_message = "ci/build.gitlab-ci.yml at tacplus-dev/looper@${local.build_ci_commit}, by tacplus-dev/cloud's gitlab stack"
    }
    trigger   = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
    schedules = local.nightly_builds
    # tacplus's gates were OOM-killed in the runner's default 8Gi pod (#82): its gates job gets the 12Gi the build runner
    # allows (its ceilings 3500m 12Gi), "<cpu> <memory> <cpu limit> <memory limit>" (tacplus-dev/looper#202), and the
    # 3500m ceiling as its CPU request too (#83: at 2 CPU its gates ran 4404 s against ~3300-3600 s, `test` 488 s
    # against 192 s, and the timing-bound legs failed). Every other repository's keeps the defaults.
    variables = { BUILD_GATES_REQUESTS_tacplus = "3500m 12Gi 3500m 12Gi" }
  }
  # The pools replaced jody1-328023's runners (2026-11-10, Jody: nothing stays in the thescottsweb.com org): shared (the
  # loopers' always-on node) and build (on demand, from zero) take jobs; deploy (fleet-seatrials') and cluster
  # (tacplus-dev/cluster's and this repository's own pipeline) are paused since the switch-over (#66), infra below
  # taking their tags' jobs, until #11 removes them and their VMs. Pausing stops new pickups, not a running job.
  runners = merge(
    {
      for k, p in module.settings.runner_pools : k => merge(p.runner, {
        paused       = contains(["cluster", "deploy"], k)
        token_secret = "projects/${module.settings.projects.ci.project}/secrets/runner-token-${k}"
      })
    },
    # The in-cluster infra runner (#64; tacplus-dev/cluster#25, its gitlab-runner/runners/infra.yaml): the cloud, cluster
    # and deploy pipelines' jobs, on protected refs only, in the dev cluster, so the runner VMs can go (#11). Registered
    # here, by nobody else, paused until the switch-over (#66; cluster's README, The infra runner), which unpaused it
    # and paused the cluster and deploy pools above, which carry the same tags, in the same commit. Its token is the
    # first version of the dev stack's secret gitlab-runner-infra, the version its file names, written by this
    # pipeline, so that no person or agent ever types it; cluster-admin-pipeline alone reads it.
    # The in-cluster kick runner (#81; tacplus-dev/cluster#36, its gitlab-runner/runners/kick.yaml): the looper's kicker
    # and plan alone, so one always runs while the control runner's slots are full of reports. Tags arm64 and kick, not
    # control: GitLab gives a runner every job whose tags are a subset of its own, so one holding control would take the
    # reports too and fill up as control does; control, lacking kick, never takes kick's jobs. Any ref (the kicker and
    # plan run on main's schedules, as the looper's other control jobs), unpaused: no job carries kick until
    # tacplus-dev/looper moves them to it, after cluster's pipeline has applied the runner. Its token, as infra's, the
    # first version of the dev stack's gitlab-runner-kick, written by this pipeline; cluster-admin-pipeline alone reads it.
    { infra = local.infra_runner, kick = local.kick_runner },
  )
}

locals {
  infra_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["cloud", "cluster", "deploy"]
    protected    = true
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-infra"
    description  = "tacplus-dev infra (tacplus-dev/cloud: the cluster, ci namespace, normal pool; protected refs; cloud, cluster and deploy pipelines)"
  }
  kick_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["arm64", "kick"]
    protected    = false
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-kick"
    description  = "tacplus-dev kick (tacplus-dev/cloud: the cluster, normal pool; the looper's kicker and plan alone)"
  }
}

# The nightly builds of tacplus-dev/build (#26, #33, #67; tacplus-dev/looper#84, #164): one pipeline schedule on
# tacplus-dev/build's main with the input nightly: true and no repo, whose pipeline lists the tacplus-dev repositories
# that pin a build image (a tacplus.lock or a build.lock on main) and runs each one's nightly in a child pipeline of its
# own (tacplus-dev/looper ci/build.gitlab-ci.yml): every pinned repository, at 03:00 UTC, with no list here. It replaced
# #33's schedule per repository, of which GitLab's 10 a project kept ten (#65): the apply that made this one deleted
# them. The module still refuses more than 10.
locals {
  nightly_builds = {
    nightly = { cron = "0 3 * * *", inputs = { nightly = "true" } }
  }
}

# The new schedule is looper's of the ten, changed in place (its description, cron and inputs: the provider drops repo),
# and the other nine are deleted: a create would run beside those deletes, not after them (OpenTofu orders them by
# dependencies only), and GitLab refuses an 11th schedule while the ten are there. With no looper schedule in the state
# (a fresh state, the tests), this moves nothing and the schedule is created.
moved {
  from = module.gitlab.gitlab_pipeline_schedule.build["looper"]
  to   = module.gitlab.gitlab_pipeline_schedule.build["nightly"]
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

# tacplus-dev/build itself (#35), for its runner settings: group runners on, which the hub set by hand on 2026-11-09
# after every build job had found no runner (tacplus-dev/looper#113), shared runners off. Adopted by its ID, never
# destroyed (the module's prevent_destroy).
import {
  for_each = var.import_existing ? toset(["build"]) : toset([])
  to       = module.gitlab.gitlab_project.build[each.key]
  id       = module.gitlab.build.project
}

# The cluster pool's runner on tacplus-dev/cloud, which the hub enabled by hand on 2026-11-10 while jody1-328023's
# runner for this repository stopped taking jobs: adopted, from then on this stack's. GitLab refuses to enable a
# locked runner on a second project, so the adoption is how this one stays locked.
variable "adopt_cluster_enablement" {
  description = "Adopt the hand-made enablement above. False only where the cluster runner is not yet in state (tests/gitlab_plan_test.sh plans from empty state), since the import's ID is the runner's."
  type        = bool
  default     = true
}

import {
  for_each = var.import_existing && var.adopt_cluster_enablement ? toset(["cluster:tacplus-dev/cloud"]) : toset([])
  to       = module.gitlab.gitlab_project_runner_enablement.also[each.key]
  id       = "${module.gitlab.project_ids[local.cloud]}:${module.gitlab.runner_ids["cluster"]}"
}

output "project_ids" {
  value = module.gitlab.project_ids
}

output "runner_ids" {
  value = module.gitlab.runner_ids
}

output "runners" {
  value = module.gitlab.runners
}

output "schedules" {
  value = module.gitlab.schedules
}

output "members" {
  value = module.gitlab.members
}

output "build" {
  value = module.gitlab.build
}

output "build_runners" {
  value = module.gitlab.build_runners
}
