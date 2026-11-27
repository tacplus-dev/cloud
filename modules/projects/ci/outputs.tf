# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_id" {
  description = "The ci project's ID."
  value       = google_project.ci.project_id
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

output "hub_audit" {
  description = "The audit job's account (#77): its email, the CI file's GCP_AUDIT_SA."
  value       = google_service_account.hub_audit.email
}

output "admiral" {
  description = "The Admiral's credentials (#84), for its Config: its account's email, its key (version 1 once imported) and its secret (projects/P/secrets/S); null without admiral."
  value = var.admiral == null ? null : {
    service_account = google_service_account.admiral["admiral"].email
    key             = "${google_kms_key_ring.looper.id}/cryptoKeys/${google_kms_crypto_key.app[var.admiral.key].name}"
    key_version     = "${google_kms_key_ring.looper.id}/cryptoKeys/${google_kms_crypto_key.app[var.admiral.key].name}/cryptoKeyVersions/1"
    secret          = "projects/${google_project.ci.project_id}/secrets/${google_secret_manager_secret.admiral["admiral"].secret_id}"
  }
}

output "looper_vms" {
  description = "Each looper VM's group (#108), by repository: its name and zone, which the kicker resizes, and its account's email."
  value       = { for k, g in google_compute_instance_group_manager.looper_vm : k => { group = g.name, zone = g.zone, service_account = google_service_account.looper_vm[k].email } }
}

output "reserved_vms" {
  description = "Each reserved machine's group (#111), by name: its name and zone, and its account's email."
  value       = { for k, g in merge(google_compute_instance_group_manager.reserved_vm, google_compute_instance_group_manager.reserved_vm_check) : k => { group = g.name, zone = g.zone, service_account = google_service_account.reserved_vm[k].email } }
}

output "releases" {
  description = "The release registry (#115): its address (<location>-docker.pkg.dev/<project>/<repository>, the build's BUILD_REGISTRY for a release), the publish account's email and its provider (projects/N/locations/global/workloadIdentityPools/P/providers/R), for tacplus-dev/build's variables, and its readers; null without releases."
  value = var.releases == null ? null : {
    registry        = "${google_artifact_registry_repository.releases[0].location}-docker.pkg.dev/${google_project.ci.project_id}/${google_artifact_registry_repository.releases[0].repository_id}"
    service_account = google_service_account.release_publish[0].email
    wif_provider    = google_iam_workload_identity_pool_provider.release[0].name
    readers         = var.releases.readers
  }
}
