# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# cluster-admin-pipeline: tacplus-dev/cluster's pipeline identity, keyless. Only that GitLab project's protected
# main may become it (the provider's condition). In GCP it may get the dev cluster's credentials, and read the runners'
# tokens (runner-tokens.tf), and write its registry ci-images (#45, below); its cluster-admin is a ClusterRoleBinding
# inside the cluster, made here (#18), through the stack's kubernetes provider, as this pipeline: never
# roles/container.admin in IAM, which could delete the cluster (ci/policy.sh refuses it).

resource "google_iam_workload_identity_pool" "gitlab" {
  project                   = google_project.dev.project_id
  workload_identity_pool_id = var.cluster_pipeline.pool
  display_name              = "gitlab.com"
  description               = "GitLab CI jobs of tacplus-dev (tacplus-dev/cloud)"
  depends_on                = [terraform_data.iam_ready]
}

resource "google_iam_workload_identity_pool_provider" "cluster" {
  project                            = google_project.dev.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = var.cluster_pipeline.provider
  display_name                       = var.cluster_pipeline.gitlab_project
  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.project_path"  = "assertion.project_path"
    "attribute.ref"           = "assertion.ref"
    "attribute.ref_type"      = "assertion.ref_type"
    "attribute.ref_protected" = "assertion.ref_protected"
  }
  attribute_condition = "assertion.project_path == '${var.cluster_pipeline.gitlab_project}' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'"
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

resource "google_service_account" "cluster_pipeline" {
  project      = google_project.dev.project_id
  account_id   = var.cluster_pipeline.account_id
  display_name = "${var.cluster_pipeline.gitlab_project} pipeline, protected main (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

resource "google_service_account_iam_member" "cluster_pipeline_wif" {
  service_account_id = google_service_account.cluster_pipeline.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_path/${var.cluster_pipeline.gitlab_project}"
}

resource "google_project_iam_member" "cluster_pipeline" {
  project = google_project.dev.project_id
  role    = "roles/container.clusterViewer"
  member  = google_service_account.cluster_pipeline.member
}

# The kubernetes provider is the stack's, configured from cluster_api: on a plan before the cluster exists (or of its
# replacement) its endpoint is known only after apply, and the binding is made once the cluster is.
resource "kubernetes_cluster_role_binding_v1" "cluster_pipeline" {
  metadata {
    name   = var.cluster_pipeline.account_id
    labels = { managed-by = "tacplus-dev-cloud" }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  # GKE names a Google service account by its email; spelled out, so that the plan shows it before the account exists.
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "${var.cluster_pipeline.account_id}@${var.project_id}.iam.gserviceaccount.com"
  }
  depends_on = [terraform_data.iam_ready]
}

# Its registry (#45; tacplus-dev/cluster#21, the hub's decision (1), 2026-11-12): the GitLab Runner and helper images
# tacplus-dev/cluster builds itself (crane, no container runtime), which the cluster's runner and its job pods pull.
# Private: cluster-admin-pipeline alone writes it, the nodes alone read it (authoritative bindings, so a grant added by
# hand, a public one included, is drift); no cleanup policy, so no image a pin names is deleted.
resource "google_artifact_registry_repository" "ci_images" {
  project       = google_project.dev.project_id
  location      = var.region
  repository_id = var.cluster_pipeline.registry
  format        = "DOCKER"
  description   = "${var.cluster_pipeline.gitlab_project}'s GitLab Runner images, run on the dev cluster (tacplus-dev/cloud)"
  labels        = { managed-by = "tacplus-dev-cloud" }
  depends_on    = [terraform_data.iam_ready]
}

resource "google_artifact_registry_repository_iam_binding" "ci_images" {
  for_each = {
    "roles/artifactregistry.writer" = google_service_account.cluster_pipeline.member
    "roles/artifactregistry.reader" = google_service_account.nodes.member
  }
  project    = google_project.dev.project_id
  location   = google_artifact_registry_repository.ci_images.location
  repository = google_artifact_registry_repository.ci_images.repository_id
  role       = each.key
  members    = [each.value]
}
