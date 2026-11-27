# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_ids" {
  description = "The GitLab projects' IDs, by path."
  value       = local.project_id
}

output "runner_ids" {
  description = "The runners' IDs, by runner."
  value       = { for k, r in gitlab_user_runner.runner : k => r.id }
}

output "runners" {
  description = "Each registration as GitLab has it (never its token): its type, the group or project ID it is registered to, its tags, whether it takes untagged jobs, its access level, whether it is paused, and the secret its token is a version of."
  value = { for k, r in gitlab_user_runner.runner : k => {
    type         = r.runner_type, group_id = r.group_id, project_id = r.project_id, tags = toset(r.tag_list), untagged = r.untagged
    access_level = r.access_level, paused = r.paused, token_secret = google_secret_manager_secret_version.runner_token[k].secret
  } }
}

output "schedules" {
  description = "The projects' pipeline schedules (#77), by PROJECT:NAME: the description, the ref, the cron, its time zone and whether it is active."
  value = { for k, s in gitlab_pipeline_schedule.project : k => {
    description = s.description, ref = s.ref, cron = s.cron, cron_timezone = s.cron_timezone, active = s.active
  } }
}

output "members" {
  description = "The memberships, by PROJECT:USER: the project's and the user's IDs, the access level and the expiry."
  value = { for k, m in gitlab_project_membership.member : k => {
    project = m.project, user_id = m.user_id, access_level = m.access_level, expires_at = m.expires_at
  } }
}

output "build" {
  description = "tacplus-dev/build's (#26), or null: the project's ID, the trigger's ID, the variable holding its token (project and key), the projects its job token allowlist admits, and its downstream triggers (#117)."
  value = var.build == null ? null : {
    project    = local.other_project_id[var.build.project]
    trigger_id = gitlab_pipeline_trigger.build["build"].pipeline_trigger_id
    variable   = { project = gitlab_project_variable.build_trigger["build"].project, key = gitlab_project_variable.build_trigger["build"].key }
    # #117: the projects its job token allowlist admits (their IDs, by path), and its downstream triggers, by name.
    job_token_readers = { for k, s in gitlab_project_job_token_scope.build : k => s.target_project_id }
    downstream_triggers = { for k, t in gitlab_pipeline_trigger.downstream : k => {
      project  = t.project
      variable = { key = gitlab_project_variable.downstream_trigger[k].key, environment_scope = gitlab_project_variable.downstream_trigger[k].environment_scope }
    } }
  }
}

# Not in build either: the stack imports the build file by build's project ID, and the schedules are created after the
# file (#112).
output "build_schedules" {
  description = "tacplus-dev/build's schedules (#67, #112), by name: their cron and inputs; empty without build."
  value       = { for k, s in gitlab_pipeline_schedule.build : k => { cron = s.cron, inputs = { for i in s.inputs : i.name => i.value } } }
}

# Not in build: the stack imports the project by build's project ID, so build cannot depend on the project (#35).
output "build_runners" {
  description = "tacplus-dev/build's runner settings (#35), or null: group runners on, shared runners off."
  value = var.build == null ? null : {
    group_runners_enabled  = gitlab_project.build["build"].group_runners_enabled
    shared_runners_enabled = gitlab_project.build["build"].shared_runners_enabled
  }
}
