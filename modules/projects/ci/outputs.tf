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

output "runner_image_bake" {
  description = "The bake's identity and network, for tacplus-dev/build's runner-image variables: its account (GCP_RUNNER_IMAGE_SA), its provider (GCP_WIF_PROVIDER) and the subnet its VMs use (RUNNER_IMAGE_SUBNET, looper#67)."
  value = {
    service_account = google_service_account.runner_image.email
    wif_provider    = google_iam_workload_identity_pool_provider.runner_image.name
    subnet          = google_compute_subnetwork.runners.id
  }
}
