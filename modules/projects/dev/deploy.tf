# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What each deployment's pipeline needs besides its certificate (certificates.tf), #20: the dev cluster's credentials
# (container.clusterViewer, conditioned on that cluster; its rights inside are tacplus-dev/cluster's, deployments.yaml),
# its images, and its environment accounts.
#
# Images: Cloud Build, for now (Jody, 2026-11-06: a managed service, no VM; once builds move to the cluster's build
# pool, tacplus-dev/looper#84, its roles and the bucket come out). The deployment's identity submits builds, which
# run as an account of their own and push to the deployment's registry; it stages each submit's source and writes its
# logs in a bucket of its own, so that gcloud needs no right on the project's buckets (fleet-seatrials#32). The
# registry is a deploy registry, not tacplus-ci's build-cache: the nodes pull from it, and it has no cleanup policy,
# so nothing deployed is deleted.
#
# Environment accounts: by GitLab environment, an account only the deployment's project's jobs in that environment, on
# protected main, may become (its provider's condition, and the binding naming the project and the environment
# together: the pool is shared by tacplus-dev's projects), with the cluster's credentials, its certificate if it has
# one (certificates.tf), and its secrets: by ID, secrets only it adds versions to and reads, made with none (#32: the
# test IdP's seeds, in Secret Manager rather than GitLab, which on gitlab.com Free has no project access token to write
# them with; as #28). Their values are only ever its jobs': none is in this repository, a plan or the state. It holds
# no other role.

locals {
  # The cluster as IAM conditions name it.
  cluster_resource = "projects/${var.project_id}/locations/${var.cluster.zone}/clusters/${var.cluster.name}"
  images           = { for k, d in var.deployments : k => d.images if d.images != null }
  environment_accounts = merge([for k, d in var.deployments : {
    for e, a in d.environment_accounts : "${k}/${e}" => { deployment = k, environment = e, account_id = a }
  }]...)
  # Every environment account's secret, by its ID: the account's key.
  environment_secrets = merge([for k, d in var.deployments : merge([for e, ids in d.environment_secrets : { for id in ids : id => "${k}/${e}" }]...)]...)
  registry_roles = {
    "roles/artifactregistry.writer" = "build"
    "roles/artifactregistry.reader" = "readers"
  }
  build_bucket_roles = {
    "roles/storage.admin"       = "deploy"
    "roles/storage.objectAdmin" = "build"
  }
}

resource "google_project_iam_member" "cluster_viewer" {
  for_each = merge(
    { for k, d in var.deployments : "deploy/${k}" => google_service_account.deploy[k].member },
    { for k, a in local.environment_accounts : "environment/${k}" => google_service_account.environment[k].member },
  )
  project = google_project.dev.project_id
  role    = "roles/container.clusterViewer"
  member  = each.value
  condition {
    title       = "cluster-${var.cluster.name}"
    description = "get-credentials on the cluster ${var.cluster.name} alone"
    expression  = "resource.name == \"${local.cluster_resource}\""
  }
}

