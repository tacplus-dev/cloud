# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The reserved machines (#111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md, the panel's items 4, 5
# and 8): the rolling check of main, per heavy project and one for an org's other repositories, and the merger's small
# control machine. Each a zonal instance group of one on-demand arm64 VM (never spot: the check's verdict and the
# merges do not wait on a reclaimed VM), sized by this plan alone, on stock Container-Optimized OS and the looper VMs'
# one generic cloud-init (files/looper-vm-cloud-init.yaml and files/looper-vm.sh), its role only metadata
# (looper-role): check runs looper-vm check, its builds through the container socket and cut off from the metadata
# server; merger runs looper-vm merger with no container socket, so no project code. A machine with no image has a
# group at 0: no VM, nothing spent, until the looper image runs its role (tacplus-dev/looper#249, #251). Its boot disk
# is its own cache, never a looper VM's. No external address, no SSH in any form (tagged looper-vm, ci/policy.sh), as
# the looper VMs.
#
# Each runs as its own account, <name>, keyless, which may write logs and sign with its role's GitHub App key alone
# (github-apps.tf's local.app_signers): tacplus-check for a check, so its status of main and main-green are what no
# report can mint; tacplus-merger for the merger, which nothing else signs with (variables.tf refuses it). Neither
# reads the model token, signs with the reports' or the managers' key, or resizes a group: nobody but this plan sizes
# them.

locals {
  reserved_vm_member = { for k, v in var.reserved_vms : k => "serviceAccount:${k}@${google_project.ci.project_id}.iam.gserviceaccount.com" }
  # The repositories with a rolling check of their own: an org's check checks every other one.
  reserved_vm_own_check = sort([for k, v in var.reserved_vms : v.repo if v.role == "check" && v.repo != ""])
}

resource "google_service_account" "reserved_vm" {
  for_each     = var.reserved_vms
  project      = google_project.ci.project_id
  account_id   = each.key
  display_name = "Reserved VM ${each.key}, ${each.value.role} (tacplus-dev/cloud #111)"
  depends_on   = [terraform_data.iam_ready]
}

# Its container's logs and the journal reach Cloud Logging: with no SSH, the only window on the VM.
resource "google_project_iam_member" "reserved_vm_log" {
  for_each   = var.reserved_vms
  project    = google_project.ci.project_id
  role       = "roles/logging.logWriter"
  member     = local.reserved_vm_member[each.key]
  depends_on = [google_service_account.reserved_vm]
}

resource "google_compute_instance_template" "reserved_vm" {
  for_each     = var.reserved_vms
  project      = google_project.ci.project_id
  name_prefix  = "${each.key}-"
  machine_type = each.value.machine_type
  region       = var.region
  tags         = ["looper-vm"]
  labels       = { managed-by = "tacplus-dev-cloud", reserved-vm = each.key }

  # C4A has no pd-* disk: Hyperdisk Balanced. The boot disk is the cache too, deleted with the VM.
  disk {
    source_image = var.looper_vm_os_image
    disk_size_gb = each.value.disk_gb
    disk_type    = "hyperdisk-balanced"
    boot         = true
    auto_delete  = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id
  }

  service_account {
    email  = google_service_account.reserved_vm[each.key].email
    scopes = ["cloud-platform"]
  }

  # On demand: restarted after a host event, never reclaimed.
  scheduling {
    provisioning_model  = "STANDARD"
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "TERMINATE"
  }

  # As the looper VMs': the role, its repository or org and its image are metadata, no secret; no SSH.
  metadata = {
    user-data              = templatefile("${path.module}/files/looper-vm-cloud-init.yaml", { script = file("${path.module}/files/looper-vm.sh") })
    looper-role            = each.value.role
    looper-repo            = each.value.repo
    looper-org             = each.value.org
    looper-except          = each.value.role == "check" && each.value.org != "" ? join(",", local.reserved_vm_own_check) : ""
    looper-image           = each.value.image
    google-logging-enabled = "true"
    cos-update-strategy    = "update_disabled"
    block-project-ssh-keys = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One VM while it has an image, none before: the plan alone sizes it (no kicker, no idle exit), so drift is a change.
resource "google_compute_instance_group_manager" "reserved_vm" {
  for_each           = var.reserved_vms
  project            = google_project.ci.project_id
  name               = each.key
  zone               = var.zone
  base_instance_name = each.key
  target_size        = each.value.image == "" ? 0 : 1
  version {
    instance_template = google_compute_instance_template.reserved_vm[each.key].self_link_unique
  }
  # As the looper VMs' (#29): a template change replaces the VM, with no surge.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }
}
