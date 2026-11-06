# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The public entry (#21; decisions/network-exposure-2026-11-03.md, its addendum "we terminate TLS, not the cloud"):
# Google's global external proxy Network Load Balancer (TCP proxy) on the global address gateway (dns.tf), the one
# public IP. Each listener is a port of the address: its forwarding rule, its target TCP proxy and its backend service,
# whose backend is the standalone zonal NEG a Service in the dev cluster exposes (the NEG's name is the settings', a
# contract with whoever renders that Service), with a TCP health check on the endpoints' port. TLS passes through
# unopened and ends in the pods (the tacplus gateway, with the pipeline's certificate): there is no certificate, no SSL
# policy and no HTTP(S) or SSL proxy on Google's side, which ci/policy.sh refuses in any plan. The nodes admit the
# endpoints' port from Google's proxies and health checkers only: GKE makes no firewall rule for a standalone NEG.

locals {
  # Where a global external proxy Network Load Balancer's proxies and its health checks come from.
  google_proxy_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

resource "google_compute_health_check" "lb" {
  for_each    = var.load_balancer
  project     = google_project.dev.project_id
  name        = "lb-${each.key}"
  description = "The ${each.key} listener's NEG ${each.value.neg}: a TCP connect to its endpoints (tacplus-dev/cloud)"
  tcp_health_check {
    port = each.value.endpoint_port
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_compute_backend_service" "lb" {
  for_each              = var.load_balancer
  project               = google_project.dev.project_id
  name                  = "lb-${each.key}"
  description           = "The ${each.key} listener: the NEG ${each.value.neg}, TLS passed through (tacplus-dev/cloud)"
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.lb[each.key].id]
  # A TCP proxy's idle timeout: a day, so that a quiet stream (gRPC, a watch) is not cut after the default 30 s.
  timeout_sec = 86400
  # The NEG is GKE's, made when its Service is rendered: until then, no backend (the API refuses a missing NEG).
  dynamic "backend" {
    for_each = each.value.ready ? [each.value.neg] : []
    content {
      group                        = "projects/${google_project.dev.project_id}/zones/${var.cluster.zone}/networkEndpointGroups/${backend.value}"
      balancing_mode               = "CONNECTION"
      max_connections_per_endpoint = 1000
    }
  }
}

resource "google_compute_target_tcp_proxy" "lb" {
  for_each        = var.load_balancer
  project         = google_project.dev.project_id
  name            = "lb-${each.key}"
  description     = "The ${each.key} listener, on port ${each.value.port} of the address gateway (tacplus-dev/cloud)"
  backend_service = google_compute_backend_service.lb[each.key].id
  proxy_header    = "NONE"
}

resource "google_compute_global_forwarding_rule" "lb" {
  for_each              = var.load_balancer
  project               = google_project.dev.project_id
  name                  = "lb-${each.key}"
  description           = "The ${each.key} listener: TCP ${each.value.port} of the address gateway (tacplus-dev/cloud)"
  ip_address            = google_compute_global_address.gateway.id
  ip_protocol           = "TCP"
  port_range            = tostring(each.value.port)
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_tcp_proxy.lb[each.key].id
  labels                = { managed-by = "tacplus-dev-cloud" }
}

# The nodes' one ingress rule from outside the network: Google's proxies and health checkers, on the endpoints' ports
# (none without a listener: a rule with no port would allow them all).
resource "google_compute_firewall" "lb" {
  count                   = length(var.load_balancer) > 0 ? 1 : 0
  project                 = google_project.dev.project_id
  name                    = "allow-google-proxies"
  description             = "The TCP proxy's connections and health checks to the NEGs' endpoints (tacplus-dev/cloud)"
  network                 = google_compute_network.dev.id
  direction               = "INGRESS"
  source_ranges           = local.google_proxy_ranges
  target_service_accounts = [google_service_account.nodes.email]
  allow {
    protocol = "tcp"
    ports    = sort(distinct([for l in values(var.load_balancer) : tostring(l.endpoint_port)]))
  }
}
