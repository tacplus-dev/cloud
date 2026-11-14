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
    # A spot VM in a managed instance group takes GCP's default termination action (STOP; DELETE is refused there,
    # 2026-11-10): a reclaimed VM stays stopped, its group does nothing (the groups' instance_lifecycle_policy, #53),
    # and the plugin deletes it; the autoscaler then asks for another, made where there is capacity.
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
    provisioning_model  = each.value.spot ? "SPOT" : "STANDARD"
    preemptible         = each.value.spot
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

# A pool in the stack's zone.
resource "google_compute_instance_group_manager" "pool" {
  for_each           = { for k, p in var.pools : k => p if length(p.zones) == 0 }
  project            = google_project.ci.project_id
  name               = "runner-${each.key}"
  zone               = var.zone
  base_instance_name = "runner-${each.key}"
  target_size        = 0
  version {
    instance_template = google_compute_instance_template.pool[each.key].self_link_unique
  }
  # A VM its group did not stop (a spot VM reclaimed, a VM failed) is left as it is, not repaired (#53): the plugin
  # deletes it, as it does every stopped VM, and the autoscaler's next one goes where there is capacity, which is what
  # upstream's README recommends. A repair recreates it in its own zone, and one in a zone out of spot t2a is retried
  # there for as long as it is out, counted by the autoscaler as coming (the build pool's VM lost at 10:26Z on
  # 2026-11-13, most likely reclaimed, and no build VM after it).
  instance_lifecycle_policy {
    default_action_on_failure = "DO_NOTHING"
  }
  # The manager's autoscaler sizes the group: its idle VMs, and the VMs its jobs need.
  lifecycle {
    ignore_changes = [target_size]
  }
}

# A pool spread over the region's zones (#49): a zone out of capacity (spot t2a in us-central1-b, 2026-11-12) stalls
# none of its jobs. Target shape ANY makes each new VM in a zone that has the capacity, and never deletes one to even
# the zones out (redistribution off, which ANY requires, as the plugin does to suspend). A VM already stuck creating in
# a zone out of capacity is not moved: the manager's reaper deletes it (files/manager-startup.sh), and the autoscaler's
# next one goes where there is room. No surge: the group never grows past what the manager asked for, inside the quota.
resource "google_compute_region_instance_group_manager" "pool" {
  for_each = { for k, p in var.pools : k => p if length(p.zones) > 0 }
  project  = google_project.ci.project_id
  # Not runner-<pool>: a regional group makes a zonal instance group of its name in each of its zones, and the pool's
  # zonal group (runner-<pool> in the stack's zone) still exists while this one is created (2026-11-12, 409).
  name                             = "runner-${each.key}-region"
  region                           = var.region
  distribution_policy_zones        = each.value.zones
  distribution_policy_target_shape = "ANY"
  base_instance_name               = "runner-${each.key}"
  target_size                      = 0
  version {
    instance_template = google_compute_instance_template.pool[each.key].self_link_unique
  }
  # A VM its group did not stop (a spot VM reclaimed, a VM failed) is left as it is, not repaired (#53): the plugin
  # deletes it, as it does every stopped VM, and the autoscaler's next one goes where there is capacity, which is what
  # upstream's README recommends. A repair recreates it in its own zone, and one in a zone out of spot t2a is retried
  # there for as long as it is out, counted by the autoscaler as coming (the build pool's VM lost at 10:26Z on
  # 2026-11-13, most likely reclaimed, and no build VM after it).
  instance_lifecycle_policy {
    default_action_on_failure = "DO_NOTHING"
  }
  update_policy {
    type                         = "OPPORTUNISTIC"
    minimal_action               = "REPLACE"
    instance_redistribution_type = "NONE"
    max_surge_fixed              = 0
    max_unavailable_fixed        = length(each.value.zones)
  }
  # The manager's autoscaler sizes the group: its idle VMs, and the VMs its jobs need.
  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_instance" "manager" {
  project                   = google_project.ci.project_id
  name                      = local.manager_name
  zone                      = var.zone
  machine_type              = local.manager_build.machine_type
  tags                      = ["runner-manager"]
  labels                    = { managed-by = "tacplus-dev-cloud" }
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = local.manager_build.image
      size  = local.manager_build.disk_gb
      type  = local.manager_build.disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id
  }

  service_account {
    email  = google_service_account.manager.email
    scopes = ["cloud-platform"]
  }

  metadata = local.manager_metadata

  # Never without a manager (#46): every runner of the fleet is its, and the apply that replaces it runs on one of them.
  # A new build replaces it, the new manager up before the old one goes (its name is the build's, so both can be);
  # a new config (a pool raised, a tag moved) is an in-place metadata update, which the running manager's watcher
  # applies (files/manager-startup.sh) with no restart and no job lost. And never a job lost to a new one (#48): the
  # old one is forgotten, not destroyed. The new one tells it to retire, and it deletes itself once its jobs are done
  # (the apply's own among them), before the new one's gitlab-runner starts on emptied groups (files/manager-startup.sh).
  # ci/policy.sh refuses a plan that would destroy it, and a source without either setting.
  lifecycle {
    create_before_destroy = true
    destroy               = false
  }

  # Its builds are in the bucket, and readable by it, before it boots.
  depends_on = [google_secret_manager_secret_iam_member.manager_reads_token, google_project_iam_member.manager, google_storage_bucket_object.runner_bin, google_storage_bucket_iam_binding.runner_bin]
}

