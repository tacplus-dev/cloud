# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev stack's plan under a stub parent folder, with an empty project (mock providers: no credentials, no
# cloud): the stack plans, and its module, with the stack's inputs, gives the arm64 cluster (private COS nodes: a normal
# pool of 3 x c4a-standard-2 on demand, and a spot build pool of c4a-standard-4 from 0 to 3, labelled and tainted
# spot=true, #7), the dev zone and the
# cluster pipeline's identity, federated from tacplus-dev/cluster's protected main alone, and each deployment's
# certificate secrets and _acme-challenge zone, which only its pipeline's identity reads and writes (#6), and the
# gateway's one global address, kept from destruction (ci/policy.sh checks prevent_destroy and that no other external
# address is in a plan), and tacplus.dev's zone: its copied records, the deployment's hostnames to that address, the
# delegations, and its name servers for the registrar (#13), and the runners' token secrets, which the cluster pipeline
# reads and only the listed people add versions to, and the cluster pipeline's cluster-admin, a ClusterRoleBinding
# made in the cluster through the kubernetes provider, with no service account of dev holding container.admin or owner
# in IAM (#18), and the public entry (#21): a global external proxy Network Load Balancer (TCP proxy) on the address
# gateway, one forwarding rule per listener, to the NEGs the settings name, a TCP health check on their endpoints'
# port, no TLS on Google's side, and the nodes open to Google's proxies and health checkers only, on that port. (A
# test sees a module's resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_active_folder" {
    defaults = { name = "folders/444" }
  }
  mock_data "google_project" {
    defaults = { billing_account = "000000-111111-222222", number = "333" }
  }
  # Computed at apply; the stub gives values of the right form.
  mock_resource "google_service_account" {
    defaults = { email = "stub-account@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:stub-account@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/stub-account@tacplus-dev.iam.gserviceaccount.com" }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/555/locations/global/workloadIdentityPools/gitlab-com" }
  }
  mock_resource "google_container_cluster" {
    defaults = { endpoint = "203.0.113.20" }
  }
  mock_resource "google_compute_global_address" {
    defaults = { address = "203.0.113.10" }
  }
  mock_resource "google_dns_managed_zone" {
    defaults = { name_servers = ["ns-cloud-b1.googledomains.com.", "ns-cloud-b2.googledomains.com.", "ns-cloud-b3.googledomains.com.", "ns-cloud-b4.googledomains.com."] }
  }
}

mock_provider "kubernetes" {}

# The parent folder, as the pipeline gives it (GCP_PARENT_FOLDER).
variables {
  parent_folder = "111111111111"
  # As GCP_RUNNER_TOKEN_ADDERS gives it: an account of the host's directory, which no file here names.
  runner_token_adders = ["user:jody@example.com"]
}

run "stack" {
  command = plan
  assert {
    condition     = data.google_active_folder.dev.parent == "folders/111111111111"
    error_message = "The folder dev is not looked up under the parent folder."
  }
  assert {
    condition     = output.project_id == "tacplus-dev"
    error_message = "The dev project is not tacplus-dev."
  }
  assert {
    condition     = output.deployments["seatrials"].secrets.tls == "projects/tacplus-dev/secrets/tls-seatrials" && output.deployments["seatrials"].secrets.acme_account == "projects/tacplus-dev/secrets/acme-account-seatrials" && output.deployments["seatrials"].challenge_zone == "acme-challenge-tacplus-dev"
    error_message = "The stack does not give seatrials its certificate secrets and tacplus.dev's challenge zone."
  }
  assert {
    condition     = output.gateway_address == { name = "gateway", address = "203.0.113.10" }
    error_message = "The stack does not give the Gateway its address's name and IP."
  }
  assert {
    condition     = output.zone.name == "tacplus-dev" && output.zone.domain == "tacplus.dev." && length(output.zone.name_servers) == 4
    error_message = "The stack does not print tacplus.dev's zone and its name servers, the registrar's values."
  }
  assert {
    condition     = output.runner_tokens == { build = "projects/tacplus-dev/secrets/gitlab-runner-build", control = "projects/tacplus-dev/secrets/gitlab-runner-control" }
    error_message = "The stack does not give the runners' token secrets, tacplus-dev/cluster's tacplus.token."
  }
  # The NEGs' names are a contract with tacplus-dev/operator (the gateway's) and tacplus-dev/fleet-seatrials (the test
  # IdP's): the stack gives them, with the ports, as the settings name them.
  assert {
    condition     = output.load_balancer.negs == { gateway = { neg = "seatrials-gateway", zone = "us-central1-a", port = 443, endpoint_port = 8443 }, test-idp = { neg = "seatrials-test-idp", zone = "us-central1-a", port = 8443, endpoint_port = 8443 } }
    error_message = "The stack does not give the NEGs' names, zone and ports: seatrials-gateway on 443 and seatrials-test-idp on 8443, endpoints on 8443."
  }
  assert {
    condition     = output.load_balancer.address == "203.0.113.10" && output.load_balancer.source_ranges == tolist(["130.211.0.0/22", "35.191.0.0/16"])
    error_message = "The stack does not give the load balancer's address and the ranges the nodes admit it from."
  }
}

