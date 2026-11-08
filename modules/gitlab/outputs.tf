# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_ids" {
  description = "The GitLab projects' IDs, by path."
  value       = local.project_id
}

output "runner_ids" {
  description = "The runners' IDs, by pool."
  value       = { for k, r in gitlab_user_runner.runner : k => r.id }
}

output "members" {
  description = "The memberships, by PROJECT:USER: the project's and the user's IDs, the access level and the expiry."
  value = { for k, m in gitlab_project_membership.member : k => {
    project = m.project, user_id = m.user_id, access_level = m.access_level, expires_at = m.expires_at
  } }
}

output "build" {
  description = "tacplus-dev/build's (#26), or null: the project's ID, the trigger's ID, the variable holding its token (project and key), and the schedules, by name: their cron and inputs."
  value = var.build == null ? null : {
    project    = local.other_project_id[var.build.project]
    trigger_id = gitlab_pipeline_trigger.build["build"].pipeline_trigger_id
    variable   = { project = gitlab_project_variable.build_trigger["build"].project, key = gitlab_project_variable.build_trigger["build"].key }
    schedules  = { for k, s in gitlab_pipeline_schedule.build : k => { cron = s.cron, inputs = { for i in s.inputs : i.name => i.value } } }
  }
}
