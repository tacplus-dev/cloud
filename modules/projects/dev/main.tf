# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev project: the dev GKE cluster (arm64, Axion, private COS nodes in a normal pool, a spot build pool and a looper
# pool from 0), the DNS zone for dev hostnames, the cluster pipeline's identity, cluster-admin-pipeline, federated from
# tacplus-dev/cluster's protected main, with its cluster-admin in the cluster (cluster-pipeline.tf) and the runners'
# token secrets it reads (runner-tokens.tf), each deployment's
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
    "cloudquotas.googleapis.com",
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

# IAM, the pipeline's roles on the parent folder included, reaches a project created seconds before only after a
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
  # the workload identity pool and the cluster among them, and the project as the quota preferences' billing project
  # (serviceusage.services.use, #90).
  iam_ready_permissions = [
    "artifactregistry.repositories.create",
    "cloudquotas.quotas.update",
    "compute.networks.create",
    "container.clusters.create",
    "dns.managedZones.create",
    "iam.serviceAccounts.create",
    "iam.workloadIdentityPools.create",
    "resourcemanager.projects.setIamPolicy",
    "secretmanager.secrets.create",
    "serviceusage.services.use",
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
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.network.control_plane
  }
  # Only load balancers are public (Jody, 2026-11-18, #79): the control plane has no public endpoint, and its private
  # one admits the cluster's own nodes and pods alone, where the cloud, cluster and deploy pipelines run (the in-cluster
  # runner infra, #64).
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled      = false
    private_endpoint_enforcement_enabled = true
    cidr_blocks {
      display_name = "nodes"
      cidr_block   = var.network.nodes
    }
    cidr_blocks {
      display_name = "pods"
      cidr_block   = var.network.pods
    }
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

# The zones of the region that offer the build pool's machine type (#85), as Compute Engine lists them in the project:
# the build pool spreads over them. Read at plan, by the project's ID and not through the project or the IAM gate:
# a pool's zones are its for_each, which must be known then (a project not yet made has none to read).
data "google_compute_zones" "region" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

data "google_compute_machine_types" "spot" {
  for_each = toset(data.google_compute_zones.region.names)
  project  = var.project_id
  zone     = each.key
  filter   = "name = \"${var.cluster.spot.machine_type}\""
}

