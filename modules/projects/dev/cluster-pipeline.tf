# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# cluster-admin-pipeline: tacplus-dev/cluster's pipeline identity, keyless. Only that GitLab project's protected
# main may become it (the provider's condition). In GCP it may get the dev cluster's credentials; its cluster-admin
# inside the cluster is a ClusterRoleBinding, which tacplus-dev/cluster's README lists for the hub.

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
