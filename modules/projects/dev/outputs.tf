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
