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

output "app_keys" {
  description = "Each GitHub App's KMS key (import-only, no version until its app's key is imported), by name."
  value       = { for k, key in google_kms_crypto_key.app : k => "${google_kms_key_ring.looper.id}/cryptoKeys/${key.name}" }
}

output "app_key_ring" {
  description = "The apps' key ring (projects/P/locations/L/keyRings/R): the looper project's LOOPER_KMS_KEYRING."
  value       = google_kms_key_ring.looper.id
}

output "app_import_jobs" {
  description = "Each import job, by the key it imports into."
  value       = { for k, j in google_kms_key_ring_import_job.app : k => local.app_import_names[k] }
}

output "app_accounts" {
  description = "The accounts that sign for a key (#30), each email by account ID: a TACPLUS_READER_SA, say."
  value       = { for id, a in google_service_account.app : id => a.email }
}

output "looper_wif_provider" {
  description = "The looper project's provider (projects/N/locations/global/workloadIdentityPools/P/providers/R): its GCP_WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.looper.name
}

output "manager" {
  description = "The runner manager's name, runner-manager-<its build's hash> (#46): a new build is a new manager."
  value       = google_compute_instance.manager.name
}
