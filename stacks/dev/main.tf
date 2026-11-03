# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev project: the dev cluster, DNS for dev hostnames, the cluster pipeline's identity, the deployments'
# certificate secrets and challenge zones. Its folder is the org stack's; its billing account is the bootstrap
# project's.

module "settings" {
  source = "../../modules/settings"
}

provider "google" {
  region = module.settings.region
}

data "google_organization" "org" {
  domain = module.settings.domain
}

data "google_active_folder" "dev" {
  display_name = module.settings.projects.dev.folder
  parent       = data.google_organization.org.name
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
    machine_type    = "c4a-standard-4"
    disk_gb         = 100
    min_nodes       = 1
    max_nodes       = 3
  }
  network = {
    nodes         = "10.20.0.0/20"
    pods          = "10.24.0.0/14"
    services      = "10.28.0.0/20"
    control_plane = "172.16.0.0/28"
  }
  dns = { zone = "dev-tacplus-dev", domain = "dev.${module.settings.domain}." }
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
