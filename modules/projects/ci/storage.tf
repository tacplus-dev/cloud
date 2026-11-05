# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The build cache and the tacplus-reader app's key.
#
# The build cache (decisions/builds-in-containers-2026-11-03.md, #5): a bucket for the compilers' remote caches and a
# Docker registry for BuildKit's layer cache, both keyed by content (a cache only speeds a build up). The build jobs
# are tacplus-dev/build's: they alone become the build identity, through Workload Identity Federation from gitlab.com,
# and it alone holds a role on either, which reads and writes. No VM carries it: agent jobs, on the same VMs, get
# neither.

resource "google_storage_bucket" "cache" {
  project                     = google_project.ci.project_id
  name                        = "${var.project_id}-${var.build_cache.name}"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { managed-by = "tacplus-dev-cloud" }
  # GCS keeps no read time: an entry is deleted once it has not been written for this long, and the next build that
  # misses it writes it again.
  lifecycle_rule {
    condition {
      age = var.build_cache.days
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_artifact_registry_repository" "cache" {
  project       = google_project.ci.project_id
  location      = var.region
  repository_id = var.build_cache.name
  format        = "DOCKER"
  description   = "BuildKit's layer cache of the build jobs (tacplus-dev/cloud)"
  labels        = { managed-by = "tacplus-dev-cloud" }
  # A version is deleted once it was pushed this long ago: a cache that BuildKit exports again on every build stays
  # young, and so do the layers it references.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "unused-${var.build_cache.days}d"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "${var.build_cache.days * 86400}s"
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_service_account" "build_cache" {
  project      = google_project.ci.project_id
  account_id   = var.build_cache.account_id
  display_name = "Build cache: ${var.build_cache.gitlab_project}'s jobs (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

# Authoritative for the role: nobody but the build identity holds it on the cache.
resource "google_storage_bucket_iam_binding" "cache" {
  bucket  = google_storage_bucket.cache.name
  role    = "roles/storage.objectUser"
  members = [google_service_account.build_cache.member]
}

resource "google_artifact_registry_repository_iam_binding" "cache" {
  project    = google_project.ci.project_id
  location   = google_artifact_registry_repository.cache.location
  repository = google_artifact_registry_repository.cache.name
  role       = "roles/artifactregistry.writer"
  members    = [google_service_account.build_cache.member]
}

resource "google_iam_workload_identity_pool" "gitlab" {
  project                   = google_project.ci.project_id
  workload_identity_pool_id = var.build_cache.wif_pool
  display_name              = "gitlab.com"
  description               = "GitLab CI jobs of tacplus-dev (tacplus-dev/cloud)"
  depends_on                = [terraform_data.iam_ready]
}

# Every job of the build project, on any ref: a merge request's build reads and fills the cache too, which its
# content keys keep from poisoning another's.
resource "google_iam_workload_identity_pool_provider" "build" {
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = var.build_cache.wif_provider
  display_name                       = var.build_cache.gitlab_project
  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.project_path" = "assertion.project_path"
  }
  attribute_condition = "assertion.project_path == '${var.build_cache.gitlab_project}'"
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

resource "google_service_account_iam_member" "build_cache_wif" {
  service_account_id = google_service_account.build_cache.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_path/${var.build_cache.gitlab_project}"
}

resource "google_kms_key_ring" "reader" {
  project    = google_project.ci.project_id
  name       = var.reader_app_key.key_ring
  location   = var.region
  depends_on = [terraform_data.iam_ready]
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
