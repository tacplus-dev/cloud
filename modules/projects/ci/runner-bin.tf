# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The runner manager's binaries (#40): GitLab Runner and the googlecloud fleeting plugin, our builds (ci/runner.sh,
# into the tools job's bin/manager/), in a bucket only the manager's account reads among the VMs' and the jobs'
# (the pipeline, which writes them, and break-glass read it through their project roles). Each object is named by its
# SHA-256, so a new build is a new object and never overwrites the one a running manager booted from. Nothing the
# manager runs comes from upstream at boot (Jody's rule on #39).

resource "google_storage_bucket" "runner_bin" {
  project                     = google_project.ci.project_id
  name                        = "${var.project_id}-runner-bin"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Its objects are the builds of the pinned commits, which every tools job makes again.
  force_destroy = true
  labels        = { managed-by = "tacplus-dev-cloud" }
  depends_on    = [terraform_data.iam_ready]
}

# Authoritative for the role: the manager alone reads the objects.
resource "google_storage_bucket_iam_binding" "runner_bin" {
  bucket  = google_storage_bucket.runner_bin.name
  role    = "roles/storage.objectViewer"
  members = [google_service_account.manager.member]
}

locals {
  runner_bin = {
    gitlab-runner               = var.runner.runner_sha256
    fleeting-plugin-googlecloud = var.runner.plugin_sha256
  }
}

resource "google_storage_bucket_object" "runner_bin" {
  for_each     = local.runner_bin
  bucket       = google_storage_bucket.runner_bin.name
  name         = "${each.key}/${each.value}"
  source       = "${var.runner_bin}/${each.key}"
  content_type = "application/octet-stream"
  lifecycle {
    # Uploaded only as the pinned build: the tools job refuses any other, and so does this.
    precondition {
      condition     = filesha256("${var.runner_bin}/${each.key}") == each.value
      error_message = "${var.runner_bin}/${each.key} is not the pinned build (ci/runner.sh, stacks/ci/main.tf's runner block)."
    }
    # The new object exists before the old one goes: the manager replaced in the same apply boots from it.
    create_before_destroy = true
  }
}
