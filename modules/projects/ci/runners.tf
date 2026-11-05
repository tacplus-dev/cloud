# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The runners: one manager VM (gitlab-runner, the docker-autoscaler executor and the googlecloud fleeting plugin)
# and, per pool, an instance template and a managed instance group of arm64 Container-Optimized OS VMs, sized by
# the manager, whose job containers share the VMs, which are reused. Each pool's runner token is in Secret Manager (runner-token-<pool>),
# written by the gitlab stack when it registers the runner; the manager reads it at boot. No token is in this
# repository or in a VM's metadata.

locals {
  pool_sa = { for k, p in var.pools : k => p if p.service_account }
}

# The workers' own accounts, with no role at all (the looper-runner pattern, tacplus-dev/looper README): a job that
# reaches the metadata server gets a token that may do nothing in this project.
resource "google_service_account" "worker" {
  for_each     = local.pool_sa
  project      = google_project.ci.project_id
  account_id   = "runner-${each.key}"
  display_name = "Runner pool ${each.key}: no roles (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

resource "google_service_account" "manager" {
  project      = google_project.ci.project_id
  account_id   = "runner-manager"
  display_name = "GitLab runner manager (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

# The manager creates and deletes its pools' VMs, and sets their SSH keys.
resource "google_project_iam_member" "manager" {
  for_each = toset(["roles/compute.instanceAdmin.v1", "roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = google_project.ci.project_id
  role     = each.key
  member   = google_service_account.manager.member
}

resource "google_service_account_iam_member" "manager_uses_worker" {
  for_each           = google_service_account.worker
  service_account_id = each.value.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.manager.member
}

resource "google_secret_manager_secret" "runner_token" {
  for_each  = var.pools
  project   = google_project.ci.project_id
  secret_id = "runner-token-${each.key}"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_secret_manager_secret_iam_member" "manager_reads_token" {
  for_each  = google_secret_manager_secret.runner_token
  project   = google_project.ci.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.manager.member
}

resource "google_compute_instance_template" "pool" {
  for_each     = var.pools
  project      = google_project.ci.project_id
  name_prefix  = "runner-${each.key}-"
  machine_type = each.value.machine_type
  region       = var.region
  tags         = ["runner-worker"]
  labels       = { managed-by = "tacplus-dev-cloud", runner-pool = each.key }

  disk {
    source_image = var.pool_image
    disk_size_gb = each.value.capacity * each.value.job.disk_gb + each.value.os_disk_gb
    disk_type    = each.value.disk_type
    boot         = true
    auto_delete  = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id
  }

  # A pool without an account of its own has none at all, and no scopes: no Google token on the VM.
  dynamic "service_account" {
    for_each = each.value.service_account ? [google_service_account.worker[each.key].email] : []
    content {
      email  = service_account.value
      scopes = ["cloud-platform"]
    }
  }

  scheduling {
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  # Vanilla Container-Optimized OS (decisions/builds-in-containers-2026-11-03.md): no startup-script, nothing installed
  # at boot, Docker the OS's own. The guest agent creates the user the manager connects as from the SSH key the
  # fleeting plugin sets, in the OS's docker group. No OS update: the image changes only with its pin.
  metadata = {
    cos-update-strategy = "update_disabled"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "pool" {
  for_each           = var.pools
  project            = google_project.ci.project_id
  name               = "runner-${each.key}"
  zone               = var.zone
  base_instance_name = "runner-${each.key}"
  target_size        = 0
  version {
    instance_template = google_compute_instance_template.pool[each.key].self_link_unique
  }
  # The manager's autoscaler sizes the group: its idle VMs, and the VMs its jobs need.
  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_instance" "manager" {
  project                   = google_project.ci.project_id
  name                      = "runner-manager"
  zone                      = var.zone
  machine_type              = var.manager_machine_type
  tags                      = ["runner-manager"]
  labels                    = { managed-by = "tacplus-dev-cloud" }
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id
  }

  service_account {
    email  = google_service_account.manager.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script           = file("${path.module}/files/manager-startup.sh")
    apt-snapshot             = var.apt_snapshot
    runner-version           = var.runner.version
    runner-deb-sha256        = var.runner.deb_sha256
    runner-helper-deb-sha256 = var.runner.helper_deb_sha256
    fleeting-plugin-version  = var.runner.plugin_version
    fleeting-plugin-sha256   = var.runner.plugin_sha256
    runner-pools             = join(" ", sort(keys(var.pools)))
    runner-config = templatefile("${path.module}/files/config.toml.tftpl", {
      project       = google_project.ci.project_id
      zone          = var.zone
      default_image = var.runner.default_image
      pools         = { for k, p in var.pools : k => merge(p, { group = google_compute_instance_group_manager.pool[k].name }) }
    })
  }

  depends_on = [google_secret_manager_secret_iam_member.manager_reads_token, google_project_iam_member.manager]
}
