# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: runners, the build cache, the reader app's key. Its folder is the org stack's; its billing
# account is the bootstrap project's.

module "settings" {
  source = "../../modules/settings"
}

provider "google" {
  region = module.settings.region
}

data "google_organization" "org" {
  domain = module.settings.domain
}

data "google_active_folder" "ci" {
  display_name = module.settings.projects.ci.folder
  parent       = data.google_organization.org.name
}

data "google_project" "bootstrap" {
  project_id = module.settings.bootstrap.project
}

module "ci" {
  source               = "../../modules/projects/ci"
  project_id           = module.settings.projects.ci.project
  name                 = module.settings.projects.ci.name
  folder               = data.google_active_folder.ci.name
  billing_account      = data.google_project.bootstrap.billing_account
  region               = module.settings.region
  zone                 = "${module.settings.region}-b"
  subnet_cidr          = "10.10.0.0/20"
  image                = module.settings.ubuntu_arm64_image.image
  apt_snapshot         = module.settings.ubuntu_arm64_image.snapshot
  pool_image           = module.settings.cos_arm64_image
  manager_machine_type = "t2a-standard-1"
  runner = {
    version           = "v19.5.2"
    deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
    helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
    plugin_version    = "v1.3.1"
    plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
    default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
  }
  pools          = { for k, p in module.settings.runner_pools : k => { for a, v in p : a => v if a != "runner" } }
  build_cache    = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
  reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
}

output "project_id" {
  value = module.ci.project_id
}

output "runner_token_secrets" {
  value = module.ci.runner_token_secrets
}

output "reader_app_key" {
  value = module.ci.reader_app_key
}
