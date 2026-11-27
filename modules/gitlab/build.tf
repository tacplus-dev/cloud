# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# tacplus-dev/build, the build pipeline (#26; tacplus-dev/looper#71, #84): its .gitlab-ci.yml, its pipeline trigger,
# whose token is the looper project's BUILD_TRIGGER_TOKEN, and its schedules. Every secret is created and rotated by a
# pipeline (tacplus-dev/roadmap decisions/secrets-by-pipeline-2026-11-05.md): the trigger's token is made here, never
# seen by anyone, and a commit of a later rotate_by replaces it; its runner settings, the project adopted (#35); and
# its job token allowlist and its downstream triggers (#117).

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

# Its settings (#82): what looper-build reads from the build project's variables, BUILD_GATES_REQUESTS_<repo> (a
# repository's gates job's requests and limits, tacplus-dev/looper#202). No secret, so neither protected nor masked:
# the plan job reads them on every ref it builds.
resource "gitlab_project_variable" "build" {
  for_each          = var.build == null ? {} : var.build.variables
  project           = local.other_project_id[var.build.project]
  key               = each.key
  value             = each.value
  protected         = false
  masked            = false
  raw               = true
  environment_scope = "*"
}

# Its job token allowlist (#117; tacplus-dev/looper#262): fleet-seatrials' deploy reads the release records
# (release-<repo>/main/record, a generic package of build) with its own JOB-TOKEN. One entry per reader, not the whole
# list (gitlab_project_job_token_scopes would remove every entry made by hand). A job token has its job's user's
# permissions too: that user must be at least a Reporter of build (a member of tacplus-dev is, by inheritance).
resource "gitlab_project_job_token_scope" "build" {
  for_each          = var.build == null ? toset([]) : toset(var.build.job_token_readers)
  project           = local.other_project_id[var.build.project]
  target_project_id = tonumber(local.other_project_id[each.key])
}

# Its downstream triggers (#117; tacplus-dev/looper#262): a pipeline trigger of another project, which a build job
# starts (main's release-report starts fleet-seatrials' pipeline once a main record moves), its token build's own
# protected, masked variable, rotated as build's trigger is. Its owner is the token's user, tacplus-dev's group bot,
# and the pipelines it starts run as that user. The variable is scoped to one environment, and that environment is
# protected: only a job on a protected ref, of a Maintainer, declaring it (release-report's
# environment: {name: seatrials-trigger, action: access}) receives the token, and no other job of build, the gates
# job, which runs a repository's own code, least of all.
locals {
  downstream_triggers = var.build == null ? {} : var.build.downstream_triggers
}

resource "terraform_data" "downstream_trigger_rotation" {
  for_each = local.downstream_triggers
  input    = each.value.rotate_by
}

resource "gitlab_pipeline_trigger" "downstream" {
  for_each    = local.downstream_triggers
  project     = local.other_project_id[each.value.project]
  description = "${each.value.description} (tacplus-dev/cloud, rotated by ${each.value.rotate_by})"
  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.downstream_trigger_rotation[each.key]]
  }
}

resource "gitlab_project_variable" "downstream_trigger" {
  for_each          = local.downstream_triggers
  project           = local.other_project_id[var.build.project]
  key               = each.value.variable_key
  value             = gitlab_pipeline_trigger.downstream[each.key].token
  protected         = true
  masked            = true
  raw               = true
  environment_scope = each.value.environment_scope
}

resource "gitlab_project_protected_environment" "downstream" {
  for_each                       = local.downstream_triggers
  project                        = local.other_project_id[var.build.project]
  environment                    = each.value.environment_scope
  deploy_access_levels_attribute = [{ access_level = "maintainer" }]
}

# A schedule's inputs must be declared by the build file (GitLab refuses a pipeline with an undeclared input), so a new
# input's schedule is created after the file that declares it (#112).
resource "gitlab_pipeline_schedule" "build" {
  for_each      = var.build == null ? {} : var.build.schedules
  project       = local.other_project_id[var.build.project]
  description   = each.key
  ref           = "refs/heads/main"
  cron          = each.value.cron
  cron_timezone = "UTC"
  active        = true
  inputs        = [for name, value in each.value.inputs : { name = name, value = value }]
  depends_on    = [gitlab_repository_file.build_ci]
}