# The nodes (decisions/cluster-node-pools-2026-11-03.md): private, Container-Optimized OS, arm64 (Axion C4A). The normal
# pool, fixed and on demand, runs the platform in the cluster's zone; the build pool, spot and from 0, runs build pods
# only: they alone tolerate its taint (tacplus-dev/cluster#6); the looper pool, on demand and from 0 in the cluster's
# zone, runs the looper runs that overflow the normal nodes (the control runner's job pods alone tolerate its taint,
# tacplus-dev/cluster#47) and empties back to 0 when they end (#95, the decision's addendum of 2026-11-22): on demand,
# as a looper run lasts hours and spot would preempt it. The pools share the rest.
# The build pool spreads over every zone of the region with its machine type (#85): on 2026-11-20 spot c4a ran out in
# us-central1-a, its only zone, and gates pods waited Pending at 2 nodes of 5. Its maximum is the pool's in all zones
# (total_max), not each zone's, and GKE makes each node in whichever zone has the capacity (location policy ANY).
locals {
  spot_zones = sort([for z, t in data.google_compute_machine_types.spot : z if length(t.machine_types) > 0])
  pools = {
    normal = {
      machine_type   = var.cluster.normal.machine_type
      node_count     = var.cluster.normal.nodes
      node_locations = null
      autoscaling    = null
      spot           = false
      labels         = {}
      taints         = []
    }
    spot = {
      machine_type   = var.cluster.spot.machine_type
      node_count     = null
      node_locations = local.spot_zones
      autoscaling    = { total_min = 0, total_max = var.cluster.spot.max_nodes, location_policy = "ANY" }
      spot           = true
      labels         = { spot = "true" }
      taints         = [{ key = "spot", value = "true", effect = "NO_SCHEDULE" }]
    }
    looper = {
      machine_type   = var.cluster.looper.machine_type
      node_count     = null
      node_locations = null
      autoscaling    = { total_min = 0, total_max = var.cluster.looper.max_nodes, location_policy = "BALANCED" }
      spot           = false
      labels         = { looper = "true" }
      taints         = [{ key = "looper", value = "true", effect = "NO_SCHEDULE" }]
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
  # Null: the cluster's zone.
  node_locations = each.value.node_locations

  dynamic "autoscaling" {
    for_each = each.value.autoscaling == null ? [] : [each.value.autoscaling]
    content {
      total_min_node_count = autoscaling.value.total_min
      total_max_node_count = autoscaling.value.total_max
      location_policy      = autoscaling.value.location_policy
    }
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  lifecycle {
    precondition {
      condition     = try(length(each.value.node_locations), 1) > 0
      error_message = "No zone of ${var.region} offers ${var.cluster.spot.machine_type}: the build pool has nowhere to make a node."
    }
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

# The quotas the pools need (#88), as Cloud Quotas preferences of the project in the region, computed from the pools,
# never typed: on 2026-11-21 the build pool stopped at 2 nodes of 5, its scale-ups refused QUOTA_EXCEEDED, C4A CPUs
# (CPUS_PER_VM_FAMILY, 24) and Hyperdisk Balanced (HDB_TOTAL_GB, 500 GB, all used). C4A CPUs: each pool's at its
# maximum (the normal pool's nodes, the build and looper pools' max_nodes, #95), and one node's of the largest machine
# type for a node being replaced (a surge upgrade, a repair), rounded up to a multiple of 8.
# Hyperdisk Balanced: a disk of disk_gb for each of those nodes, rounded up to a multiple of 500. An increase may wait
# on Google's review (reconciling, until granted); ci/policy.sh refuses a plan whose pools these do not cover. The
# contact is who Google asks about an increase: GCP_QUOTA_CONTACT (README, The network rules, The node pools' quotas).
locals {
  # A machine type's vCPUs, from its name (c4a-standard-4: 4).
  pool_cpus = { for k, p in local.pools : k => tonumber(regex("^[a-z0-9]+-[a-z]+-([0-9]+)", p.machine_type)[0]) }
  # A pool's nodes at its maximum: a fixed pool's count, an autoscaled one's total maximum.
  pool_nodes = { for k, p in local.pools : k => p.autoscaling == null ? p.node_count : p.autoscaling.total_max }
  quota_need = {
    c4a_cpus = sum([for k, n in local.pool_nodes : n * local.pool_cpus[k]]) + max(values(local.pool_cpus)...)
    hdb_gb   = (sum(values(local.pool_nodes)) + 1) * var.cluster.disk_gb
  }
  quotas = {
    c4a_cpus = {
      quota_id   = "CPUS-PER-VM-FAMILY-per-project-region"
      dimensions = { region = var.region, vm_family = "C4A" }
      need       = local.quota_need.c4a_cpus
      preferred  = ceil(local.quota_need.c4a_cpus / 8) * 8
    }
    hdb_gb = {
      quota_id   = "HDB-TOTAL-GB-per-project-region"
      dimensions = { region = var.region }
      need       = local.quota_need.hdb_gb
      preferred  = ceil(local.quota_need.hdb_gb / 500) * 500
    }
  }
}

# Through google.quotas (#90): its calls count against the dev project (billing_project, user_project_override), whose
# Cloud Quotas API the project's services enable before the IAM gate, not against the caller's project.
resource "google_cloud_quotas_quota_preference" "pools" {
  for_each      = local.quotas
  provider      = google.quotas
  parent        = "projects/${google_project.dev.project_id}"
  name          = "dev-pools-${replace(each.key, "_", "-")}-${var.region}"
  service       = "compute.googleapis.com"
  quota_id      = each.value.quota_id
  dimensions    = each.value.dimensions
  contact_email = var.quota_contact
  justification = "The dev cluster's node pools (tacplus-dev/cloud #88): ${each.value.need} needed at their maximum, with one node being replaced."
  quota_config {
    preferred_value = tostring(each.value.preferred)
  }
  depends_on = [terraform_data.iam_ready]
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
