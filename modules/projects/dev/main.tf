# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev project: the dev GKE cluster (arm64, Axion, private COS nodes in a normal pool and a spot build pool), the DNS zone for dev hostnames, the cluster pipeline's
# identity, cluster-admin-pipeline, federated from tacplus-dev/cluster's protected main, with its cluster-admin in the
# cluster (cluster-pipeline.tf) and the runners' token secrets it reads (runner-tokens.tf), each deployment's
# certificate secrets and challenge zone (certificates.tf), the gateway's address and the domain's zone (dns.tf), and
# the TCP proxy load balancer on that address, TLS passed through to the NEGs in the cluster (load-balancer.tf), and
# each deployment's get-credentials on the cluster, Cloud Build, deploy registry and build bucket, and environment
# accounts (deploy.tf).

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
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  project            = google_project.dev.project_id
  service            = each.key
  disable_on_destroy = false
}

# IAM, the pipeline's role on the parent folder included, reaches a project created seconds before only after a
# minute or two (#16): everything else in the project comes after this gate, which waits, bounded, until the
# pipeline holds there the permissions of its first creates (ci/iam-ready.sh). An existing project passes at once.
resource "terraform_data" "iam_ready" {
  triggers_replace = google_project.dev.number
  input            = { project = google_project.dev.project_id, permissions = local.iam_ready_permissions }
  provisioner "local-exec" {
    command = "${path.module}/../../../ci/iam-ready.sh ${self.input.project} ${join(" ", self.input.permissions)}"
  }
  depends_on = [google_project_service.service]
}

locals {
  # What the gate waits for: the first create of each kind in the project,
  # the workload identity pool and the cluster among them.
  iam_ready_permissions = [
    "artifactregistry.repositories.create",
    "compute.networks.create",
    "container.clusters.create",
    "dns.managedZones.create",
    "iam.serviceAccounts.create",
    "iam.workloadIdentityPools.create",
    "resourcemanager.projects.setIamPolicy",
    "secretmanager.secrets.create",
    "storage.buckets.create",
  ]
}

resource "google_compute_network" "dev" {
  project                 = google_project.dev.project_id
  name                    = "dev"
  auto_create_subnetworks = false
  depends_on              = [terraform_data.iam_ready]
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
  depends_on   = [terraform_data.iam_ready]
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

# The nodes (decisions/cluster-node-pools-2026-11-03.md): private, Container-Optimized OS, arm64 (Axion C4A). The normal
# pool, fixed and on demand, runs the platform; the build pool, spot and from 0, runs build pods only: they alone
# tolerate its taint (tacplus-dev/cluster#6). Both pools share the rest.
locals {
  pools = {
    normal = {
      machine_type = var.cluster.normal.machine_type
      node_count   = var.cluster.normal.nodes
      autoscaling  = null
      spot         = false
      labels       = {}
      taints       = []
    }
    spot = {
      machine_type = var.cluster.spot.machine_type
      node_count   = null
      autoscaling  = { min = 0, max = var.cluster.spot.max_nodes }
      spot         = true
      labels       = { spot = "true" }
      taints       = [{ key = "spot", value = "true", effect = "NO_SCHEDULE" }]
    }
  }
}

resource "google_container_node_pool" "pool" {
  for_each   = local.pools
  project    = google_project.dev.project_id
  name       = each.key
  location   = var.cluster.zone
  cluster    = google_container_cluster.dev.name
  node_count = each.value.node_count

  dynamic "autoscaling" {
    for_each = each.value.autoscaling == null ? [] : [each.value.autoscaling]
    content {
      min_node_count = autoscaling.value.min
      max_node_count = autoscaling.value.max
    }
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  network_config {
    enable_private_nodes = true
  }
  node_config {
    machine_type    = each.value.machine_type
    image_type      = "COS_CONTAINERD"
    spot            = each.value.spot
    disk_type       = "hyperdisk-balanced"
    disk_size_gb    = var.cluster.disk_gb
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = merge({ managed-by = "tacplus-dev-cloud" }, each.value.labels)
    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }
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

# The zone for dev hostnames. Its delegation is an NS record of the domain's zone (dns.tf); in the zone it replaces,
# still in jody1-328023 until the cutover, it is the hub's step (README).
resource "google_dns_managed_zone" "dev" {
  project     = google_project.dev.project_id
  name        = var.dns.zone
  dns_name    = var.dns.domain
  description = "Dev hostnames (tacplus-dev/cloud)"
  dnssec_config {
    state = "on"
  }
  depends_on = [terraform_data.iam_ready]
}
