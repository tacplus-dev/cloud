# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: GitLab runners (a manager VM and its pools of arm64 VMs, shared by job containers), the build
# cache, and the GitHub Apps' keys in Cloud KMS (github-apps.tf).

resource "google_project" "ci" {
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
    "cloudkms.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  project            = google_project.ci.project_id
  service            = each.key
  disable_on_destroy = false
}

# IAM, the pipeline's role on the parent folder included, reaches a project created seconds before only after a
# minute or two (#16): everything else in the project comes after this gate, which waits, bounded, until the
# pipeline holds there the permissions of its first creates (ci/iam-ready.sh). An existing project passes at once.
resource "terraform_data" "iam_ready" {
  triggers_replace = google_project.ci.number
  input            = { project = google_project.ci.project_id, permissions = local.iam_ready_permissions }
  provisioner "local-exec" {
    command = "${path.module}/../../../ci/iam-ready.sh ${self.input.project} ${join(" ", self.input.permissions)}"
  }
  depends_on = [google_project_service.service]
}

locals {
  # What the gate waits for: the first create of each kind in the project,
  # the workload identity pools, the key ring and the importers' custom role among them.
  iam_ready_permissions = [
    "artifactregistry.repositories.create",
    "cloudkms.keyRings.create",
    "compute.networks.create",
    "iam.roles.create",
    "iam.serviceAccounts.create",
    "iam.workloadIdentityPools.create",
    "resourcemanager.projects.setIamPolicy",
    "secretmanager.secrets.create",
    "storage.buckets.create",
  ]
}

resource "google_compute_network" "runners" {
  project                 = google_project.ci.project_id
  name                    = "runners"
  auto_create_subnetworks = false
  depends_on              = [terraform_data.iam_ready]
}

resource "google_compute_subnetwork" "runners" {
  project                  = google_project.ci.project_id
  name                     = "runners-${var.region}"
  region                   = var.region
  network                  = google_compute_network.runners.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# No VM has an external address: they reach gitlab.com, the registries and the Ubuntu archive through NAT.
resource "google_compute_router" "runners" {
  project = google_project.ci.project_id
  name    = "runners"
  region  = var.region
  network = google_compute_network.runners.id
}

resource "google_compute_router_nat" "runners" {
  project                            = google_project.ci.project_id
  name                               = "runners"
  region                             = var.region
  router                             = google_compute_router.runners.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  # Ports per VM grow with its connections (2026-11-11): with no slots, a VM runs up to 25 jobs that open connections
  # at once (image pulls, git, the model API), and NAT's default of 64 ports a VM ran out ("Get https://ghcr.io/v2/:
  # context deadline exceeded" on every new job). Dynamic allocation from 1024 up to 16384 a VM.
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 1024
  max_ports_per_vm                    = 16384
  # A connection NAT drops (no port left, an allocation failed) is logged, errors only (#61): the pools' VMs log nothing
  # of their own (no account), and a fresh VM's first pull timed out with no record of why.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The manager reaches its workers over SSH (the docker-autoscaler executor): the one port-22 rule, internal and by
# network tag, which ci/policy.sh admits exactly as it is until the runner VMs go (#11). Nothing else reaches port 22,
# not even IAP (decisions/network-exposure-2026-11-03.md): break-glass on a VM is its serial console and its logs.
resource "google_compute_firewall" "manager_to_workers" {
  project     = google_project.ci.project_id
  name        = "runner-manager-to-workers-ssh"
  network     = google_compute_network.runners.id
  direction   = "INGRESS"
  source_tags = ["runner-manager"]
  target_tags = ["runner-worker"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
