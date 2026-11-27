# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The reserved machines (#111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md, the panel's items 4, 5
# and 8): the rolling check of main, per heavy project and one for an org's other repositories, and the merger's small
# control machine. Each a zonal instance group of one on-demand arm64 VM (never spot: the check's verdict and the
# merges do not wait on a reclaimed VM), on stock Container-Optimized OS and the looper VMs' one generic cloud-init
# (files/looper-vm-cloud-init.yaml and files/looper-vm.sh), its role only metadata (looper-role): check runs
# looper-vm check, its builds through the container socket and cut off from the metadata server; merger runs
# looper-vm merger with no container socket, so no project code. Its boot disk is its own cache, never a looper VM's.
# No external address, no SSH in any form (tagged looper-vm, ci/policy.sh), as the looper VMs.
#
# Builders run only while used (Jody, 2026-11-25): a check machine's group is 0..1, never sized by a plan. Idle (every
# check ended idle), its VM has its group stop it (stopInstances): the stopped VM keeps its boot disk, the cache, and
# costs nothing else. The merger's machine, the one always-on machine (at 1 while it has an image, sized by this plan
# alone), is the small orchestrator: it asks `looper-check needed` of each check machine whose group runs no VM, and
# starts it (startInstances, or a first VM, resize to 1). A machine with no image runs nothing.
#
# Each runs as its own account, <name>, keyless, which may write logs and sign with its machine's GitHub App key alone
# (github-apps.tf's local.app_signers): tacplus-manager until tacplus-check and tacplus-merger exist (the hub, for Jody,
# 2026-11-25: no new App to go live; no looper VM signs with it, variables.tf), then those. A check machine's account
# may also stop its own group's VM, and the merger's start the check machines' (the resizer role, conditioned on the
# groups' names). Neither reads the model token or signs with the reports' key.

