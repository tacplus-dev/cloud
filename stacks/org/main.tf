# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The organization's org policies, the folders ci and dev, and who reads the organization.

module "settings" {
  source = "../../modules/settings"
}

provider "google" {
  region = module.settings.region
}

module "org" {
  source      = "../../modules/org"
  domain      = module.settings.domain
  region      = module.settings.region
  folders     = sort([for p in values(module.settings.projects) : p.folder])
  pipeline_sa = module.settings.bootstrap.pipeline_sa
  # People, the hub included, read only: their tacplus.dev accounts, added here by a commit (README, People).
  readers = []
}

output "org_id" {
  value = module.org.org_id
}

output "folders" {
  value = module.org.folders
}