run "dev" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
    runner_token_adders = ["user:jody@example.com"]
    # The gateway's NEG made, the test IdP's not yet.
    load_balancer = {
      gateway  = { port = 443, neg = "seatrials-gateway", endpoint_port = 8443, ready = true }
      test-idp = { port = 8443, neg = "seatrials-test-idp", endpoint_port = 8443, ready = false }
    }
  }

  assert {
    condition     = google_project.dev.folder_id == "folders/444" && !google_project.dev.auto_create_network && google_project.dev.deletion_policy == "PREVENT"
    error_message = "The project is not in its folder, without a default network and protected from deletion."
  }
  # The IAM gate waits for the pipeline's permissions in the new project before its first creates (#16).
  assert {
    condition     = terraform_data.iam_ready.input.project == "tacplus-dev" && alltrue([for x in ["iam.workloadIdentityPools.create", "container.clusters.create"] : contains(terraform_data.iam_ready.input.permissions, x)])
    error_message = "The IAM gate does not wait for the pipeline's permissions in tacplus-dev."
  }
  assert {
    condition     = toset(keys(google_container_node_pool.pool)) == toset(["normal", "spot"]) && google_container_cluster.dev.deletion_protection
    error_message = "The cluster's pools are not normal and spot, or the cluster is not deletion-protected."
  }
  assert {
    condition     = google_container_node_pool.pool["normal"].node_config[0].machine_type == "c4a-standard-2" && google_container_node_pool.pool["normal"].node_count == 3 && length(google_container_node_pool.pool["normal"].autoscaling) == 0 && !google_container_node_pool.pool["normal"].node_config[0].spot && length(google_container_node_pool.pool["normal"].node_config[0].taint) == 0
    error_message = "The normal pool is not 3 x c4a-standard-2, fixed, on demand, untainted."
  }
  assert {
    condition     = google_container_node_pool.pool["spot"].node_config[0].machine_type == "c4a-standard-4" && google_container_node_pool.pool["spot"].node_config[0].spot && google_container_node_pool.pool["spot"].autoscaling[0].min_node_count == 0 && google_container_node_pool.pool["spot"].autoscaling[0].max_node_count == 3
    error_message = "The build pool is not c4a-standard-4 spot, from 0 to 3."
  }
  assert {
    condition     = google_container_node_pool.pool["spot"].node_config[0].labels["spot"] == "true" && length(google_container_node_pool.pool["spot"].node_config[0].taint) == 1 && google_container_node_pool.pool["spot"].node_config[0].taint[0].key == "spot" && google_container_node_pool.pool["spot"].node_config[0].taint[0].value == "true" && google_container_node_pool.pool["spot"].node_config[0].taint[0].effect == "NO_SCHEDULE" && !contains(keys(google_container_node_pool.pool["normal"].node_config[0].labels), "spot")
    error_message = "The build pool is not labelled spot=true and tainted spot=true:NoSchedule, or the normal pool is labelled spot."
  }
  assert {
    condition     = output.cluster.spot_label == { spot = "true" } && output.cluster.spot_taint == { key = "spot", value = "true", effect = "NO_SCHEDULE" }
    error_message = "The module does not give the build pool's label and taint."
  }
  assert {
    condition     = google_container_cluster.dev.private_cluster_config[0].enable_private_nodes && !google_container_cluster.dev.private_cluster_config[0].enable_private_endpoint && alltrue([for p in google_container_node_pool.pool : p.network_config[0].enable_private_nodes && p.node_config[0].image_type == "COS_CONTAINERD" && p.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"])
    error_message = "The nodes have external addresses or do not run Container-Optimized OS, pods see the node's metadata, or the control plane is not public (Jody, 2026-11-04: it stays public)."
  }
  assert {
    condition     = google_dns_managed_zone.dev.dns_name == "dev.tacplus.dev." && google_dns_managed_zone.dev.dnssec_config[0].state == "on"
    error_message = "The dev zone is not dev.tacplus.dev with DNSSEC."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.cluster.attribute_condition == "assertion.project_path == 'tacplus-dev/cluster' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'" && google_iam_workload_identity_pool_provider.cluster.oidc[0].issuer_uri == "https://gitlab.com"
    error_message = "The cluster pipeline's provider admits more than tacplus-dev/cluster's protected main."
  }
  assert {
    condition     = google_service_account_iam_member.cluster_pipeline_wif.member == "principalSet://iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cluster" && google_service_account_iam_member.cluster_pipeline_wif.role == "roles/iam.workloadIdentityUser"
    error_message = "cluster-admin-pipeline is not tacplus-dev/cluster's alone."
  }
  assert {
    condition     = google_project_iam_member.cluster_pipeline.role == "roles/container.clusterViewer"
    error_message = "cluster-admin-pipeline holds more in GCP than getting the cluster's credentials."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.deploy["seatrials"].attribute_condition == "assertion.project_path == 'tacplus-dev/fleet-seatrials' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'" && google_iam_workload_identity_pool_provider.deploy["seatrials"].oidc[0].issuer_uri == "https://gitlab.com"
    error_message = "The seatrials pipeline's provider admits more than tacplus-dev/fleet-seatrials's protected main."
  }
  assert {
    condition     = google_service_account.deploy["seatrials"].account_id == "seatrials-deploy" && google_service_account_iam_member.deploy_wif["seatrials"].member == "principalSet://iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/fleet-seatrials"
    error_message = "seatrials-deploy is not tacplus-dev/fleet-seatrials's alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret.certificate)) == toset(["tls-seatrials", "acme-account-seatrials"]) && alltrue([for s in google_secret_manager_secret.certificate : s.replication[0].user_managed[0].replicas[0].location == "us-central1"])
    error_message = "The deployment's secrets are not tls-seatrials and acme-account-seatrials, in us-central1."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.certificate)) == toset(["tls-seatrials/roles/secretmanager.secretVersionAdder", "tls-seatrials/roles/secretmanager.secretAccessor", "acme-account-seatrials/roles/secretmanager.secretVersionAdder", "acme-account-seatrials/roles/secretmanager.secretAccessor"])
    error_message = "The secrets' roles are not exactly adding versions and reading them."
  }
  assert {
    condition     = alltrue([for b in google_secret_manager_secret_iam_binding.certificate : b.members == toset([google_service_account.deploy["seatrials"].member])])
    error_message = "Someone besides the seatrials pipeline adds or reads its certificate secrets."
  }
  assert {
    condition     = google_dns_managed_zone.acme_challenge["seatrials"].name == "acme-challenge-tacplus-dev" && google_dns_managed_zone.acme_challenge["seatrials"].dns_name == "_acme-challenge.tacplus.dev." && google_dns_managed_zone.acme_challenge["seatrials"].dnssec_config[0].state == "on"
    error_message = "The challenge zone is not acme-challenge-tacplus-dev for _acme-challenge.tacplus.dev, with DNSSEC."
  }
  assert {
    condition     = google_dns_managed_zone_iam_binding.acme_challenge["seatrials"].role == "roles/dns.admin" && google_dns_managed_zone_iam_binding.acme_challenge["seatrials"].members == toset([google_service_account.deploy["seatrials"].member])
    error_message = "Someone besides the seatrials pipeline administers its challenge zone, or the pipeline does not."
  }
  assert {
    condition     = google_compute_global_address.gateway.name == "gateway" && google_compute_global_address.gateway.address_type == "EXTERNAL" && google_compute_global_address.gateway.ip_version == "IPV4"
    error_message = "The gateway's address is not the global external IPv4 address gateway."
  }
  assert {
    condition     = google_dns_managed_zone.zone.name == "tacplus-dev" && google_dns_managed_zone.zone.dns_name == "tacplus.dev." && google_dns_managed_zone.zone.dnssec_config[0].state == "on"
    error_message = "The domain's zone is not tacplus-dev for tacplus.dev, with DNSSEC."
  }
  assert {
    condition     = toset(keys(google_dns_record_set.gateway)) == toset(["seatrials.tacplus.dev.", "idp.test.tacplus.dev."]) && alltrue([for r in google_dns_record_set.gateway : r.type == "A" && r.ttl == 300 && r.rrdatas == tolist([google_compute_global_address.gateway.address]) && r.managed_zone == "tacplus-dev"])
    error_message = "The deployment's hostnames are not A records of the zone to the gateway's address."
  }
  assert {
    condition     = toset(keys(google_dns_record_set.copied)) == toset(["tacplus.dev. A", "www.tacplus.dev. CNAME"]) && google_dns_record_set.copied["www.tacplus.dev. CNAME"].rrdatas == tolist(["tacplus-dev.github.io."]) && google_dns_record_set.copied["tacplus.dev. A"].ttl == 3600
    error_message = "The zone does not hold the copied records as they are."
  }
  assert {
    condition     = toset(keys(google_dns_record_set.delegation)) == toset(["dev.tacplus.dev.", "_acme-challenge.tacplus.dev."]) && google_dns_record_set.delegation["dev.tacplus.dev."].rrdatas == google_dns_managed_zone.dev.name_servers && google_dns_record_set.delegation["_acme-challenge.tacplus.dev."].rrdatas == google_dns_managed_zone.acme_challenge["seatrials"].name_servers && alltrue([for r in google_dns_record_set.delegation : r.type == "NS" && r.managed_zone == "tacplus-dev"])
    error_message = "The zone does not delegate dev.tacplus.dev and _acme-challenge.tacplus.dev to their zones' name servers."
  }
  assert {
    condition     = output.zone.name_servers == google_dns_managed_zone.zone.name_servers && output.gateway_address.address == google_compute_global_address.gateway.address
    error_message = "The module does not give the zone's name servers, the registrar's values, and the gateway's address."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret.runner_token)) == toset(["gitlab-runner-build", "gitlab-runner-control"]) && alltrue([for s in google_secret_manager_secret.runner_token : s.replication[0].user_managed[0].replicas[0].location == "us-central1" && length(s.replication[0].user_managed[0].replicas) == 1])
    error_message = "The runners' token secrets are not gitlab-runner-build and gitlab-runner-control, in us-central1 alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.runner_token)) == toset(["gitlab-runner-build/roles/secretmanager.secretAccessor", "gitlab-runner-build/roles/secretmanager.secretVersionAdder", "gitlab-runner-control/roles/secretmanager.secretAccessor", "gitlab-runner-control/roles/secretmanager.secretVersionAdder"]) && alltrue([for k, b in google_secret_manager_secret_iam_binding.runner_token : b.secret_id == split("/", k)[0] && b.role == trimprefix(k, "${split("/", k)[0]}/")])
    error_message = "Each runner token secret does not have exactly two bindings: reading its versions and adding them."
  }
  assert {
    condition     = alltrue([for k, b in google_secret_manager_secret_iam_binding.runner_token : b.members == (endswith(k, "secretAccessor") ? toset([google_service_account.cluster_pipeline.member]) : toset(["user:jody@example.com"]))])
    error_message = "Someone besides cluster-admin-pipeline reads the runners' tokens, or someone besides the listed adders adds their versions."
  }
  assert {
    condition     = kubernetes_cluster_role_binding_v1.cluster_pipeline.metadata[0].name == "cluster-admin-pipeline" && kubernetes_cluster_role_binding_v1.cluster_pipeline.role_ref[0].api_group == "rbac.authorization.k8s.io" && kubernetes_cluster_role_binding_v1.cluster_pipeline.role_ref[0].kind == "ClusterRole" && kubernetes_cluster_role_binding_v1.cluster_pipeline.role_ref[0].name == "cluster-admin"
    error_message = "The cluster pipeline's binding is not cluster-admin-pipeline, of the ClusterRole cluster-admin."
  }
  assert {
    condition     = length(kubernetes_cluster_role_binding_v1.cluster_pipeline.subject) == 1 && kubernetes_cluster_role_binding_v1.cluster_pipeline.subject[0].kind == "User" && kubernetes_cluster_role_binding_v1.cluster_pipeline.subject[0].name == "cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com" && kubernetes_cluster_role_binding_v1.cluster_pipeline.subject[0].api_group == "rbac.authorization.k8s.io"
    error_message = "The cluster-admin binding names more than the User cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com."
  }
  assert {
    condition     = alltrue([for m in concat(values(google_project_iam_member.nodes), [google_project_iam_member.cluster_pipeline]) : !contains(["roles/container.admin", "roles/owner"], m.role)])
    error_message = "A service account in dev holds container.admin or owner in IAM: cluster-admin is the binding's, in the cluster."
  }
  assert {
    condition     = output.runner_tokens == { build = "projects/tacplus-dev/secrets/gitlab-runner-build", control = "projects/tacplus-dev/secrets/gitlab-runner-control" } && output.cluster_api.host == "https://${google_container_cluster.dev.endpoint}"
    error_message = "The module does not give the runners' token secrets, or the cluster's API for the kubernetes provider."
  }
  # The public entry (#21): a TCP proxy per listener, on the address gateway, to the NEG its listener names.
  assert {
    condition     = toset(keys(google_compute_global_forwarding_rule.lb)) == toset(["gateway", "test-idp"]) && alltrue([for k, r in google_compute_global_forwarding_rule.lb : r.load_balancing_scheme == "EXTERNAL_MANAGED" && r.ip_protocol == "TCP" && r.ip_address == google_compute_global_address.gateway.id && r.target == google_compute_target_tcp_proxy.lb[k].id])
    error_message = "The forwarding rules are not the gateway's and the test IdP's, global external proxy (EXTERNAL_MANAGED, TCP) on the address gateway, each to its TCP proxy."
  }
  assert {
    condition     = google_compute_global_forwarding_rule.lb["gateway"].port_range == "443" && google_compute_global_forwarding_rule.lb["test-idp"].port_range == "8443"
    error_message = "The gateway is not on 443 and the test IdP on 8443 of the address."
  }
  assert {
    condition     = alltrue([for k, p in google_compute_target_tcp_proxy.lb : p.backend_service == google_compute_backend_service.lb[k].id && p.proxy_header == "NONE"])
    error_message = "A TCP proxy does not pass its connections, as they are, to its listener's backend service."
  }
  assert {
    condition     = alltrue([for k, b in google_compute_backend_service.lb : b.protocol == "TCP" && b.load_balancing_scheme == "EXTERNAL_MANAGED" && b.health_checks == toset([google_compute_health_check.lb[k].id])])
    error_message = "A backend service is not TCP, EXTERNAL_MANAGED, with its listener's health check."
  }
  assert {
    condition     = length(google_compute_backend_service.lb["gateway"].backend) == 1 && one(google_compute_backend_service.lb["gateway"].backend[*].group) == "projects/tacplus-dev/zones/us-central1-a/networkEndpointGroups/seatrials-gateway" && one(google_compute_backend_service.lb["gateway"].backend[*].balancing_mode) == "CONNECTION"
    error_message = "The gateway's backend is not the zonal NEG seatrials-gateway in the cluster's zone, balanced by connection."
  }
  assert {
    condition     = length(google_compute_backend_service.lb["test-idp"].backend) == 0
    error_message = "The test IdP's backend service names a NEG that does not exist yet (ready = false)."
  }
  assert {
    condition     = alltrue([for h in google_compute_health_check.lb : h.tcp_health_check[0].port == 8443 && length(h.http_health_check) == 0 && length(h.https_health_check) == 0 && length(h.ssl_health_check) == 0])
    error_message = "The health checks are not TCP on the endpoints' port, 8443."
  }
  # The nodes' one ingress allow rule: Google's proxies and health checkers, on the endpoints' port, nothing else.
  assert {
    condition     = google_compute_firewall.lb[0].direction == "INGRESS" && google_compute_firewall.lb[0].source_ranges == toset(["35.191.0.0/16", "130.211.0.0/22"]) && length(coalesce(google_compute_firewall.lb[0].source_tags, [])) == 0 && length(coalesce(google_compute_firewall.lb[0].source_service_accounts, [])) == 0
    error_message = "The load balancer's firewall rule admits more than Google's proxy and health-check ranges (35.191.0.0/16, 130.211.0.0/22)."
  }
  assert {
    condition     = length(google_compute_firewall.lb[0].allow) == 1 && one(google_compute_firewall.lb[0].allow[*].protocol) == "tcp" && one(google_compute_firewall.lb[0].allow[*].ports) == tolist(["8443"]) && length(google_compute_firewall.lb[0].deny) == 0
    error_message = "The load balancer's firewall rule allows more than tcp:8443, the endpoints' port."
  }
  assert {
    condition     = google_compute_firewall.lb[0].target_service_accounts == toset([google_service_account.nodes.email]) && google_compute_firewall.lb[0].network == google_compute_network.dev.id
    error_message = "The load balancer's firewall rule is not the dev network's, to the nodes."
  }
}

