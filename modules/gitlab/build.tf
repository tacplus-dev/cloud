# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# tacplus-dev/build, the build pipeline (#26; tacplus-dev/looper#71, #84): its .gitlab-ci.yml, its pipeline trigger,
# whose token is the looper project's BUILD_TRIGGER_TOKEN, and its schedules. Every secret is created and rotated by a
# pipeline (tacplus-dev/roadmap decisions/secrets-by-pipeline-2026-11-05.md): the trigger's token is made here, never
# seen by anyone, and a commit of a later rotate_by replaces it.

locals {
  build = var.build == null ? {} : { build = var.build }
}

# tacplus-dev/looper's ci/build.gitlab-ci.yml, as is, on the build project's main (the plan job lints it first,
# ci/build-ci.sh).
resource "gitlab_repository_file" "build_ci" {
  for_each       = { for k, b in local.build : k => b.ci_file if b.ci_file != null }
  project        = local.other_project_id[var.build.project]
  branch         = "main"
  file_path      = ".gitlab-ci.yml"
  encoding       = "text"
  content        = each.value.content
  commit_message = each.value.commit_message
}

# The rotation: a change of rotate_by replaces the trigger. The new token is the variable's before the old trigger is
# deleted, so a build started in between is refused at most once.
resource "terraform_data" "build_trigger_rotation" {
  for_each = local.build
  input    = each.value.trigger.rotate_by
}

resource "gitlab_pipeline_trigger" "build" {
  for_each    = local.build
  project     = local.other_project_id[each.value.project]
  description = "${each.value.trigger.description} (tacplus-dev/cloud, rotated by ${each.value.trigger.rotate_by})"
  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.build_trigger_rotation[each.key]]
  }
}

resource "gitlab_project_variable" "build_trigger" {
  for_each          = local.build
  project           = each.value.trigger.variable_project
  key               = each.value.trigger.variable_key
  value             = gitlab_pipeline_trigger.build[each.key].token
  protected         = true
  masked            = true
  raw               = true
  environment_scope = "*"
}

resource "gitlab_pipeline_schedule" "build" {
  for_each      = var.build == null ? {} : var.build.schedules
  project       = local.other_project_id[var.build.project]
  description   = each.key
  ref           = "refs/heads/main"
  cron          = each.value.cron
  cron_timezone = "UTC"
  active        = true
  inputs        = [for name, value in each.value.inputs : { name = name, value = value }]
}
