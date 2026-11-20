# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The Admiral's federation (#84; tacplus-dev/admiral#5, Jody's option A): a pool for fleet services that present
# their own kernel-signed identity, not a GitLab job's, and in it one provider for the fleet kernel's OIDC issuer
# (its keys by discovery, ES256), admitting the Admiral's SPIFFE ID alone. Its service account, key and secret are the
# ci project's (modules/projects/ci/admiral.tf), which only this provider's subject becomes. Not GKE Workload
# Identity: the Admiral's identity is its kernel's, the SPIFFE ID the platform authorizes on, not a Kubernetes service
# account's.

resource "google_iam_workload_identity_pool" "fleet_kernels" {
  count                     = var.admiral == null ? 0 : 1
  project                   = google_project.dev.project_id
  workload_identity_pool_id = var.admiral.pool
  display_name              = "fleet kernels"
  description               = "Fleet services by their kernel-signed identity (tacplus-dev/cloud)"
  depends_on                = [terraform_data.iam_ready]
}

# One issuer URL, never a pattern: every fleet's kernel may mint the same SPIFFE ID (its trust domain is every
# fleet's), so the issuer is what tells this fleet's Admiral from another's. Audience: the provider's own resource
# name, GCP's default (no allowed_audiences), which the Admiral asks its kernel for.
resource "google_iam_workload_identity_pool_provider" "admiral" {
  count                              = var.admiral == null ? 0 : 1
  project                            = google_project.dev.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.fleet_kernels[0].workload_identity_pool_id
  workload_identity_pool_provider_id = var.admiral.provider
  display_name                       = "${var.admiral.provider}'s Admiral"
  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  attribute_condition = "assertion.sub == '${var.admiral.subject}'"
  oidc {
    issuer_uri = var.admiral.issuer
  }
}