run "shared_port_refused" {
  # Two listeners on one port of the address: a TCP proxy does not route by SNI.
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    load_balancer = {
      gateway  = { port = 443, neg = "seatrials-gateway", endpoint_port = 8443, ready = false }
      test-idp = { port = 443, neg = "seatrials-test-idp", endpoint_port = 8443, ready = false }
    }
  }
  expect_failures = [var.load_balancer]
}

run "x86_nodes_refused" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "e2-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.cluster]
}

run "empty_normal_pool_refused" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 0 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.cluster]
}

run "shared_environment_refused" {
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    # Two pipelines would share one ACME account and one challenge zone.
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
      other     = { gitlab_project = "tacplus-dev/fleet-dev", environment = "seatrials", domain = "tacplus.dev", hostnames = [], account_id = "other-deploy", wif_provider = "tacplus-dev-fleet-dev" }
    }
  }
  expect_failures = [var.deployments]
}

run "hostname_outside_zone_refused" {
  # A hostname the zone cannot hold.
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.example.com"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [google_dns_managed_zone.zone]
}

run "copied_record_at_hostname_refused" {
  # A copied record where the gateway's A record goes.
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "seatrials.tacplus.dev.", type = "A", ttl = 600, rrdatas = ["146.148.80.132"] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [google_dns_managed_zone.zone]
}

