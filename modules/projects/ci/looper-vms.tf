# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper VMs (#108; tacplus-dev/roadmap decisions/looper-build-vms-2026-11-24.md): one looper+builder per
# project, outside the deployment cluster, each a zonal instance group of 0..1 spot arm64 VMs on stock
# Container-Optimized OS, started by one generic cloud-init (files/looper-vm-cloud-init.yaml and files/looper-vm.sh,
# the same for every project; the project, its image and its group are only metadata). The VM is ephemeral, its
# boot disk only a cache (point 3). No external address (NAT, as the runners), no SSH in any form: no key in its
# metadata, the project's blocked, no firewall rule targets it (the runners' one SSH rule is tagged runner-worker);
# break-glass is its logs (roles/logging.logWriter, google-logging-enabled) and its serial console.
#
# Each VM runs as its own account, looper-vm-<name>, keyless, which may: write logs; read the secret looper-model-token,
# and no other; sign with the reports' GitHub App key (looper_vm_app_key, github-apps.tf's local.app_signers, never the
# manager's); and resize its own group alone (idle, to 0). The kicker (tacplus-dev/looper#241), the looper project's
# jobs of its environment kicker, may resize the looper VMs' groups alone (to 1 when its project has work). Members are
# written out, not the accounts' computed ones, so that every plan, the first too, names who each grant is to.

locals {
  looper_vm_member = { for k, v in var.looper_vms : k => "serviceAccount:looper-vm-${k}@${google_project.ci.project_id}.iam.gserviceaccount.com" }
  # Each VM's group, by its resource name as IAM's conditions see it (and as the VM's metadata looper-group names it,
  # which its idle resize calls): the template cannot name the group, which names the template.
  looper_vm_group_prefix = "projects/${google_project.ci.project_id}/zones/${var.zone}/instanceGroupManagers/looper-vm-"
  looper_vm_group        = { for k, v in var.looper_vms : k => "${local.looper_vm_group_prefix}${k}" }
  # The kicker's jobs: tacplus-dev/looper's protected ref in its environment kicker, as local.app_signers names them.
  looper_vm_kicker = "${local.app_pool}/attribute.role/${local.apps.looper.project_id}:${local.apps.looper.ref}:true:kicker"
}

resource "google_service_account" "looper_vm" {
  for_each     = var.looper_vms
  project      = google_project.ci.project_id
  account_id   = "looper-vm-${each.key}"
  display_name = "Looper VM ${each.key} (tacplus-dev/cloud #108)"
  depends_on   = [terraform_data.iam_ready]
}

# Its container's logs and the journal reach Cloud Logging: with no SSH, the only window on the VM.
resource "google_project_iam_member" "looper_vm_log" {
  for_each   = var.looper_vms
  project    = google_project.ci.project_id
  role       = "roles/logging.logWriter"
  member     = local.looper_vm_member[each.key]
  depends_on = [google_service_account.looper_vm]
}

