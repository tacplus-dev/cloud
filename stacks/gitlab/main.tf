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
  build_ci_commit = "fc6e0f1349072c3a18f24897bb78da040215b3ff"
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
    # fleet-seatrials' pipeline user reads tacplus-dev/build's release records (#117): a job token has its job's user's
    # permissions, so that user must be at least a Reporter of build. Its triggered pipelines run as the trigger's
    # owner, this stack's token user (tacplus-dev's group bot, Owner), and any member of tacplus-dev is a Reporter of
    # build by inheritance (GitLab refuses a project membership below an inherited one): no entry. Its daily schedule,
    # which the hub has still to make (fleet-seatrials' docs/deploy-pipeline.md, The daily schedule), runs as its
    # owner: a member of tacplus-dev, or, if it is ever a user of fleet-seatrials alone, an entry here,
    # "tacplus-dev/build:<user>", Reporter, a year's expiry.
  }
  # tacplus-dev/build (#26; tacplus-dev/looper#71, #84): its runner settings (group runners on, shared off, #35: its jobs
  # are tagged build, which only tacplus-dev's group runners take); its .gitlab-ci.yml, tacplus-dev/looper's
  # ci/build.gitlab-ci.yml at local.build_ci_commit (files/, which ci/build-ci.sh checks and lints before every plan);
  # its pipeline trigger, whose token is the looper project's (88136765, tacplus-dev/looper) protected, masked
  # BUILD_TRIGGER_TOKEN, for its reports' and managers' build jobs; and its schedules (local.nightly_builds): the nightly
  # that builds every pinned repository (#67) and the branch releases' two (#112). The trigger rotates every 90 days:
  # the drift job's expiry check reports its rotate_by from 30 days before, and a commit of a date 90 days later
  # replaces it.
  build = {
    project = "tacplus-dev/build"
    ci_file = {
      content        = file("${path.module}/files/build.gitlab-ci.yml")
      commit_message = "ci/build.gitlab-ci.yml at tacplus-dev/looper@${local.build_ci_commit}, by tacplus-dev/cloud's gitlab stack"
    }
    trigger   = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-02-05", variable_project = "88136765", variable_key = "BUILD_TRIGGER_TOKEN" }
    schedules = local.nightly_builds
    # tacplus's gates were OOM-killed in the runner's default 8Gi pod (#82): its gates job gets the 12Gi the build runner
    # allows (its ceilings 3500m 12Gi) as its memory limit, "<cpu> <memory> <cpu limit> <memory limit>"
    # (tacplus-dev/looper#202), and the 3500m ceiling as its CPU limit (#83: at 2 CPU its gates ran 4404 s against
    # ~3300-3600 s, `test` 488 s against 192 s, and the timing-bound legs failed). Its requests are 3 CPU and 10Gi (#87):
    # a request must fit a c4a-standard-4 spot node's allocatable after its DaemonSets, and 3500m 12Gi scheduled on
    # none; only the limits may be the ceilings, to which it bursts on an otherwise empty node (ci/policy.sh refuses a
    # larger request). Every other repository's keeps the defaults.
    variables = { BUILD_GATES_REQUESTS_tacplus = "3 10Gi 3500m 12Gi" }
    # fleet-seatrials rolls dev to each green main release by digest (#117; tacplus-dev/looper#262,
    # tacplus-dev/fleet-seatrials#82): its deploy reads release-<repo>/main/record, and release-tacplus/main/record,
    # with its own JOB-TOKEN, which build's job token allowlist admits.
    job_token_readers = ["tacplus-dev/fleet-seatrials"]
    # Once tacplus-dev/fleet-seatrials#82 is live (until then a triggered pipeline deploys from source, not by digest),
    # its trigger, whose token main's release-report reads to start seatrials' pipeline after a record moves, scoped to
    # the protected environment seatrials-trigger, which only that job declares (#117, the hub's decision of
    # 2026-11-26), rotated every 90 days as build's own: the entry seatrials, its project tacplus-dev/fleet-seatrials,
    # its description "BUILD_SEATRIALS_TRIGGER_TOKEN of tacplus-dev/build", its rotate_by 90 days after it lands, its
    # variable_key BUILD_SEATRIALS_TRIGGER_TOKEN and its environment_scope seatrials-trigger.
    downstream_triggers = {}
  }
  # The in-cluster runners, every runner this stack registers. The tacplus-ci pools' (shared, build, deploy and cluster),
  # which replaced jody1-328023's on 2026-11-10, were deleted with their pools and manager (#113, Jody 2026-11-25: "make
  # sure you have all the dead stuff cut"): nothing had run on them for a day, and every tag they carried is an
  # in-cluster runner's (cloud, cluster and deploy infra's below, arm64 and build tacplus-dev/cluster's build runner's)
  # but the dead ones: autoscale and autoscale-16, and build-docker, a host-Docker publish's, which waits for a builder
  # image with rootless BuildKit (tacplus-dev/tacplus#315).
  runners = {
    # The in-cluster infra runner (#64; tacplus-dev/cluster#25, its gitlab-runner/runners/infra.yaml): the cloud, cluster
    # and deploy pipelines' jobs, on protected refs only, in the dev cluster, so the runner VMs can go (#11). Registered
    # here, by nobody else, paused until the switch-over (#66; cluster's README, The infra runner), which unpaused it
    # and paused the cluster and deploy pools, which carried the same tags, in the same commit (#113 deleted them). Its token is the
    # first version of the dev stack's secret gitlab-runner-infra, the version its file names, written by this
    # pipeline, so that no person or agent ever types it; cluster-admin-pipeline alone reads it.
    # The in-cluster kick runner (#81; tacplus-dev/cluster#36, its gitlab-runner/runners/kick.yaml): the looper's kicker
    # and plan alone, so one always runs while the control runner's slots are full of reports. Tags arm64 and kick, not
    # control: GitLab gives a runner every job whose tags are a subset of its own, so one holding control would take the
    # reports too and fill up as control does; control, lacking kick, never takes kick's jobs. Any ref (the kicker and
    # plan run on main's schedules, as the looper's other control jobs), unpaused: no job carries kick until
    # tacplus-dev/looper moves them to it, after cluster's pipeline has applied the runner. Its token, as infra's, the
    # first version of the dev stack's gitlab-runner-kick, written by this pipeline; cluster-admin-pipeline alone reads it.
    # The in-cluster build-report runner (#93; tacplus-dev/cluster#42, its gitlab-runner/runners/build-report.yaml): the
    # report builds alone (every build but a manager's land: tacplus-dev/looper#209, tacplus-dev/build's BUILD_REPORT_TAGS),
    # whose pods run below a land's build's and are preempted by them. Tags arm64 and build-report, not build: GitLab
    # gives a runner every job whose tags are a subset of its own, so one holding build would take a land's jobs too, at
    # the report builds' priority; build, lacking build-report, never takes a report's. Any ref, unpaused: no job carries
    # build-report until the hub sets BUILD_REPORT_TAGS, after cluster's pipeline has applied the runner. Its token, as
    # kick's, the first version of the dev stack's gitlab-runner-build-report, written by this pipeline.
    # The in-cluster build-light runner (#100; tacplus-dev/cluster#51, its gitlab-runner/runners/build-light.yaml): on the
    # normal pool, tacplus-dev/build's light jobs alone (pending, plan, report-pass and report-fail: looper-build in the
    # looper image, seconds to a minute; tacplus-dev/looper#224), which on the build runner held its slots (on 2026-11-23
    # 42 pending and 42 plan jobs waited behind its 6, and a land's candidate 77 minutes at its first job). Tags arm64
    # and build-light, not build: GitLab gives a runner every job whose tags are a subset of its own, so one holding
    # build would take the gates and security jobs onto the normal pool; build, lacking build-light, never takes a
    # light job. Any ref, unpaused: no job carries build-light until files/build.gitlab-ci.yml does, after cluster's
    # pipeline has applied the runner. Its token, as kick's, the first version of the dev stack's
    # gitlab-runner-build-light, written by this pipeline.
    # The in-cluster manager runner (#106; tacplus-dev/cluster#60, its gitlab-runner/runners/manager.yaml): on the normal
    # (always-on) pool, the looper's managers alone (tacplus-dev/looper#236's .manager), which on the control runner
    # waited for its slots behind the reports (on 2026-11-24 at 19:59Z five managers were pending behind 17 slots full),
    # and while a manager waits nothing merges in its repository. Tags arm64 and manager, not control: GitLab gives a
    # runner every job whose tags are a subset of its own, so one holding control would take the reports too and fill up
    # as control does; control, lacking manager, never takes a manager. Any ref, unpaused: no job carries manager until
    # tacplus-dev/looper tags its managers so, after cluster's pipeline has applied the runner. Its token, as kick's, the
    # first version of the dev stack's gitlab-runner-manager, written by this pipeline.
    # The in-cluster nightly runner (#116; tacplus-dev/cluster#46, its gitlab-runner/runners/nightly.yaml): on the spot
    # pool, the nightly fan-out's jobs alone (tacplus-dev/build's BUILD_NIGHTLY_TAGS), whose pods run at cluster's
    # PriorityClass build-nightly, above the report builds' (on 2026-11-21/22 10 of 31 repositories' security jobs waited
    # Pending behind them and published nothing) and below a land's build's. Tags arm64 and build-nightly, not build:
    # GitLab gives a runner every job whose tags are a subset of its own, so one holding build would take a land's jobs
    # too, at the nightly's priority. Any ref, unpaused: no job carries build-nightly until tacplus-dev/looper#220 sets
    # BUILD_NIGHTLY_TAGS, after cluster's pipeline has applied the runner. Its token, as kick's, the first version of the
    # dev stack's gitlab-runner-nightly, written by this pipeline. Interim: it goes with the spot pool (#114).
    infra = local.infra_runner, kick = local.kick_runner, build-report = local.build_report_runner, build-light = local.build_light_runner, manager = local.manager_runner, nightly = local.nightly_runner
  }
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
  build_report_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["arm64", "build-report"]
    protected    = false
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-build-report"
    description  = "tacplus-dev build-report (tacplus-dev/cloud: the cluster, spot pool; report builds alone, preempted by a land's)"
  }
  build_light_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["arm64", "build-light"]
    protected    = false
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-build-light"
    description  = "tacplus-dev build-light (tacplus-dev/cloud: the cluster, normal pool; tacplus-dev/build's pending, plan and report jobs alone)"
  }
  manager_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["arm64", "manager"]
    protected    = false
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-manager"
    description  = "tacplus-dev manager (tacplus-dev/cloud: the cluster, normal pool; the looper's managers alone)"
  }
  nightly_runner = {
    type         = "group_type"
    group        = "tacplus-dev"
    project      = null
    tags         = ["arm64", "build-nightly"]
    protected    = false
    paused       = false
    token_secret = "projects/${module.settings.projects.dev.project}/secrets/gitlab-runner-nightly"
    description  = "tacplus-dev nightly (tacplus-dev/cloud: the cluster, spot pool; the nightly fan-out's jobs alone, above report builds, below a land's)"
  }
}