run "copied_apex_ns_refused" {
  # The zone's own name servers are Cloud DNS's, never copied.
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
        { name = "tacplus.dev.", type = "NS", ttl = 21600, rrdatas = ["ns-cloud-a1.googledomains.com."] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.zone]
}


run "runner_token_adder_refused" {
  # An adder that is not a member: user:, group: or serviceAccount: and an address.
  command = plan
  module {
    source = "../../modules/projects/dev"
  }
  variables {
    project_id      = "tacplus-dev"
    name            = "tacplus dev"
    folder          = "folders/444"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    cluster = {
      name            = "dev"
      zone            = "us-central1-a"
      release_channel = "REGULAR"
      disk_gb         = 100
      normal          = { machine_type = "c4a-standard-2", nodes = 3 }
      spot            = { machine_type = "c4a-standard-4", max_nodes = 3 }
    }
    network = {
      nodes         = "10.20.0.0/20"
      pods          = "10.24.0.0/14"
      services      = "10.28.0.0/20"
      control_plane = "172.16.0.0/28"
    }
    dns = { zone = "dev-tacplus-dev", domain = "dev.tacplus.dev." }
    zone = {
      zone   = "tacplus-dev"
      domain = "tacplus.dev."
      records = [
        { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153"] },
      ]
    }
    cluster_pipeline = {
      account_id     = "cluster-admin-pipeline"
      gitlab_project = "tacplus-dev/cluster"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-cluster"
    }
    runner_token_adders = ["jody@example.com"]
  }
  expect_failures = [var.runner_token_adders]
}
