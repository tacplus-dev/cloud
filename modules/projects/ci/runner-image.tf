# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The bake of the pools' image (#4, looper#43): looper's `runner-image build`, run by tacplus-dev/build's job
# runner-image, boots a VM in the runners' subnet with no external address, no account and no scopes, images its
# disk and publishes runner-arm64-docker-<date>-<time>, keyless. Only that project's protected main, in its
# environment runner-image, from the web or its schedule, may become runner-image (the provider's condition). It may
# manage the bake's own VMs (runner-image-*), their disks and the images it publishes (runner-arm64-docker-*), and
# use the runners' subnet; nothing else. The pools boot an image only once modules/settings pins it by name.

resource "google_service_account" "runner_image" {
  project      = google_project.ci.project_id
  account_id   = var.runner_image_bake.account_id
  display_name = "Runner image bake, ${var.runner_image_bake.gitlab_project} protected main (tacplus-dev/cloud)"
  depends_on   = [google_project_service.service]
}

resource "google_project_iam_custom_role" "runner_image" {
  project = google_project.ci.project_id
  role_id = "runnerImageBaker"
  title   = "Runner image bake (tacplus-dev/cloud#4)"
  permissions = [
    "compute.disks.create", "compute.disks.delete", "compute.disks.get", "compute.disks.setLabels", "compute.disks.use",
    "compute.disks.useReadOnly",
    "compute.globalOperations.get",
    "compute.images.create", "compute.images.delete", "compute.images.get", "compute.images.getFromFamily",
    "compute.images.list", "compute.images.setLabels", "compute.images.useReadOnly",
    "compute.instances.create", "compute.instances.delete", "compute.instances.get",
    "compute.instances.getGuestAttributes", "compute.instances.getSerialPortOutput", "compute.instances.setLabels",
    "compute.instances.setMetadata", "compute.instances.stop",
    "compute.machineTypes.get", "compute.projects.get", "compute.zoneOperations.get", "compute.zones.get",
  ]
}

# Its instances, disks and images only by their names; the operations, zones and machine types it reads are not
# those types.
resource "google_project_iam_member" "runner_image" {
  project = google_project.ci.project_id
  role    = google_project_iam_custom_role.runner_image.name
  member  = google_service_account.runner_image.member
  condition {
    title       = "runner-image only"
    description = "The bake's own instances and disks (runner-image-*) and images (${var.runner_image_bake.family}-*)."
    expression  = <<-EOT
      !(resource.type in ["compute.googleapis.com/Instance", "compute.googleapis.com/Disk", "compute.googleapis.com/Image"])
      || resource.name.extract("/instances/{n}").startsWith("runner-image-")
      || resource.name.extract("/disks/{n}").startsWith("runner-image-")
      || resource.name.extract("/images/{n}").startsWith("${var.runner_image_bake.family}-")
    EOT
  }
}

# Its VMs are in the runners' subnet, reaching the archives through its NAT (looper#67: RUNNER_IMAGE_SUBNET).
resource "google_compute_subnetwork_iam_member" "runner_image" {
  project    = google_project.ci.project_id
  region     = var.region
  subnetwork = google_compute_subnetwork.runners.name
  role       = "roles/compute.networkUser"
  member     = google_service_account.runner_image.member
}

resource "google_iam_workload_identity_pool" "gitlab" {
  project                   = google_project.ci.project_id
  workload_identity_pool_id = var.runner_image_bake.pool
  display_name              = "gitlab.com"
  description               = "GitLab CI jobs of tacplus-dev (tacplus-dev/cloud)"
  depends_on                = [google_project_service.service]
}

resource "google_iam_workload_identity_pool_provider" "runner_image" {
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = var.runner_image_bake.provider
  display_name                       = var.runner_image_bake.gitlab_project
  attribute_mapping = {
    "google.subject"            = "assertion.sub"
    "attribute.project_path"    = "assertion.project_path"
    "attribute.ref"             = "assertion.ref"
    "attribute.ref_type"        = "assertion.ref_type"
    "attribute.ref_protected"   = "assertion.ref_protected"
    "attribute.environment"     = "assertion.environment"
    "attribute.pipeline_source" = "assertion.pipeline_source"
  }
  attribute_condition = "assertion.project_path == '${var.runner_image_bake.gitlab_project}' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true' && assertion.environment == '${var.runner_image_bake.environment}' && assertion.pipeline_source in ['web', 'schedule']"
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

resource "google_service_account_iam_member" "runner_image_wif" {
  service_account_id = google_service_account.runner_image.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_path/${var.runner_image_bake.gitlab_project}"
}
