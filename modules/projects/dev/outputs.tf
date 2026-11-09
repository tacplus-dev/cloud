# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

output "project_id" {
  description = "The dev project's ID."
  value       = google_project.dev.project_id
}

output "cluster" {
  description = "The dev cluster's name and zone, and the spot build pool's node label and taint, which only build pods tolerate (tacplus-dev/cluster#6)."
  value = {
    name       = google_container_cluster.dev.name
    zone       = google_container_cluster.dev.location
    spot_label = local.pools.spot.labels
    spot_taint = local.pools.spot.taints[0]
  }
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
  description = "Each deployment's GCP_WIF_PROVIDER and service account, its certificate secrets, its challenge zone with the name servers its delegation needs, its deploy registry and its Cloud Build bucket and account (null without images), its environment accounts' service accounts, by GitLab environment, and its fleet secrets with the init-secrets job's environment and service account (null without init_secrets)."
  value = {
    for k, d in var.deployments : k => {
      wif_provider         = google_iam_workload_identity_pool_provider.deploy[k].name
      sa                   = google_service_account.deploy[k].email
      secrets              = { tls = "projects/${google_project.dev.project_id}/secrets/tls-${k}", acme_account = "projects/${google_project.dev.project_id}/secrets/acme-account-${d.environment}" }
      challenge_zone       = google_dns_managed_zone.acme_challenge[k].name
      name_servers         = google_dns_managed_zone.acme_challenge[k].name_servers
      registry             = d.images == null ? null : "${google_artifact_registry_repository.deploy[k].location}-docker.pkg.dev/${google_project.dev.project_id}/${google_artifact_registry_repository.deploy[k].repository_id}"
      build                = d.images == null ? null : { bucket = "gs://${google_storage_bucket.build[k].name}", sa = google_service_account.build[k].email }
      environment_accounts = { for e in keys(d.environment_accounts) : e => google_service_account.environment["${k}/${e}"].email }
      fleet_secrets        = d.init_secrets == null ? null : { ca = "projects/${google_project.dev.project_id}/secrets/${google_secret_manager_secret.fleet["fleet-ca-${k}"].secret_id}", crypto = "projects/${google_project.dev.project_id}/secrets/${google_secret_manager_secret.fleet["fleet-crypto-${k}"].secret_id}", environment = d.init_secrets.environment, sa = google_service_account.init_secrets[k].email }
    }
  }
}

output "gateway_address" {
  description = "The public address: its name, which the load balancer's forwarding rules name, and its IP, which the hostnames get."
  value = {
    name    = google_compute_global_address.gateway.name
    address = google_compute_global_address.gateway.address
  }
}

output "zone" {
  description = "The domain's zone: its name, its domain, and its name servers, the values the registrar is given (README, The tacplus.dev cutover)."
  value = {
    name         = google_dns_managed_zone.zone.name
    domain       = google_dns_managed_zone.zone.dns_name
    name_servers = google_dns_managed_zone.zone.name_servers
  }
}

output "runner_tokens" {
  description = "The runners' token secrets, by runner (tacplus-dev/cluster's tacplus.token names their versions)."
  value       = { for k, s in local.runner_tokens : k => "projects/${google_project.dev.project_id}/secrets/${google_secret_manager_secret.runner_token[s].secret_id}" }
}

output "cluster_api" {
  description = "The dev cluster's API, for the stack's kubernetes provider (cluster-pipeline.tf): its endpoint, and its CA certificate in base64, as GKE gives it."
  value = {
    host                   = "https://${google_container_cluster.dev.endpoint}"
    cluster_ca_certificate = one(google_container_cluster.dev.master_auth[*].cluster_ca_certificate)
  }
}

output "load_balancer" {
  description = "The public entry (#21): the address's IP, and by listener its NEG's name and zone, its port on the address and its endpoints' port (the contract with the Services that expose the NEGs), and the ranges the nodes admit their connections from."
  value = {
    address       = google_compute_global_address.gateway.address
    negs          = { for k, l in var.load_balancer : k => { neg = l.neg, zone = var.cluster.zone, port = l.port, endpoint_port = l.endpoint_port } }
    source_ranges = sort(local.google_proxy_ranges)
  }
}