# The model token the looper VMs read (through llmproxy's path, as today). Made with no version: its value is only
# ever added out of band (by Jody), never in this repository, a plan or the state. So no secretVersionAdder binding:
# nobody here adds one.
resource "google_secret_manager_secret" "looper_model_token" {
  project   = google_project.ci.project_id
  secret_id = "looper-model-token"
  labels    = { managed-by = "tacplus-dev-cloud" }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

# Authoritative: the looper VMs' accounts alone read it; a grant added by hand is drift.
resource "google_secret_manager_secret_iam_binding" "looper_model_token" {
  count      = length(var.looper_vms) > 0 ? 1 : 0
  project    = google_project.ci.project_id
  secret_id  = google_secret_manager_secret.looper_model_token.secret_id
  role       = "roles/secretmanager.secretAccessor"
  members    = [for k in sort(keys(var.looper_vms)) : local.looper_vm_member[k]]
  depends_on = [google_service_account.looper_vm]
}

# A resize of a looper VM's group, and nothing else: the get its caller reads the group with, and the update a resize
# is (instanceGroupManagers.resize needs compute.instanceGroupManagers.update alone). Each grant of it is conditioned
# on the groups' names.
resource "google_project_iam_custom_role" "looper_vm_resizer" {
  project     = google_project.ci.project_id
  role_id     = "looperVmResizer"
  title       = "Looper VM group resizer"
  description = "Resizes a looper VM's instance group, conditioned on the group's name (tacplus-dev/cloud #108)."
  permissions = ["compute.instanceGroupManagers.get", "compute.instanceGroupManagers.update"]
  depends_on  = [terraform_data.iam_ready]
}

# Idle, a VM sizes its own group to 0 (files/looper-vm.sh post): its account's resize is on that group alone.
resource "google_project_iam_member" "looper_vm_self_stop" {
  for_each = var.looper_vms
  project  = google_project.ci.project_id
  role     = "projects/${google_project.ci.project_id}/roles/${google_project_iam_custom_role.looper_vm_resizer.role_id}"
  member   = local.looper_vm_member[each.key]
  condition {
    title       = "looper-vm-${each.key} only"
    description = "The VM's own instance group alone (tacplus-dev/cloud #108)"
    expression  = "resource.name == \"${local.looper_vm_group[each.key]}\""
  }
  depends_on = [google_service_account.looper_vm]
}

# The kicker sizes a project's group to 1 when it has work (tacplus-dev/looper#241): on the looper VMs' groups alone.
resource "google_project_iam_member" "looper_vm_kicker" {
  count   = length(var.looper_vms) > 0 ? 1 : 0
  project = google_project.ci.project_id
  role    = "projects/${google_project.ci.project_id}/roles/${google_project_iam_custom_role.looper_vm_resizer.role_id}"
  member  = local.looper_vm_kicker
  condition {
    title       = "looper-vm groups only"
    description = "The looper VMs' instance groups alone (tacplus-dev/cloud #108, tacplus-dev/looper#241)"
    expression  = "resource.name.startsWith(\"${local.looper_vm_group_prefix}\")"
  }
}

resource "google_compute_instance_template" "looper_vm" {
  for_each     = var.looper_vms
  project      = google_project.ci.project_id
  name_prefix  = "looper-vm-${each.key}-"
  machine_type = each.value.machine_type
  region       = var.region
  tags         = ["looper-vm"]
  labels       = { managed-by = "tacplus-dev-cloud", looper-vm = each.key }

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
    email  = google_service_account.looper_vm[each.key].email
    scopes = ["cloud-platform"]
  }

  # A reclaimed spot VM stops (STOP, the only action a group admits), and its group, while at 1, recreates it (the
  # default repair: unlike the runner pools', nobody else deletes it). The container has about 30 s from the
  # preemption's shutdown to push its checkpoints (files/looper-vm-cloud-init.yaml).
  scheduling {
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"
    preemptible                 = each.value.spot
    automatic_restart           = !each.value.spot
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = each.value.spot ? "STOP" : null
  }

  # Stock Container-Optimized OS (point 10): cloud-init from user-data, the OS's own Docker, no OS update (the image
  # changes only with its pin). Its project and image are metadata, no secret. No SSH: no ssh-keys, and the
  # project's keys blocked.
  metadata = {
    user-data              = templatefile("${path.module}/files/looper-vm-cloud-init.yaml", { script = file("${path.module}/files/looper-vm.sh") })
    looper-repo            = each.key
    looper-image           = each.value.image
    looper-group           = local.looper_vm_group[each.key]
    google-logging-enabled = "true"
    cos-update-strategy    = "update_disabled"
    block-project-ssh-keys = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Sized by the kicker (to 1) and the VM itself (idle, to 0), never by a plan. No instance_lifecycle_policy: a VM its
# group did not stop (a spot VM reclaimed) is repaired while the group is at 1.
resource "google_compute_instance_group_manager" "looper_vm" {
  for_each           = var.looper_vms
  project            = google_project.ci.project_id
  name               = "looper-vm-${each.key}"
  zone               = var.zone
  base_instance_name = "looper-vm-${each.key}"
  target_size        = 0
  version {
    instance_template = google_compute_instance_template.looper_vm[each.key].self_link_unique
  }
  # As the runner pools' (#29): a template change replaces the VM, with no surge.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }
  lifecycle {
    ignore_changes = [target_size]
  }
}
