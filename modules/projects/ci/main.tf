# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: the looper VMs (looper-vms.tf) and the reserved machines (reserved-vms.tf) on the network runners and
# its NAT, the build cache, the GitHub Apps' keys in Cloud KMS (github-apps.tf), the Admiral's credentials (admiral.tf)
# and the audit's account (hub-audit.tf). Its GitLab runner pools and their manager are gone (#113): GitLab's jobs run
# on the in-cluster runners of the dev project (README, What runs where).

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
    "cloudquotas.googleapis.com", # hub-audit's reads of the quotas (#88), its calls' quota project
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

# IAM, the pipeline's roles on the parent folder included, reaches a project created seconds before only after a
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

# The network, its subnet, router and NAT are still named runners, for the runner pools they were made for (#113 removed
# the pools): the looper VMs and the reserved machines are on them, and a new name would replace every one of those.
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

# No VM has an external address: they reach gitlab.com, GitHub, the registries and the model API through NAT.
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
  # Ports per VM grow with its connections (2026-11-11): a VM's jobs open connections at once (image pulls, git, the
  # model API), and NAT's default of 64 ports a VM ran out on the shared runner VM ("Get https://ghcr.io/v2/: context
  # deadline exceeded" on every new job). Dynamic allocation from 1024 up to 16384 a VM.
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 1024
  max_ports_per_vm                    = 16384
  # A connection NAT drops (no port left, an allocation failed) is logged, errors only (#61): a runner pool's fresh VM's
  # first pull timed out with no record of why.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The runner manager (#113): #48's destroy = false is in its state (OpenTofu keeps it there), so a resource block taken
# away would forget it, not destroy it, and its VM and disk would bill on outside every state (tests/ci_plan_test.sh).
# This destroys it, with the rest of the pools; once applied it is in no state and the block is a no-op, which goes in
# a later commit (PROPOSALS.md). The managers made before #46 were forgotten by their own destroy = false: the drift
# job's audit names any runner-* VM, disk, template or group still in the project (ci/audit.sh).
removed {
  from = google_compute_instance.manager
  lifecycle {
    destroy = true
  }
}