locals {
  # Each pool's group: its name, and where it is (the plugin's region or zone, and its path in the Compute API).
  groups = merge(
    { for k, g in google_compute_instance_group_manager.pool : k => { name = g.name, scope = "zone", location = var.zone, path = "zones/${var.zone}/instanceGroupManagers/${g.name}" } },
    { for k, g in google_compute_region_instance_group_manager.pool : k => { name = g.name, scope = "region", location = var.region, path = "regions/${var.region}/instanceGroupManagers/${g.name}" } },
  )
  manager_config = templatefile("${path.module}/files/config.toml.tftpl", {
    project       = google_project.ci.project_id
    default_image = var.runner.default_image
    helper_image  = var.runner.helper_image
    pools         = { for k, p in var.pools : k => merge(p, { group = local.groups[k] }) }
  })
}

# The manager's build: what it is made of and boots from, the VM (its image, machine type, disk and zone; a stop
# for an update would take every runner down with it, as a replacement would), the startup script, GitLab Runner
# and the fleeting plugin from the bucket by SHA-256 (#40), and each pool's autoscaler but its policy (#61). A change
# to any of it replaces the manager, and its name, the build's hash, lets the new one be made before the old one goes
# (#46). The config, the rest of its metadata, is not the build: it is pushed to the running manager, which reloads
# it. Not the autoscaler: gitlab-runner reads it once, at a pool's first job, and a reload changes only its policy
# (v19.5.3, executors/internal/autoscaler/provider.go), so #50's ready check, pushed in place, was not live until
# gitlab-runner restarted. Nor may the manager restart it in place: a gitlab-runner that starts removes every pool VM
# it finds, jobs and all ("no data on pre-existing instance so removing for safety"); a new manager's handoff drains
# them first, capped (#51).
locals {
  manager_build = {
    image                  = var.image
    machine_type           = var.manager_machine_type
    disk_gb                = 20
    disk_type              = "pd-balanced"
    zone                   = var.zone
    startup-script         = file("${path.module}/files/manager-startup.sh")
    runner-sha256          = var.runner.runner_sha256
    fleeting-plugin-sha256 = var.runner.plugin_sha256
    # Each pool's [runners.autoscaler] as config.toml has it, up to its policy, which comes last.
    autoscaler = regexall("(?ms)^ *\\[runners\\.autoscaler\\].*?\\[\\[runners\\.autoscaler\\.policy\\]\\]", local.manager_config)
  }
  manager_name = "runner-manager-${substr(sha256(jsonencode(local.manager_build)), 0, 8)}"
  manager_metadata = {
    startup-script         = local.manager_build.startup-script
    runner-bucket          = google_storage_bucket.runner_bin.name
    runner-sha256          = local.manager_build.runner-sha256
    fleeting-plugin-sha256 = local.manager_build.fleeting-plugin-sha256
    runner-pools           = join(" ", sort(keys(var.pools)))
    runner-groups          = join(" ", [for k in sort(keys(var.pools)) : local.groups[k].path])
    runner-config          = local.manager_config
    # Config, not the build (#51): read by the next new manager's handoff, which caps the old one's drain with it.
    runner-handoff-limit = tostring(var.manager_handoff_minutes * 60)
  }
}

# The config's hash, the manager's replace_triggered_by until #46, which removed it: forgotten, not destroyed (#47). It
# has no remote object, and its destroy, which a manager made before #46 waits for (its stored dependencies name it),
# needs the pools' templates and groups, which the new manager's config needs: with a deposed manager in the state (the
# crashed apply of 2026-11-12), the plan had a cycle. A forget is no node of the graph.
removed {
  from = terraform_data.manager_config
  lifecycle {
    destroy = false
  }
}
