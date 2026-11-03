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
