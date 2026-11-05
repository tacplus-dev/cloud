# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The public entry point and the domain's own zone (#13; decisions/only-vms-are-k8s-nodes-2026-11-04.md, its addendum on
# the new cluster; decisions/network-exposure-2026-11-03.md). The gateway's load balancer has the one public
# IP, a reserved global address the Gateway names (NamedAddress), which outlives any rebuild of the load balancer. The
# zone of the domain (tacplus.dev) is written only by this pipeline: the records copied from the zone it replaces, each
# deployment's hostnames to the gateway's address, and the delegations of the dev zone and the challenge zones. Its
# name servers are what the registrar is given (README, The tacplus.dev cutover).

# IPv4 only: GKE documents one static global address (NamedAddress) for its global external Gateway class, nothing of a
# second, IPv6 one beside it (PROPOSALS.md, IPv6 on the Gateway).
resource "google_compute_global_address" "gateway" {
  project      = google_project.dev.project_id
  name         = "gateway"
  description  = "The dev cluster's Gateway load balancer: the one public IP (tacplus-dev/cloud)"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  depends_on   = [terraform_data.iam_ready]
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # The domain without its trailing dot, and each record by "<name> <type>".
  zone_domain = trimsuffix(var.zone.domain, ".")
  copied      = { for r in var.zone.records : "${r.name} ${r.type}" => r }
  # Each deployment's hostnames in this zone: A to the gateway's address.
  hostnames = toset(flatten([for d in values(var.deployments) : [for h in d.hostnames : "${h}."]]))
  # The zones under this one, delegated by NS records to their name servers.
  delegations = merge(
    endswith(var.dns.domain, ".${var.zone.domain}") ? { (var.dns.domain) = google_dns_managed_zone.dev.name_servers } : {},
    { for k, d in var.deployments : "_acme-challenge.${d.domain}." => google_dns_managed_zone.acme_challenge[k].name_servers if d.domain == local.zone_domain },
  )
}

resource "google_dns_managed_zone" "zone" {
  project     = google_project.dev.project_id
  name        = var.zone.zone
  dns_name    = var.zone.domain
  description = "${local.zone_domain}: written only by tacplus-dev/cloud's pipeline"
  labels      = { managed-by = "tacplus-dev-cloud" }
  dnssec_config {
    state = "on"
  }
  depends_on = [terraform_data.iam_ready]
  lifecycle {
    precondition {
      condition     = alltrue([for h in local.hostnames : endswith(h, ".${var.zone.domain}")])
      error_message = "A deployment's hostname is not in ${var.zone.domain}."
    }
    precondition {
      condition     = alltrue([for r in var.zone.records : !contains(keys(local.delegations), r.name) && !(contains(local.hostnames, r.name) && contains(["A", "CNAME"], r.type))])
      error_message = "A copied record is at a delegated name, or at a deployment's hostname, which point elsewhere."
    }
  }
}

# The records of the zone it replaces, as they are there.
resource "google_dns_record_set" "copied" {
  for_each     = local.copied
  project      = google_project.dev.project_id
  managed_zone = google_dns_managed_zone.zone.name
  name         = each.value.name
  type         = each.value.type
  ttl          = each.value.ttl
  rrdatas      = each.value.rrdatas
}

# Short-lived, so that a new address reaches the resolvers within minutes.
resource "google_dns_record_set" "gateway" {
  for_each     = local.hostnames
  project      = google_project.dev.project_id
  managed_zone = google_dns_managed_zone.zone.name
  name         = each.key
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.gateway.address]
}

resource "google_dns_record_set" "delegation" {
  for_each     = local.delegations
  project      = google_project.dev.project_id
  managed_zone = google_dns_managed_zone.zone.name
  name         = each.key
  type         = "NS"
  ttl          = 300
  rrdatas      = each.value
}
