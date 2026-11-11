# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# tacplus-dev/build, the build pipeline (#26; tacplus-dev/looper#71, #84): its .gitlab-ci.yml, its pipeline trigger,
# whose token is the looper project's BUILD_TRIGGER_TOKEN, and its schedules. Every secret is created and rotated by a
# pipeline (tacplus-dev/roadmap decisions/secrets-by-pipeline-2026-11-05.md): the trigger's token is made here, never
# seen by anyone, and a commit of a later rotate_by replaces it; and its runner settings, the project adopted (#35).

locals {
  build = var.build == null ? {} : { build = var.build }
}

# Its runner settings (#35): its build jobs are tagged `build`, which only tacplus-dev's group runners take (the pools,
# none of them a project runner of it), so group runners are on, and gitlab.com's shared runners off. With them off,
# every build job waited 1.5 h and failed stuck_pending_no_matching_runners. Only gitlab_project sets them: the
# project is adopted (the stack's import block, by its ID), never created or deleted here, and this owns nothing else
# of it: every other attribute the provider reads back and would otherwise reset is ignored.
resource "gitlab_project" "build" {
  for_each               = local.build
  name                   = basename(each.value.project)
  group_runners_enabled  = true
  shared_runners_enabled = false
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      name, path, namespace_id, description, archived, ci_config_path, issues_template, issue_branch_template,
      merge_requests_template, resolve_outdated_diff_discussions, external_authorization_classification_label,
      suggestion_commit_message, squash_commit_template, merge_commit_template, mr_default_title_template,
      forked_from_project_id, mr_default_target_self,
    ]
  }
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
