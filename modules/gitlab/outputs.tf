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