# The nightly builds of tacplus-dev/build (#26, #33, #67; tacplus-dev/looper#84, #164): one pipeline schedule on
# tacplus-dev/build's main with the input nightly: true and no repo, whose pipeline lists the tacplus-dev repositories
# that pin a build image (a tacplus.lock or a build.lock on main) and runs each one's nightly in a child pipeline of its
# own (tacplus-dev/looper ci/build.gitlab-ci.yml): every pinned repository, at 03:00 UTC, with no list here. It replaced
# #33's schedule per repository, of which GitLab's 10 a project kept ten (#65): the apply that made this one deleted
# them. The module still refuses more than 10.
#
# The branch releases (#112; tacplus-dev/looper#252, its README, Release builds by branch): two more, on main with no
# repo either. release-main, nightly at 08:00 UTC, after the nightly's 03:00: every pinned repository's main, each
# building the commit its main-green names (the rolling check's, tacplus-dev/looper#249), skipped when that is its
# release already or when there is none; it holds the nightly's nightly-slot-<n> resource groups and tags, so an
# overlap queues rather than fails. release-branches, every 3 hours at :30 (clear of 03:00, 08:00 and the audit's :07):
# each release/X.Y branch whose head is not its release's, and with nothing new a pipeline of one job, nothing-new. A
# "build main now" is no schedule: the trigger's API run with {"repo": "<repo>", "release": "main"}. Their input,
# release, is declared by files/build.gitlab-ci.yml from tacplus-dev/looper's b6f80ed on, and its plan needs the image
# b40b42b pins (tacplus-dev/looper#261: main-7c1dc4d, with #252's looper-build); the module creates the schedules after
# the file.
locals {
  nightly_builds = {
    nightly          = { cron = "0 3 * * *", inputs = { nightly = "true" } }
    release-main     = { cron = "0 8 * * *", inputs = { release = "main" } }
    release-branches = { cron = "30 1-23/3 * * *", inputs = { release = "branches" } }
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

output "build_schedules" {
  value = module.gitlab.build_schedules
}

output "build_runners" {
  value = module.gitlab.build_runners
}
