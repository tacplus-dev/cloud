# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev project: the dev GKE cluster (arm64, Axion), the DNS zone for dev hostnames, the cluster pipeline's
# identity, cluster-admin-pipeline, federated from tacplus-dev/cluster's protected main, and each deployment's
# certificate secrets and challenge zone (certificates.tf).

resource "google_project" "dev" {
  project_id          = var.project_id
  name                = var.name
  folder_id           = var.folder
  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = { managed-by = "tacplus-dev-cloud" }
}

resource "google_project_service" "service" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "sts.googleapis.com",
  ])
  project            = google_project.dev.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_compute_network" "dev" {
  project                 = google_project.dev.project_id
  name                    = "dev"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.service]
}

resource "google_compute_subnetwork" "nodes" {
  project                  = google_project.dev.project_id
  name                     = "dev-${var.region}"
  region                   = var.region
  network                  = google_compute_network.dev.id
  ip_cidr_range            = var.network.nodes
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.network.pods
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.network.services
  }
}

# The nodes have no external address: they pull images and reach out through NAT.
resource "google_compute_router" "dev" {
  project = google_project.dev.project_id
  name    = "dev"
  region  = var.region
  network = google_compute_network.dev.id
}

resource "google_compute_router_nat" "dev" {
  project                            = google_project.dev.project_id
  name                               = "dev"
  region                             = var.region
  router                             = google_compute_router.dev.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# The nodes' account: write logs and metrics, nothing else.
resource "google_service_account" "nodes" {
  project      = google_project.dev.project_id
  account_id   = "gke-nodes"
  display_name = "Dev cluster nodes (tacplus-dev/cloud)"
  depends_on   = [google_project_service.service]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = google_project.dev.project_id
  role    = each.key
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "dev" {
  project                  = google_project.dev.project_id
  name                     = var.cluster.name
  location                 = var.cluster.zone
  network                  = google_compute_network.dev.id
  subnetwork               = google_compute_subnetwork.nodes.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = true
  datapath_provider        = "ADVANCED_DATAPATH"
  enable_shielded_nodes    = true

  release_channel {
    channel = var.cluster.release_channel
  }
  workload_identity_config {
    workload_pool = "${google_project.dev.project_id}.svc.id.goog"
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.network.control_plane
  }
  # The default pool goes at once; this is only what it is created with.
  node_config {
    service_account = google_service_account.nodes.email
  }
  lifecycle {
    ignore_changes = [node_config]
  }
  depends_on = [google_project_iam_member.nodes]
}

resource "google_container_node_pool" "arm64" {
  project  = google_project.dev.project_id
  name     = "arm64"
  location = var.cluster.zone
  cluster  = google_container_cluster.dev.name

  autoscaling {
    min_node_count = var.cluster.min_nodes
    max_node_count = var.cluster.max_nodes
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  node_config {
    machine_type    = var.cluster.machine_type
    disk_type       = "hyperdisk-balanced"
    disk_size_gb    = var.cluster.disk_gb
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = { managed-by = "tacplus-dev-cloud" }
    gvnic {
      enabled = true
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# The zone for dev hostnames. Its delegation (NS records in tacplus.dev's zone, still in jody1-328023) is the
# hub's step until DNS moves (README).
resource "google_dns_managed_zone" "dev" {
  project     = google_project.dev.project_id
  name        = var.dns.zone
  dns_name    = var.dns.domain
  description = "Dev hostnames (tacplus-dev/cloud)"
  dnssec_config {
    state = "on"
  }
  depends_on = [google_project_service.service]
}
