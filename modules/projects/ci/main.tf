# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: GitLab runners (a manager VM and its pools of arm64 VMs, shared by job containers), the build
# cache, and the tacplus-reader app's key in Cloud KMS.

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

resource "google_compute_network" "runners" {
  project                 = google_project.ci.project_id
  name                    = "runners"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.service]
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
