# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Under the parent folder the host organization hands over: the folders ci and dev, and who reads the parent folder.
# The org policies are the host organization's job (README).

variable "parent_folder" {
  description = "The parent folder's numeric ID: the protected GitLab variable GCP_PARENT_FOLDER (ci/lib.sh), never written here."
  type        = string
}

module "settings" {
  source        = "../../modules/settings"
  parent_folder = var.parent_folder
}

provider "google" {
  region = module.settings.region
}

module "folder" {
  source        = "../../modules/folder"
  parent_folder = module.settings.parent_folder
  folders       = sort([for p in values(module.settings.projects) : p.folder])
  pipeline_sa   = module.settings.bootstrap.pipeline_sa
  # People, the hub included, read only: their accounts, added here by a commit (README, People).
  readers = []
}

output "parent_folder" {
  value = module.settings.parent_folder
}

output "folders" {
  value = module.folder.folders
}
