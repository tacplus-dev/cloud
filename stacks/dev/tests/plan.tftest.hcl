# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev stack's plan against a stub organization and an empty project (mock providers: no credentials, no
# cloud): the stack plans, and its module, with the stack's inputs, gives the arm64 cluster, the dev zone and the
# cluster pipeline's identity, federated from tacplus-dev/cluster's protected main alone. (A test sees a module's
# resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_organization" {
    defaults = { org_id = "123456789012", name = "organizations/123456789012", directory_customer_id = "C0stub000" }
  }
  mock_data "google_active_folder" {
    defaults = { name = "folders/444" }
  }
  mock_data "google_project" {
    defaults = { billing_account = "000000-111111-222222", number = "333" }
  }
  # Computed at apply; the stub gives values of the right form.
  mock_resource "google_service_account" {
    defaults = { email = "stub-account@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:stub-account@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/stub-account@tacplus-dev.iam.gserviceaccount.com" }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/555/locations/global/workloadIdentityPools/gitlab-com" }
  }
}

run "stack" {
  command = plan
  assert {
    condition     = output.project_id == "tacplus-dev"
    error_message = "The dev project is not tacplus-dev."
  }
}

run "dev" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      machine_type    = "c4a-standard-4"
      disk_gb         = 100
      min_nodes       = 1
      max_nodes       = 3
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
  }

  assert {
    condition     = google_project.dev.folder_id == "folders/444" && !google_project.dev.auto_create_network && google_project.dev.deletion_policy == "PREVENT"
    error_message = "The project is not in its folder, without a default network and protected from deletion."
  }
  assert {
    condition     = google_container_node_pool.arm64.node_config[0].machine_type == "c4a-standard-4" && google_container_cluster.dev.deletion_protection
    error_message = "The cluster's only nodes are not Axion (arm64), or the cluster is not deletion-protected."
  }
  assert {
    condition     = google_container_cluster.dev.private_cluster_config[0].enable_private_nodes && google_container_node_pool.arm64.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "The nodes have external addresses, or pods see the node's metadata."
  }
  assert {
    condition     = google_dns_managed_zone.dev.dns_name == "dev.tacplus.dev." && google_dns_managed_zone.dev.dnssec_config[0].state == "on"
    error_message = "The dev zone is not dev.tacplus.dev with DNSSEC."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.cluster.attribute_condition == "assertion.project_path == 'tacplus-dev/cluster' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'" && google_iam_workload_identity_pool_provider.cluster.oidc[0].issuer_uri == "https://gitlab.com"
    error_message = "The cluster pipeline's provider admits more than tacplus-dev/cluster's protected main."
  }
  assert {
    condition     = google_service_account_iam_member.cluster_pipeline_wif.member == "principalSet://iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cluster" && google_service_account_iam_member.cluster_pipeline_wif.role == "roles/iam.workloadIdentityUser"
    error_message = "cluster-admin-pipeline is not tacplus-dev/cluster's alone."
  }
  assert {
    condition     = google_project_iam_member.cluster_pipeline.role == "roles/container.clusterViewer"
    error_message = "cluster-admin-pipeline holds more in GCP than getting the cluster's credentials."
  }
}

run "x86_nodes_refused" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      machine_type    = "e2-standard-4"
      disk_gb         = 100
      min_nodes       = 1
      max_nodes       = 3
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
  }
  expect_failures = [var.cluster]
}
