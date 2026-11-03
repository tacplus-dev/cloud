# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_id" {
  description = "The ci project's ID."
  value       = google_project.ci.project_id
}

output "runner_token_secrets" {
  description = "Each pool's runner-token secret (projects/P/secrets/S), which the gitlab stack writes."
  value       = { for k, s in google_secret_manager_secret.runner_token : k => s.id }
}

output "reader_app_key" {
  description = "The tacplus-reader app's KMS key (import-only, no version yet)."
  value       = google_kms_crypto_key.reader.id
}
