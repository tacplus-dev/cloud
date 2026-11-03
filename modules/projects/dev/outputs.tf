# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_id" {
  description = "The dev project's ID."
  value       = google_project.dev.project_id
}

output "cluster" {
  description = "The dev cluster's name and zone."
  value       = { name = google_container_cluster.dev.name, zone = google_container_cluster.dev.location }
}

output "dns_name_servers" {
  description = "The dev zone's name servers: the NS records its delegation in tacplus.dev's zone needs."
  value       = google_dns_managed_zone.dev.name_servers
}

output "cluster_pipeline" {
  description = "tacplus-dev/cluster's GCP_WIF_PROVIDER and GCP_DEPLOY_SA."
  value = {
    wif_provider = google_iam_workload_identity_pool_provider.cluster.name
    sa           = google_service_account.cluster_pipeline.email
  }
}

output "deployments" {
  description = "Each deployment's GCP_WIF_PROVIDER and service account, its certificate secrets, and its challenge zone with the name servers its delegation needs."
  value = {
    for k, d in var.deployments : k => {
      wif_provider   = google_iam_workload_identity_pool_provider.deploy[k].name
      sa             = google_service_account.deploy[k].email
      secrets        = { tls = "projects/${google_project.dev.project_id}/secrets/tls-${k}", acme_account = "projects/${google_project.dev.project_id}/secrets/acme-account-${d.environment}" }
      challenge_zone = google_dns_managed_zone.acme_challenge[k].name
      name_servers   = google_dns_managed_zone.acme_challenge[k].name_servers
    }
  }
}
