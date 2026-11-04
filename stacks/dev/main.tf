# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev project: the dev cluster, DNS for dev hostnames, the cluster pipeline's identity, the deployments'
# certificate secrets and challenge zones, the gateway's address and tacplus.dev's zone. Its folder is the folder stack's; its billing account is the bootstrap
# project's.

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

data "google_active_folder" "dev" {
  display_name = module.settings.projects.dev.folder
  parent       = module.settings.parent_folder
}

data "google_project" "bootstrap" {
  project_id = module.settings.bootstrap.project
}

module "dev" {
  source          = "../../modules/projects/dev"
  project_id      = module.settings.projects.dev.project
  name            = module.settings.projects.dev.name
  folder          = data.google_active_folder.dev.name
  billing_account = data.google_project.bootstrap.billing_account
  region          = module.settings.region
  cluster = {
    name            = "dev"
    zone            = "${module.settings.region}-a"
    release_channel = "REGULAR"
    disk_gb         = 100
    # Jody, 2026-11-04 (#7): 3 x c4a-standard-2 on demand; builds on c4a-standard-4 spot, from 0 to 3.
    normal = { machine_type = "c4a-standard-2", nodes = 3 }
    spot   = { machine_type = "c4a-standard-4", max_nodes = 3 }
  }
  network = {
    nodes         = "10.20.0.0/20"
    pods          = "10.24.0.0/14"
    services      = "10.28.0.0/20"
    control_plane = "172.16.0.0/28"
  }
  dns  = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
  zone = module.settings.zone
  cluster_pipeline = {
    account_id     = "cluster-admin-pipeline"
    gitlab_project = "tacplus-dev/cluster"
    pool           = "gitlab-com"
    provider       = "tacplus-dev-cluster"
  }
  deployments = module.settings.deployments
}

output "project_id" {
  value = module.dev.project_id
}

output "cluster" {
  value = module.dev.cluster
}

output "dns_name_servers" {
  value = module.dev.dns_name_servers
}

output "cluster_pipeline" {
  value = module.dev.cluster_pipeline
}

output "deployments" {
  value = module.dev.deployments
}

output "gateway_address" {
  value = module.dev.gateway_address
}

output "zone" {
  value = module.dev.zone
}
