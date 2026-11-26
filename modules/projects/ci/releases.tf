# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The release registry (#115; tacplus-dev/looper#252, tacplus-dev/fleet-seatrials#82): the images a release build
# publishes by digest, <repo>:<branch>-<commit, 12 hex>, in tacplus-dev rather than jody1-328023, which #15 empties.
# No cleanup policy: a deployment pins a release by digest, and nothing it pins is deleted. One writer, the publish
# identity, which only tacplus-dev/build's jobs on its protected main, in its environment registry (its publish jobs),
# become: not the build cache's provider, which admits every job of build on any ref. Its readers are the deployments'
# accounts that copy a release by digest into their own registry (the same manifest, nothing rebuilt), so that no
# cluster pulls across projects; nobody else reads it. Both roles are authoritative, and ci/policy.sh refuses any
# other on it.

resource "google_artifact_registry_repository" "releases" {
  count         = var.releases == null ? 0 : 1
  project       = google_project.ci.project_id
  location      = var.releases.location
  repository_id = var.releases.repository
  format        = "DOCKER"
  description   = "Release images of ${var.releases.gitlab_project}'s release builds, by digest (tacplus-dev/cloud #115)"
  labels        = { managed-by = "tacplus-dev-cloud" }
  depends_on    = [terraform_data.iam_ready]
}

resource "google_service_account" "release_publish" {
  count        = var.releases == null ? 0 : 1
  project      = google_project.ci.project_id
  account_id   = var.releases.account_id
  display_name = "Release publish: ${var.releases.gitlab_project}'s protected main, environment ${var.releases.environment} (tacplus-dev/cloud #115)"
  depends_on   = [terraform_data.iam_ready]
}

# Protected main alone, and the job's environment mapped with its project, as the dev pool's (deploy.tf): the binding
# below names both together.
resource "google_iam_workload_identity_pool_provider" "release" {
  count                              = var.releases == null ? 0 : 1
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = var.releases.wif_provider
  display_name                       = "${var.releases.gitlab_project} releases"
  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.project_path"        = "assertion.project_path"
    "attribute.ref"                 = "assertion.ref"
    "attribute.ref_type"            = "assertion.ref_type"
    "attribute.ref_protected"       = "assertion.ref_protected"
    "attribute.project_environment" = "assertion.project_path + ':' + (has(assertion.environment) ? assertion.environment : '')"
  }
  attribute_condition = "assertion.project_path == '${var.releases.gitlab_project}' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'"
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

# Authoritative: nobody else becomes it.
resource "google_service_account_iam_binding" "release_publish" {
  count              = var.releases == null ? 0 : 1
  service_account_id = google_service_account.release_publish[0].name
  role               = "roles/iam.workloadIdentityUser"
  members            = ["principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_environment/${var.releases.gitlab_project}:${var.releases.environment}"]
}

# Authoritative for each role: the publish identity writes, the readers read.
resource "google_artifact_registry_repository_iam_binding" "releases_writer" {
  count      = var.releases == null ? 0 : 1
  project    = google_project.ci.project_id
  location   = google_artifact_registry_repository.releases[0].location
  repository = google_artifact_registry_repository.releases[0].repository_id
  role       = "roles/artifactregistry.writer"
  members    = [google_service_account.release_publish[0].member]
}

resource "google_artifact_registry_repository_iam_binding" "releases_reader" {
  count      = var.releases == null || length(var.releases.readers) == 0 ? 0 : 1
  project    = google_project.ci.project_id
  location   = google_artifact_registry_repository.releases[0].location
  repository = google_artifact_registry_repository.releases[0].repository_id
  role       = "roles/artifactregistry.reader"
  members    = var.releases.readers
}