resource "google_service_account" "environment" {
  for_each     = local.environment_accounts
  project      = google_project.dev.project_id
  account_id   = each.value.account_id
  display_name = "${var.deployments[each.value.deployment].gitlab_project} pipeline, protected main, environment ${each.value.environment} (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

resource "google_service_account_iam_member" "environment_wif" {
  for_each           = local.environment_accounts
  service_account_id = google_service_account.environment[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_environment/${var.deployments[each.value.deployment].gitlab_project}:${each.value.environment}"
}

resource "google_service_account" "build" {
  for_each     = local.images
  project      = google_project.dev.project_id
  account_id   = each.value.account_id
  display_name = "Cloud Build builds of ${var.deployments[each.key].gitlab_project}: deployment ${each.key} (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

# Only the deployment's identity submits builds as it.
resource "google_service_account_iam_binding" "build_user" {
  for_each           = local.images
  service_account_id = google_service_account.build[each.key].name
  role               = "roles/iam.serviceAccountUser"
  members            = [google_service_account.deploy[each.key].member]
}

resource "google_project_iam_member" "deploy" {
  for_each = { for p in setproduct(keys(local.images), ["roles/cloudbuild.builds.editor", "roles/serviceusage.serviceUsageConsumer"]) : "${p[0]}/${p[1]}" => { deployment = p[0], role = p[1] } }
  project  = google_project.dev.project_id
  role     = each.value.role
  member   = google_service_account.deploy[each.value.deployment].member
}

# The builds write their logs to Cloud Logging too, as the nodes do.
resource "google_project_iam_member" "build" {
  for_each = local.images
  project  = google_project.dev.project_id
  role     = "roles/logging.logWriter"
  member   = google_service_account.build[each.key].member
}

resource "google_artifact_registry_repository" "deploy" {
  for_each      = local.images
  project       = google_project.dev.project_id
  location      = var.region
  repository_id = each.value.registry
  format        = "DOCKER"
  description   = "${var.deployments[each.key].gitlab_project}'s images, deployed on the dev cluster (tacplus-dev/cloud)"
  labels        = { managed-by = "tacplus-dev-cloud", deployment = each.key }
  depends_on    = [terraform_data.iam_ready]
}

# Authoritative for each role: the builds' account writes, the deployment's identity (its fingerprint tags) and the
# nodes (to pull) read.
resource "google_artifact_registry_repository_iam_binding" "deploy" {
  for_each   = { for p in setproduct(keys(local.images), keys(local.registry_roles)) : "${p[0]}/${p[1]}" => { deployment = p[0], role = p[1] } }
  project    = google_project.dev.project_id
  location   = google_artifact_registry_repository.deploy[each.value.deployment].location
  repository = google_artifact_registry_repository.deploy[each.value.deployment].name
  role       = each.value.role
  members = local.registry_roles[each.value.role] == "build" ? [google_service_account.build[each.value.deployment].member] : [
    google_service_account.deploy[each.value.deployment].member,
    google_service_account.nodes.member,
  ]
}

resource "google_storage_bucket" "build" {
  for_each                    = local.images
  project                     = google_project.dev.project_id
  name                        = "${var.project_id}-${each.value.bucket}"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { managed-by = "tacplus-dev-cloud", deployment = each.key }
  lifecycle_rule {
    condition {
      age = each.value.days
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [terraform_data.iam_ready]
}

# Authoritative for each role: the deployment's identity administers the bucket, the builds' account its objects.
resource "google_storage_bucket_iam_binding" "build" {
  for_each = { for p in setproduct(keys(local.images), keys(local.build_bucket_roles)) : "${p[0]}/${p[1]}" => { deployment = p[0], role = p[1] } }
  bucket   = google_storage_bucket.build[each.value.deployment].name
  role     = each.value.role
  members = [local.build_bucket_roles[each.value.role] == "build" ? google_service_account.build[each.value.deployment].member :
  google_service_account.deploy[each.value.deployment].member]
}

resource "google_secret_manager_secret" "environment" {
  for_each  = local.environment_secrets
  project   = google_project.dev.project_id
  secret_id = each.key
  labels    = { managed-by = "tacplus-dev-cloud", deployment = local.environment_accounts[each.value].deployment }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

# Authoritative for each role: the environment account alone adds versions and reads them.
resource "google_secret_manager_secret_iam_binding" "environment" {
  for_each  = { for p in setproduct(keys(local.environment_secrets), local.certificate_roles) : "${p[0]}/${p[1]}" => { secret = p[0], role = p[1] } }
  project   = google_project.dev.project_id
  secret_id = google_secret_manager_secret.environment[each.value.secret].secret_id
  role      = each.value.role
  members   = [google_service_account.environment[local.environment_secrets[each.value.secret]].member]
}
