# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The build buckets and the tacplus-reader app's key.

resource "google_storage_bucket" "build" {
  for_each                    = var.build_buckets
  project                     = google_project.ci.project_id
  name                        = "${var.project_id}-${each.key}"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { managed-by = "tacplus-dev-cloud" }
  lifecycle_rule {
    condition {
      age = each.value
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [google_project_service.service]
}

resource "google_kms_key_ring" "reader" {
  project    = google_project.ci.project_id
  name       = var.reader_app_key.key_ring
  location   = var.region
  depends_on = [google_project_service.service]
}

# The GitHub App's key is GitHub's: it is imported, never generated here, so the key has no version until then
# (RS256, which a GitHub App's JWT is signed with).
resource "google_kms_crypto_key" "reader" {
  name                          = var.reader_app_key.key
  key_ring                      = google_kms_key_ring.reader.id
  purpose                       = "ASYMMETRIC_SIGN"
  import_only                   = true
  skip_initial_version_creation = true
  version_template {
    algorithm        = "RSA_SIGN_PKCS1_2048_SHA256"
    protection_level = "SOFTWARE"
  }
  lifecycle {
    prevent_destroy = true
  }
}
