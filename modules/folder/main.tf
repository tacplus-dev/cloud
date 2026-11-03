# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Under the parent folder the host organization hands to this repository: the folders (but bootstrap's, which
# bootstrap/bootstrap.sh made), the pipeline's rights on them, and the people's read-only access. The org policies
# are the host organization's job, not this repository's (README, What the host organization provides): it holds no
# right over the host's organization.

resource "google_folder" "folder" {
  for_each            = toset(var.folders)
  display_name        = each.key
  parent              = var.parent_folder
  deletion_protection = true
}

# The pipeline owns what is under its folders (the projects it creates there, and their IAM).
resource "google_folder_iam_member" "pipeline_owner" {
  for_each = google_folder.folder
  folder   = each.value.name
  role     = "roles/owner"
  member   = "serviceAccount:${var.pipeline_sa}"
}

# People, the hub included, read only (tacplus-dev/roadmap decisions/cloud-pipeline-2026-11-02.md).
resource "google_folder_iam_member" "reader" {
  for_each = { for p in setproduct(var.readers, ["roles/viewer", "roles/iam.securityReviewer"]) : "${p[0]} ${p[1]}" => p }
  folder   = var.parent_folder
  member   = each.value[0]
  role     = each.value[1]
}