locals {
  reserved_vm_member = { for k, v in var.reserved_vms : k => "serviceAccount:${k}@${google_project.ci.project_id}.iam.gserviceaccount.com" }
  reserved_vm_checks = { for k, v in var.reserved_vms : k => v if v.role == "check" }
  reserved_vm_merger = { for k, v in var.reserved_vms : k => v if v.role == "merger" }
  # Each group, by its resource name as IAM's conditions see it, and as the metadata names it to the VMs.
  reserved_vm_group = { for k, v in var.reserved_vms : k => "projects/${google_project.ci.project_id}/zones/${var.zone}/instanceGroupManagers/${k}" }
  # The repositories with a rolling check of their own: an org's check checks every other one.
  reserved_vm_own_check = sort([for k, v in local.reserved_vm_checks : v.repo if v.repo != ""])
  reserved_vm_except    = { for k, v in var.reserved_vms : k => v.role == "check" && v.org != "" ? join(",", local.reserved_vm_own_check) : "" }
  # The check machines the merger's machine starts, a line each: its group and its repositories.
  reserved_vm_kicks = join("\n", [for k in sort(keys(local.reserved_vm_checks)) : "${local.reserved_vm_group[k]} ${local.reserved_vm_checks[k].repo != "" ? "--repo ${local.reserved_vm_checks[k].repo}" : "--org ${local.reserved_vm_checks[k].org}${local.reserved_vm_except[k] == "" ? "" : " --except ${local.reserved_vm_except[k]}"}"}"])
  # The checks' login, whose state of the rolling check alone the merger's gate trusts.
  reserved_vm_check_login = "${coalesce(one(distinct([for k, v in local.reserved_vm_checks : v.key])), "tacplus-check")}[bot]"
  # Each container's settings (looper-env, files/looper-vm.sh): the key ring, and its app (looper-token's role check
  # signs as tacplus-check once LOOPER_CHECK_APP_ID is set, else as tacplus-manager; the merger as LOOPER_MERGER_KEY).
  reserved_vm_env = { for k, v in var.reserved_vms : k => join("\n", [for n, x in merge(
    { LOOPER_KMS_KEYRING = "projects/${google_project.ci.project_id}/locations/${var.region}/keyRings/${local.apps.key_ring}" },
    v.role == "check" && v.key == "tacplus-manager" ? { LOOPER_MANAGER_APP_ID = v.app_id, LOOPER_MANAGER_INSTALLATION_ID = v.installation_id } : {},
    v.role == "check" && v.key != "tacplus-manager" ? { LOOPER_CHECK_APP_ID = v.app_id, LOOPER_CHECK_INSTALLATION_ID = v.installation_id } : {},
    v.role == "merger" ? { LOOPER_ORG = v.org, LOOPER_MERGER_KEY = v.key, LOOPER_MERGER_APP_ID = v.app_id, LOOPER_MERGER_INSTALLATION_ID = v.installation_id, LOOPER_CHECK_LOGIN = local.reserved_vm_check_login } : {},
  ) : "${n}=${x}" if x != ""]) }
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

# Idle, a check machine has its own group stop it (files/looper-vm.sh post): on that group alone.
resource "google_project_iam_member" "reserved_vm_self_stop" {
  for_each = local.reserved_vm_checks
  project  = google_project.ci.project_id
  role     = "projects/${google_project.ci.project_id}/roles/${google_project_iam_custom_role.looper_vm_resizer.role_id}"
  member   = local.reserved_vm_member[each.key]
  condition {
    title       = "${each.key} only"
    description = "The check machine's own instance group alone (tacplus-dev/cloud #111)"
    expression  = "resource.name == \"${local.reserved_vm_group[each.key]}\""
  }
  depends_on = [google_service_account.reserved_vm]
}

# The merger's machine starts the check machines (files/looper-vm.sh kick): on their groups alone.
resource "google_project_iam_member" "reserved_vm_kick" {
  for_each = length(local.reserved_vm_checks) > 0 ? local.reserved_vm_merger : {}
  project  = google_project.ci.project_id
  role     = "projects/${google_project.ci.project_id}/roles/${google_project_iam_custom_role.looper_vm_resizer.role_id}"
  member   = local.reserved_vm_member[each.key]
  condition {
    title       = "check machines only"
    description = "The rolling check's instance groups alone (tacplus-dev/cloud #111)"
    expression  = join(" || ", [for k in sort(keys(local.reserved_vm_checks)) : "resource.name == \"${local.reserved_vm_group[k]}\""])
  }
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

  # C4A has no pd-* disk: Hyperdisk Balanced; T2A has no Hyperdisk: pd-balanced. The boot disk is the cache too, kept
  # while a check machine's VM is stopped, deleted with the VM.
  disk {
    source_image = var.looper_vm_os_image
    disk_size_gb = each.value.disk_gb
    disk_type    = startswith(each.value.machine_type, "c4a-") ? "hyperdisk-balanced" : "pd-balanced"
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

  # As the looper VMs': the role, its repository or org, its image, its group and its settings are metadata, no
  # secret; for the merger, the check machines it starts; no SSH.
  metadata = {
    user-data              = templatefile("${path.module}/files/looper-vm-cloud-init.yaml", { script = file("${path.module}/files/looper-vm.sh") })
    looper-role            = each.value.role
    looper-repo            = each.value.repo
    looper-org             = each.value.org
    looper-except          = local.reserved_vm_except[each.key]
    looper-image           = each.value.image
    looper-group           = local.reserved_vm_group[each.key]
    looper-env             = local.reserved_vm_env[each.key]
    looper-checks          = each.value.role == "merger" ? local.reserved_vm_kicks : ""
    google-logging-enabled = "true"
    cos-update-strategy    = "update_disabled"
    block-project-ssh-keys = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The merger's machine: one VM while it has an image, none before; the plan alone sizes it (no kicker, no idle exit),
# so drift is a change.
resource "google_compute_instance_group_manager" "reserved_vm" {
  for_each           = local.reserved_vm_merger
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

# A check machine: 0..1 running, sized by its VM (stopped, idle) and the merger's machine (started, needed), never by a
# plan; its stopped VM, a standby the group keeps (manual: only those calls start or stop it), is its cache between
# checks.
resource "google_compute_instance_group_manager" "reserved_vm_check" {
  for_each            = local.reserved_vm_checks
  project             = google_project.ci.project_id
  name                = each.key
  zone                = var.zone
  base_instance_name  = each.key
  target_size         = 0
  target_stopped_size = 0
  standby_policy {
    mode = "MANUAL"
  }
  version {
    instance_template = google_compute_instance_template.reserved_vm[each.key].self_link_unique
  }
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }
  lifecycle {
    ignore_changes = [target_size, target_stopped_size]
  }
}

moved {
  from = google_compute_instance_group_manager.reserved_vm["check-tacplus"]
  to   = google_compute_instance_group_manager.reserved_vm_check["check-tacplus"]
}

moved {
  from = google_compute_instance_group_manager.reserved_vm["check-tacplus-dev"]
  to   = google_compute_instance_group_manager.reserved_vm_check["check-tacplus-dev"]
}
