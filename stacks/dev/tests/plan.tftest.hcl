# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The dev stack's plan under a stub parent folder, with an empty project (mock providers: no credentials, no
# cloud): the stack plans, and its module, with the stack's inputs, gives the arm64 cluster (private COS nodes: a normal
# pool of 3 x c4a-standard-2 on demand, a spot build pool of c4a-standard-4 from 0 to 3, labelled and tainted
# spot=true, #7, over the region's zones with c4a, #85, and a looper pool of c4a-standard-2 on demand from 0 to 4 (#107) in the
# cluster's zone, labelled and tainted looper=true, #95), the dev zone and the
# cluster pipeline's identity, federated from tacplus-dev/cluster's protected main alone, and each deployment's
# certificate secrets and _acme-challenge zone, which only its pipeline's identity reads and writes (#6), and the
# gateway's one global address, kept from destruction (ci/policy.sh checks prevent_destroy and that no other external
# address is in a plan), and tacplus.dev's zone: its copied records, the deployment's hostnames to that address, the
# delegations, and its name servers for the registrar (#13), and the runners' token secrets, which the cluster pipeline
# reads and only the listed people add versions to, and the cluster pipeline's cluster-admin, a ClusterRoleBinding
# made in the cluster through the kubernetes provider, with no service account of dev holding container.admin, owner or
# editor in IAM (#18, #78), and the public entry (#21): a global external proxy Network Load Balancer (TCP proxy) on the address
# gateway, one forwarding rule per listener, to the NEGs the settings name, a TCP health check on their endpoints'
# port, no TLS on Google's side, and the nodes open to Google's proxies and health checkers only, on that port, and
# (#20) the deployment's get-credentials on the cluster dev alone, its Cloud Build roles, the builds' own account, its
# deploy registry (the builds write it, the deployment and the nodes read it) and build bucket (7 days), and its test
# IdP's account, which only its project's jobs in the environment test-idp become, with no role but get-credentials,
# and (#28) its fleet secrets fleet-ca-<deployment> and fleet-crypto-<deployment>, and (#105) its root credential's
# key fleet-root-cred-<deployment>, whose versions only its init-secrets job's account adds (only its project's jobs
# in the environment init-secrets become it) and only its identity reads, and (#37) its Google sign-in client's secret
# google-signin-<deployment>, made with no version, whose versions only the listed people add (Jody, in the Console:
# Google has no API for a web client) and only its identity reads, and (#84) the Admiral's provider, for its fleet kernel's issuer and its SPIFFE ID alone, and (#88) the Cloud
# Quotas preferences of the C4A CPUs and the Hyperdisk Balanced GB its pools need, computed from them.
# (A test sees a module's resources only when it runs that module itself.)

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
  # us-central1's zones, each offering every machine type (a run overrides a zone without).
  mock_data "google_compute_zones" {
    defaults = { names = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"] }
  }
  mock_data "google_compute_machine_types" {
    defaults = { machine_types = [{ name = "c4a-standard-4", accelerators = [], architecture = "ARM64", deprecated = [], description = "4 vCPUs, 16 GB RAM", guest_cpus = 4, is_shared_cpus = false, maximum_persistent_disks = 128, maximum_persistent_disks_size_gb = 263168, memory_mb = 16384, self_link = "https://www.googleapis.com/compute/v1/projects/tacplus-dev/zones/us-central1-a/machineTypes/c4a-standard-4" }] }
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

# The quota preferences' (#90): its calls count against the dev project (tests/quotas_plan_test.sh plans them with it).
mock_provider "google" {
  alias = "quotas"
}

mock_provider "kubernetes" {}

# The parent folder, as the pipeline gives it (GCP_PARENT_FOLDER).
variables {
  parent_folder = "111111111111"
  # As GCP_RUNNER_TOKEN_ADDERS gives it: an account of the host's directory, which no file here names.
  runner_token_adders = ["user:jody@example.com"]
  # As GCP_GOOGLE_SIGNIN_ADDERS gives it, alike.
  google_signin_adders = ["user:jody@example.com"]
  # As GCP_QUOTA_CONTACT gives it (#88): the account Google asks about a quota increase.
  quota_contact = "jody@example.com"
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
  # fleet-seatrials#39's names (#20).
  assert {
    condition     = output.deployments["seatrials"].registry == "us-central1-docker.pkg.dev/tacplus-dev/seatrials" && output.deployments["seatrials"].build.bucket == "gs://tacplus-dev-seatrials-build" && keys(output.deployments["seatrials"].environment_accounts) == ["test-idp"]
    error_message = "The stack does not give seatrials its registry, its build bucket and the test IdP's account."
  }
  # tacplus-dev/cluster's gitlab-runner/pin.yaml names it (#45).
  assert {
    condition     = output.cluster_pipeline.registry == "us-central1-docker.pkg.dev/tacplus-dev/ci-images"
    error_message = "The stack does not give the cluster pipeline its registry us-central1-docker.pkg.dev/tacplus-dev/ci-images."
  }
  # fleet-seatrials#44's names (#28), and fleet-seatrials#77's (#105).
  assert {
    condition     = output.deployments["seatrials"].fleet_secrets.ca == "projects/tacplus-dev/secrets/fleet-ca-seatrials" && output.deployments["seatrials"].fleet_secrets.crypto == "projects/tacplus-dev/secrets/fleet-crypto-seatrials" && output.deployments["seatrials"].fleet_secrets.root_cred == "projects/tacplus-dev/secrets/fleet-root-cred-seatrials" && output.deployments["seatrials"].fleet_secrets.environment == "init-secrets"
    error_message = "The stack does not give seatrials its fleet secrets and the init-secrets job's account."
  }
  # fleet-seatrials#27's names (#32).
  assert {
    condition     = output.deployments["seatrials"].environment_certificates["test-idp"].secrets == { tls = "projects/tacplus-dev/secrets/tls-test-idp", acme_account = "projects/tacplus-dev/secrets/acme-account-test-idp" } && output.deployments["seatrials"].environment_certificates["test-idp"].challenge_zone == "acme-challenge-idp-test-tacplus-dev" && output.deployments["seatrials"].environment_secrets == { test-idp = ["projects/tacplus-dev/secrets/test-idp-seeds"] }
    error_message = "The stack does not give the test IdP its certificate secrets, its challenge zone and its seed secret."
  }
  # fleet-seatrials#46's name (#37).
  assert {
    condition     = output.deployments["seatrials"].google_signin == "projects/tacplus-dev/secrets/google-signin-seatrials"
    error_message = "The stack does not give seatrials its Google sign-in client's secret."
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
    condition     = output.runner_tokens == { build = "projects/tacplus-dev/secrets/gitlab-runner-build", control = "projects/tacplus-dev/secrets/gitlab-runner-control", infra = "projects/tacplus-dev/secrets/gitlab-runner-infra", kick = "projects/tacplus-dev/secrets/gitlab-runner-kick", build-report = "projects/tacplus-dev/secrets/gitlab-runner-build-report", build-light = "projects/tacplus-dev/secrets/gitlab-runner-build-light", manager = "projects/tacplus-dev/secrets/gitlab-runner-manager" }
    error_message = "The stack does not give the seven runners' token secrets, tacplus-dev/cluster's tacplus.token (infra's: #64; kick's: #81; build-report's: #93; build-light's: #100; manager's: #106)."
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
  # The Admiral's provider (#84), the settings' admiral: the ci stack names it from the dev project's number.
  assert {
    condition     = output.admiral.wif_provider == "projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials" && output.admiral.audience == "//iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials"
    error_message = "The stack does not give the Admiral's provider seatrials of the pool fleet-kernels."
  }
  # The quotas the pools need (#88), from the stack's pools: 3 normal c4a-standard-2 (6 CPUs), the build pool's 8
  # (#96) c4a-standard-4 (32), the looper pool's 4 (#107) c4a-standard-2 (8, #95) and one more for a node being replaced (4):
  # 50 C4A CPUs, asked 56; and 16 nodes of 100 GB of Hyperdisk Balanced, 1600 GB, asked 2000.
  assert {
    condition     = output.quotas.c4a_cpus.need == 50 && output.quotas.c4a_cpus.preferred == 56 && output.quotas.hdb_gb.need == 1600 && output.quotas.hdb_gb.preferred == 2000
    error_message = "The stack does not ask 56 C4A CPUs (50 needed) and 2000 GB of Hyperdisk Balanced (1600 needed) for its pools."
  }
  # The looper pool (#95): c4a-standard-2 on demand, from 0 to 4 (#107); its label and taint for the cluster pipeline.
  assert {
    condition     = output.cluster.looper_label == { looper = "true" } && output.cluster.looper_taint == { key = "looper", value = "true", effect = "NO_SCHEDULE" }
    error_message = "The stack does not give the looper pool's label and taint."
  }
  override_resource {
    target = module.dev.google_iam_workload_identity_pool_provider.admiral
    values = { name = "projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials" }
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    deployments = {
      seatrials = {
        gitlab_project           = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        images                   = { registry = "seatrials", bucket = "seatrials-build", account_id = "seatrials-build", days = 7 }
        environment_accounts     = { test-idp = "test-idp-deploy" }
        environment_certificates = { test-idp = "idp.test.tacplus.dev" }
        environment_secrets      = { test-idp = ["test-idp-seeds"] }
        init_secrets             = { environment = "init-secrets", account_id = "seatrials-init-secrets" }
        google_signin            = true
      }
    }
    runner_token_adders  = ["user:jody@example.com"]
    google_signin_adders = ["user:jody@example.com"]
    # Both NEGs made (the test IdP's since its first run, #42).
    load_balancer = {
      gateway  = { port = 443, neg = "seatrials-gateway", endpoint_port = 8443, ready = true }
      test-idp = { port = 8443, neg = "seatrials-test-idp", endpoint_port = 8443, ready = true }
    }
    admiral = { pool = "fleet-kernels", provider = "seatrials", issuer = "https://seatrials.tacplus.dev", subject = "spiffe://tacplus.dev/system/services/admiral" }
    # As the stack gives GCP_QUOTA_CONTACT (#88).
    quota_contact = "jody@example.com"
  }

  # The quotas the pools need (#88), as Cloud Quotas preferences of tacplus-dev in the region, computed from the pools:
  # C4A CPUs for the normal pool (3 x 2), the build pool at its maximum plus one node being replaced (4 x 4) and the
  # looper pool at its maximum (2 x 2, #95), 26, asked 32 (a multiple of 8); Hyperdisk Balanced for each of those
  # nodes' disks (9 x 100 GB), 900, asked 1000 (of 500).
  assert {
    condition     = google_cloud_quotas_quota_preference.pools["c4a_cpus"].parent == "projects/tacplus-dev" && google_cloud_quotas_quota_preference.pools["c4a_cpus"].service == "compute.googleapis.com" && google_cloud_quotas_quota_preference.pools["c4a_cpus"].quota_id == "CPUS-PER-VM-FAMILY-per-project-region" && google_cloud_quotas_quota_preference.pools["c4a_cpus"].dimensions == tomap({ region = "us-central1", vm_family = "C4A" }) && google_cloud_quotas_quota_preference.pools["c4a_cpus"].quota_config[0].preferred_value == "32"
    error_message = "The C4A CPU quota preference is not 32 in us-central1 (the pools' 26 rounded up to 8)."
  }
  assert {
    condition     = google_cloud_quotas_quota_preference.pools["hdb_gb"].parent == "projects/tacplus-dev" && google_cloud_quotas_quota_preference.pools["hdb_gb"].service == "compute.googleapis.com" && google_cloud_quotas_quota_preference.pools["hdb_gb"].quota_id == "HDB-TOTAL-GB-per-project-region" && google_cloud_quotas_quota_preference.pools["hdb_gb"].dimensions == tomap({ region = "us-central1" }) && google_cloud_quotas_quota_preference.pools["hdb_gb"].quota_config[0].preferred_value == "1000"
    error_message = "The Hyperdisk Balanced quota preference is not 1000 GB in us-central1 (the pools' 900 rounded up to 500)."
  }
  assert {
    condition     = alltrue([for q in google_cloud_quotas_quota_preference.pools : q.contact_email == "jody@example.com"]) && output.quotas == { c4a_cpus = { quota_id = "CPUS-PER-VM-FAMILY-per-project-region", dimensions = { region = "us-central1", vm_family = "C4A" }, need = 26, preferred = 32 }, hdb_gb = { quota_id = "HDB-TOTAL-GB-per-project-region", dimensions = { region = "us-central1" }, need = 900, preferred = 1000 } }
    error_message = "The quota preferences do not name the contact, or the module does not give them."
  }
  # The Cloud Quotas API, in the project the preferences are of, which their calls count against (#90: tests/quotas_plan_test.sh).
  assert {
    condition     = contains(keys(google_project_service.service), "cloudquotas.googleapis.com") && contains(terraform_data.iam_ready.input.permissions, "cloudquotas.quotas.update") && contains(terraform_data.iam_ready.input.permissions, "serviceusage.services.use")
    error_message = "The project does not enable the Cloud Quotas API, or the IAM gate does not wait for cloudquotas.quotas.update and serviceusage.services.use."
  }

  # The Admiral's federation (#84): a pool of its own, not the GitLab jobs', whose one provider trusts the seatrials
  # kernel's issuer alone, by discovery, for the Admiral's SPIFFE ID alone.
  assert {
    condition     = google_iam_workload_identity_pool.fleet_kernels[0].workload_identity_pool_id == "fleet-kernels" && google_iam_workload_identity_pool_provider.admiral[0].workload_identity_pool_provider_id == "seatrials" && google_iam_workload_identity_pool_provider.admiral[0].oidc[0].issuer_uri == "https://seatrials.tacplus.dev" && google_iam_workload_identity_pool_provider.admiral[0].oidc[0].jwks_json == null && try(length(google_iam_workload_identity_pool_provider.admiral[0].oidc[0].allowed_audiences), 0) == 0
    error_message = "The Admiral's provider is not seatrials, in the pool fleet-kernels, for the seatrials kernel's issuer by discovery, with the provider's own audience."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.admiral[0].attribute_condition == "assertion.sub == 'spiffe://tacplus.dev/system/services/admiral'" && google_iam_workload_identity_pool_provider.admiral[0].attribute_mapping == tomap({ "google.subject" = "assertion.sub" })
    error_message = "The Admiral's provider admits more than its SPIFFE ID, or maps more than its subject."
  }
  override_resource {
    target = google_iam_workload_identity_pool_provider.admiral
    values = { name = "projects/555/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials" }
  }
  assert {
    condition     = output.admiral == { wif_provider = "projects/555/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials", audience = "//iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials" }
    error_message = "The module does not give the Admiral's provider and its audience."
  }

  # A zone of the region without the build pool's machine type.
  override_data {
    target = data.google_compute_machine_types.spot["us-central1-c"]
    values = { machine_types = [] }
  }
  # Each account its own member, so that a binding's members show whose they are.
  override_resource {
    target = google_service_account.deploy["seatrials"]
    values = { email = "seatrials-deploy@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/seatrials-deploy@tacplus-dev.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_service_account.build["seatrials"]
    values = { email = "seatrials-build@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:seatrials-build@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/seatrials-build@tacplus-dev.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_service_account.environment["seatrials/test-idp"]
    values = { email = "test-idp-deploy@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/test-idp-deploy@tacplus-dev.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_service_account.init_secrets["seatrials"]
    values = { email = "seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_service_account.nodes
    values = { email = "gke-nodes@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:gke-nodes@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/gke-nodes@tacplus-dev.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_service_account.cluster_pipeline
    values = { email = "cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com", member = "serviceAccount:cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com", name = "projects/tacplus-dev/serviceAccounts/cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com" }
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
    condition     = toset(keys(google_container_node_pool.pool)) == toset(["normal", "spot", "looper"]) && google_container_cluster.dev.deletion_protection
    error_message = "The cluster's pools are not normal, spot and looper, or the cluster is not deletion-protected."
  }
  assert {
    condition     = google_container_node_pool.pool["normal"].node_config[0].machine_type == "c4a-standard-2" && google_container_node_pool.pool["normal"].node_count == 3 && length(google_container_node_pool.pool["normal"].autoscaling) == 0 && !google_container_node_pool.pool["normal"].node_config[0].spot && length(google_container_node_pool.pool["normal"].node_config[0].taint) == 0
    error_message = "The normal pool is not 3 x c4a-standard-2, fixed, on demand, untainted."
  }
  # Its maximum is the pool's, in all its zones (#85).
  assert {
    condition     = google_container_node_pool.pool["spot"].node_config[0].machine_type == "c4a-standard-4" && google_container_node_pool.pool["spot"].node_config[0].spot && google_container_node_pool.pool["spot"].autoscaling[0].total_min_node_count == 0 && google_container_node_pool.pool["spot"].autoscaling[0].total_max_node_count == 3 && google_container_node_pool.pool["spot"].autoscaling[0].min_node_count == null && google_container_node_pool.pool["spot"].autoscaling[0].max_node_count == null
    error_message = "The build pool is not c4a-standard-4 spot, from 0 to 3 in all its zones (total, not per zone)."
  }
  # A zone out of spot c4a stalls no build (#85): the pool spreads over the region's zones that offer its machine type
  # (us-central1-c does not, here), and GKE makes each node where there is capacity. The normal pool stays in the
  # cluster's zone.
  assert {
    condition     = toset(google_container_node_pool.pool["spot"].node_locations) == toset(["us-central1-a", "us-central1-b", "us-central1-f"]) && google_container_node_pool.pool["spot"].autoscaling[0].location_policy == "ANY"
    error_message = "The build pool does not spread over the zones of us-central1 with c4a-standard-4 (a, b and f), location policy ANY."
  }
  assert {
    condition     = google_container_node_pool.pool["normal"].location == "us-central1-a" && length(google_container_node_pool.pool["normal"].node_locations) == 0 && google_container_cluster.dev.location == "us-central1-a"
    error_message = "The normal pool or the cluster is not in us-central1-a alone."
  }
  assert {
    condition     = google_container_node_pool.pool["spot"].node_config[0].labels["spot"] == "true" && length(google_container_node_pool.pool["spot"].node_config[0].taint) == 1 && google_container_node_pool.pool["spot"].node_config[0].taint[0].key == "spot" && google_container_node_pool.pool["spot"].node_config[0].taint[0].value == "true" && google_container_node_pool.pool["spot"].node_config[0].taint[0].effect == "NO_SCHEDULE" && !contains(keys(google_container_node_pool.pool["normal"].node_config[0].labels), "spot")
    error_message = "The build pool is not labelled spot=true and tainted spot=true:NoSchedule, or the normal pool is labelled spot."
  }
  assert {
    condition     = output.cluster.spot_label == { spot = "true" } && output.cluster.spot_taint == { key = "spot", value = "true", effect = "NO_SCHEDULE" }
    error_message = "The module does not give the build pool's label and taint."
  }
  # The looper runs' overflow (#95): on demand (a looper run lasts hours; spot would preempt it), from 0 to 2 in the
  # cluster's zone, labelled and tainted looper=true so that only the control runner's job pods land there and it
  # empties back to 0 (tacplus-dev/cluster#47).
  assert {
    condition     = google_container_node_pool.pool["looper"].node_config[0].machine_type == "c4a-standard-2" && !google_container_node_pool.pool["looper"].node_config[0].spot && google_container_node_pool.pool["looper"].autoscaling[0].total_min_node_count == 0 && google_container_node_pool.pool["looper"].autoscaling[0].total_max_node_count == 2 && google_container_node_pool.pool["looper"].autoscaling[0].min_node_count == null && google_container_node_pool.pool["looper"].autoscaling[0].max_node_count == null
    error_message = "The looper pool is not c4a-standard-2 on demand, from 0 to 2."
  }
  assert {
    condition     = google_container_node_pool.pool["looper"].location == "us-central1-a" && length(google_container_node_pool.pool["looper"].node_locations) == 0 && google_container_node_pool.pool["looper"].node_config[0].disk_type == "hyperdisk-balanced" && google_container_node_pool.pool["looper"].node_config[0].disk_size_gb == 100
    error_message = "The looper pool is not in us-central1-a alone, on a 100 GB Hyperdisk Balanced disk a node."
  }
  assert {
    condition     = google_container_node_pool.pool["looper"].node_config[0].labels["looper"] == "true" && length(google_container_node_pool.pool["looper"].node_config[0].taint) == 1 && google_container_node_pool.pool["looper"].node_config[0].taint[0].key == "looper" && google_container_node_pool.pool["looper"].node_config[0].taint[0].value == "true" && google_container_node_pool.pool["looper"].node_config[0].taint[0].effect == "NO_SCHEDULE" && !contains(keys(google_container_node_pool.pool["normal"].node_config[0].labels), "looper") && !contains(keys(google_container_node_pool.pool["spot"].node_config[0].labels), "looper")
    error_message = "The looper pool is not labelled looper=true and tainted looper=true:NoSchedule, or another pool is labelled looper."
  }
  assert {
    condition     = output.cluster.looper_label == { looper = "true" } && output.cluster.looper_taint == { key = "looper", value = "true", effect = "NO_SCHEDULE" }
    error_message = "The module does not give the looper pool's label and taint."
  }
  assert {
    condition     = google_container_cluster.dev.private_cluster_config[0].enable_private_nodes && alltrue([for p in google_container_node_pool.pool : p.network_config[0].enable_private_nodes && p.node_config[0].image_type == "COS_CONTAINERD" && p.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"])
    error_message = "The nodes have external addresses or do not run Container-Optimized OS, or pods see the node's metadata."
  }
  # Only load balancers are public (Jody, 2026-11-18, #79): the control plane has no public endpoint, and its private one
  # admits the cluster's own nodes and pods alone, where the cloud, cluster and deploy pipelines run (the runner infra).
  assert {
    condition     = google_container_cluster.dev.private_cluster_config[0].enable_private_endpoint && length(google_container_cluster.dev.master_authorized_networks_config) == 1 && !google_container_cluster.dev.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled && google_container_cluster.dev.master_authorized_networks_config[0].private_endpoint_enforcement_enabled && toset([for b in google_container_cluster.dev.master_authorized_networks_config[0].cidr_blocks : b.cidr_block]) == toset(["10.20.0.0/20", "10.24.0.0/14"])
    error_message = "The control plane has a public endpoint, or admits more than the cluster's nodes (10.20.0.0/20) and pods (10.24.0.0/14)."
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
    condition     = toset(keys(google_secret_manager_secret.certificate)) == toset(["tls-seatrials", "acme-account-seatrials", "tls-test-idp", "acme-account-test-idp"]) && alltrue([for s in google_secret_manager_secret.certificate : s.replication[0].user_managed[0].replicas[0].location == "us-central1"])
    error_message = "The certificate secrets are not the deployment's tls-seatrials and acme-account-seatrials and the test IdP's tls-test-idp and acme-account-test-idp, in us-central1."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.certificate)) == toset(flatten([for s in ["tls-seatrials", "acme-account-seatrials", "tls-test-idp", "acme-account-test-idp"] : [for r in ["secretVersionAdder", "secretAccessor", "viewer"] : "${s}/roles/secretmanager.${r}"]]))
    error_message = "The secrets' roles are not exactly adding versions, reading them and listing them (#68: the cert job lists the versions)."
  }
  assert {
    condition     = alltrue([for k, b in google_secret_manager_secret_iam_binding.certificate : b.members == toset([endswith(split("/", k)[0], "-test-idp") ? google_service_account.environment["seatrials/test-idp"].member : google_service_account.deploy["seatrials"].member])])
    error_message = "Someone besides the seatrials pipeline adds or reads its certificate secrets, or besides test-idp-deploy the test IdP's."
  }
  assert {
    condition     = google_dns_managed_zone.acme_challenge["seatrials"].name == "acme-challenge-tacplus-dev" && google_dns_managed_zone.acme_challenge["seatrials"].dns_name == "_acme-challenge.tacplus.dev." && google_dns_managed_zone.acme_challenge["seatrials"].dnssec_config[0].state == "on"
    error_message = "The challenge zone is not acme-challenge-tacplus-dev for _acme-challenge.tacplus.dev, with DNSSEC."
  }
  assert {
    condition     = google_dns_managed_zone_iam_binding.acme_challenge["seatrials"].role == "roles/dns.admin" && google_dns_managed_zone_iam_binding.acme_challenge["seatrials"].members == toset([google_service_account.deploy["seatrials"].member])
    error_message = "Someone besides the seatrials pipeline administers its challenge zone, or the pipeline does not."
  }
  # The test IdP's certificate (#32, fleet-seatrials#27): idp.test.tacplus.dev, which *.tacplus.dev does not cover, by
  # its own job's DNS-01, in a zone of its own that test-idp-deploy alone administers.
  assert {
    condition     = google_dns_managed_zone.acme_challenge["seatrials/test-idp"].name == "acme-challenge-idp-test-tacplus-dev" && google_dns_managed_zone.acme_challenge["seatrials/test-idp"].dns_name == "_acme-challenge.idp.test.tacplus.dev." && google_dns_managed_zone.acme_challenge["seatrials/test-idp"].dnssec_config[0].state == "on"
    error_message = "The test IdP's challenge zone is not acme-challenge-idp-test-tacplus-dev for _acme-challenge.idp.test.tacplus.dev, with DNSSEC."
  }
  assert {
    condition     = google_dns_managed_zone_iam_binding.acme_challenge["seatrials/test-idp"].role == "roles/dns.admin" && google_dns_managed_zone_iam_binding.acme_challenge["seatrials/test-idp"].members == toset(["serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com"])
    error_message = "Someone besides test-idp-deploy administers the test IdP's challenge zone, or it does not."
  }
  # The test IdP's seeds (#32): in Secret Manager, not GitLab (gitlab.com Free has no project access tokens, as #28).
  assert {
    condition     = toset(keys(google_secret_manager_secret.environment)) == toset(["test-idp-seeds"]) && google_secret_manager_secret.environment["test-idp-seeds"].replication[0].user_managed[0].replicas[0].location == "us-central1" && length(google_secret_manager_secret.environment["test-idp-seeds"].replication[0].user_managed[0].replicas) == 1
    error_message = "The test IdP's seed secret is not test-idp-seeds, in us-central1 alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.environment)) == toset([for r in ["secretVersionAdder", "secretAccessor", "viewer"] : "test-idp-seeds/roles/secretmanager.${r}"]) && alltrue([for k, b in google_secret_manager_secret_iam_binding.environment : b.secret_id == "test-idp-seeds" && b.role == trimprefix(k, "test-idp-seeds/")])
    error_message = "The test IdP's seeds' roles are not exactly adding versions, reading them and listing them."
  }
  # #68: seatrials' own jobs read the seeds too (fleet-seatrials' ci_test_idp_seeds); #73: and add them, its test-idp
  # job storing them on the test IdP's first run.
  assert {
    condition     = alltrue([for r in ["secretVersionAdder", "secretAccessor", "viewer"] : google_secret_manager_secret_iam_binding.environment["test-idp-seeds/roles/secretmanager.${r}"].members == toset(["serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com", "serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"])])
    error_message = "Someone besides test-idp-deploy and seatrials-deploy adds, reads or lists the test IdP's seeds, or either does not."
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
    condition     = toset(keys(google_dns_record_set.delegation)) == toset(["dev.tacplus.dev.", "_acme-challenge.tacplus.dev.", "_acme-challenge.idp.test.tacplus.dev."]) && google_dns_record_set.delegation["dev.tacplus.dev."].rrdatas == google_dns_managed_zone.dev.name_servers && google_dns_record_set.delegation["_acme-challenge.tacplus.dev."].rrdatas == google_dns_managed_zone.acme_challenge["seatrials"].name_servers && google_dns_record_set.delegation["_acme-challenge.idp.test.tacplus.dev."].rrdatas == google_dns_managed_zone.acme_challenge["seatrials/test-idp"].name_servers && alltrue([for r in google_dns_record_set.delegation : r.type == "NS" && r.managed_zone == "tacplus-dev"])
    error_message = "The zone does not delegate dev.tacplus.dev, _acme-challenge.tacplus.dev and _acme-challenge.idp.test.tacplus.dev to their zones' name servers."
  }
  assert {
    condition     = output.zone.name_servers == google_dns_managed_zone.zone.name_servers && output.gateway_address.address == google_compute_global_address.gateway.address
    error_message = "The module does not give the zone's name servers, the registrar's values, and the gateway's address."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret.runner_token)) == toset(["gitlab-runner-build", "gitlab-runner-control", "gitlab-runner-infra", "gitlab-runner-kick", "gitlab-runner-build-report", "gitlab-runner-build-light", "gitlab-runner-manager"]) && alltrue([for s in google_secret_manager_secret.runner_token : s.replication[0].user_managed[0].replicas[0].location == "us-central1" && length(s.replication[0].user_managed[0].replicas) == 1])
    error_message = "The runners' token secrets are not gitlab-runner-build, gitlab-runner-control, gitlab-runner-infra (#64), gitlab-runner-kick (#81), gitlab-runner-build-report (#93), gitlab-runner-build-light (#100) and gitlab-runner-manager (#106), in us-central1 alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.runner_token)) == toset(["gitlab-runner-build/roles/secretmanager.secretAccessor", "gitlab-runner-build/roles/secretmanager.secretVersionAdder", "gitlab-runner-control/roles/secretmanager.secretAccessor", "gitlab-runner-control/roles/secretmanager.secretVersionAdder", "gitlab-runner-infra/roles/secretmanager.secretAccessor", "gitlab-runner-infra/roles/secretmanager.secretVersionAdder", "gitlab-runner-kick/roles/secretmanager.secretAccessor", "gitlab-runner-kick/roles/secretmanager.secretVersionAdder", "gitlab-runner-build-report/roles/secretmanager.secretAccessor", "gitlab-runner-build-report/roles/secretmanager.secretVersionAdder", "gitlab-runner-build-light/roles/secretmanager.secretAccessor", "gitlab-runner-build-light/roles/secretmanager.secretVersionAdder", "gitlab-runner-manager/roles/secretmanager.secretAccessor", "gitlab-runner-manager/roles/secretmanager.secretVersionAdder"]) && alltrue([for k, b in google_secret_manager_secret_iam_binding.runner_token : b.secret_id == split("/", k)[0] && b.role == trimprefix(k, "${split("/", k)[0]}/")])
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
    condition     = alltrue([for m in concat(values(google_project_iam_member.nodes), [google_project_iam_member.cluster_pipeline], values(google_project_iam_member.deploy), values(google_project_iam_member.build), values(google_project_iam_member.cluster_viewer)) : !contains(["roles/container.admin", "roles/owner", "roles/editor"], m.role)])
    error_message = "A service account in dev holds container.admin, owner or editor in IAM: cluster-admin is the binding's, in the cluster."
  }
  assert {
    condition     = output.runner_tokens == { build = "projects/tacplus-dev/secrets/gitlab-runner-build", control = "projects/tacplus-dev/secrets/gitlab-runner-control", infra = "projects/tacplus-dev/secrets/gitlab-runner-infra", kick = "projects/tacplus-dev/secrets/gitlab-runner-kick", build-report = "projects/tacplus-dev/secrets/gitlab-runner-build-report", build-light = "projects/tacplus-dev/secrets/gitlab-runner-build-light", manager = "projects/tacplus-dev/secrets/gitlab-runner-manager" } && output.cluster_api.host == "https://${google_container_cluster.dev.endpoint}"
    error_message = "The module does not give the runners' token secrets, or the cluster's API for the kubernetes provider."
  }
  # get-credentials on dev (#20): the deployment's identity and its environment accounts view the cluster dev alone. The
  # condition names it as GKE checks a zonal cluster, projects/<project>/zones/<zone>/clusters/<name>: the locations/
  # form is a regional cluster's, and never matched dev (#71: container.clusters.get 403).
  assert {
    condition     = toset(keys(google_project_iam_member.cluster_viewer)) == toset(["deploy/seatrials", "environment/seatrials/test-idp"]) && alltrue([for m in google_project_iam_member.cluster_viewer : m.role == "roles/container.clusterViewer" && m.condition[0].expression == "resource.name == \"projects/tacplus-dev/zones/us-central1-a/clusters/dev\""])
    error_message = "The deployment's identity and its environment accounts do not view the cluster dev, and it alone (container.clusterViewer, conditioned on its zonal name)."
  }
  assert {
    condition     = google_project_iam_member.cluster_viewer["deploy/seatrials"].member == "serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com" && google_project_iam_member.cluster_viewer["environment/seatrials/test-idp"].member == "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com"
    error_message = "get-credentials on dev is not seatrials-deploy's and test-idp-deploy's."
  }
  # The test IdP's account (#20): its own, only fleet-seatrials' jobs in the environment test-idp on protected main
  # become it, and it holds no role but get-credentials, its certificate's secrets and challenge zone, and its seeds
  # (#32).
  assert {
    condition     = google_service_account.environment["seatrials/test-idp"].account_id == "test-idp-deploy" && google_service_account_iam_member.environment_wif["seatrials/test-idp"].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_member.environment_wif["seatrials/test-idp"].member == "principalSet://iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/gitlab-com/attribute.project_environment/tacplus-dev/fleet-seatrials:test-idp"
    error_message = "test-idp-deploy is not only tacplus-dev/fleet-seatrials' jobs in the environment test-idp."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.deploy["seatrials"].attribute_mapping["attribute.project_environment"] == "assertion.project_path + ':' + (has(assertion.environment) ? assertion.environment : '')" && google_iam_workload_identity_pool_provider.deploy["seatrials"].attribute_mapping["attribute.project_path"] == "assertion.project_path"
    error_message = "The seatrials provider does not map the job's project and environment together (a job without an environment maps to none)."
  }
  assert {
    condition     = alltrue(flatten([for r in [google_project_iam_member.deploy, google_project_iam_member.build, google_project_iam_member.cluster_viewer] : [for m in values(r) : m.member != "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com" || m.role == "roles/container.clusterViewer"]])) && alltrue([for b in concat(values(google_artifact_registry_repository_iam_binding.deploy), values(google_storage_bucket_iam_binding.build), values(google_service_account_iam_binding.build_user)) : !contains(b.members, "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com")])
    error_message = "test-idp-deploy holds a role on the project besides get-credentials on dev, or one on the deployment's registry, bucket or builds' account."
  }
  assert {
    condition     = toset(flatten([for b in concat(values(google_secret_manager_secret_iam_binding.certificate), values(google_secret_manager_secret_iam_binding.environment), values(google_secret_manager_secret_iam_binding.runner_token)) : [for m in b.members : "${b.secret_id} ${b.role}" if m == "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com"]])) == toset(flatten([for s in ["tls-test-idp", "acme-account-test-idp", "test-idp-seeds"] : [for r in ["secretVersionAdder", "secretAccessor", "viewer"] : "${s} roles/secretmanager.${r}"]])) && toset([for b in values(google_dns_managed_zone_iam_binding.acme_challenge) : b.managed_zone if contains(b.members, "serviceAccount:test-idp-deploy@tacplus-dev.iam.gserviceaccount.com")]) == toset(["acme-challenge-idp-test-tacplus-dev"])
    error_message = "test-idp-deploy's secrets are not exactly adding, reading and listing tls-test-idp, acme-account-test-idp and test-idp-seeds, or its zone not exactly acme-challenge-idp-test-tacplus-dev."
  }
  # The deploy registry (#20): Docker, us-central1, seatrials; the builds' account writes it, the deployment's
  # identity and the nodes read it; no cleanup policy, so nothing deployed is deleted.
  assert {
    condition     = google_artifact_registry_repository.deploy["seatrials"].repository_id == "seatrials" && google_artifact_registry_repository.deploy["seatrials"].format == "DOCKER" && google_artifact_registry_repository.deploy["seatrials"].location == "us-central1" && length(google_artifact_registry_repository.deploy["seatrials"].cleanup_policies) == 0
    error_message = "The deploy registry is not the Docker registry seatrials in us-central1, without a cleanup policy."
  }
  assert {
    condition     = toset(keys(google_artifact_registry_repository_iam_binding.deploy)) == toset(["seatrials/roles/artifactregistry.writer", "seatrials/roles/artifactregistry.reader"]) && google_artifact_registry_repository_iam_binding.deploy["seatrials/roles/artifactregistry.writer"].members == toset(["serviceAccount:seatrials-build@tacplus-dev.iam.gserviceaccount.com"]) && google_artifact_registry_repository_iam_binding.deploy["seatrials/roles/artifactregistry.reader"].members == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com", "serviceAccount:gke-nodes@tacplus-dev.iam.gserviceaccount.com"])
    error_message = "The deploy registry is not written by the builds' account alone, and read by seatrials-deploy and the nodes alone."
  }
  # The cluster pipeline's registry (#45, tacplus-dev/cluster#21): Docker, us-central1, ci-images, private;
  # cluster-admin-pipeline alone writes it, the nodes alone read it, and it holds no other registry's role.
  assert {
    condition     = google_artifact_registry_repository.ci_images.repository_id == "ci-images" && google_artifact_registry_repository.ci_images.format == "DOCKER" && google_artifact_registry_repository.ci_images.location == "us-central1" && google_artifact_registry_repository.ci_images.project == "tacplus-dev"
    error_message = "The cluster pipeline's registry is not the Docker registry ci-images in us-central1, in tacplus-dev."
  }
  assert {
    condition     = toset(keys(google_artifact_registry_repository_iam_binding.ci_images)) == toset(["roles/artifactregistry.writer", "roles/artifactregistry.reader"]) && google_artifact_registry_repository_iam_binding.ci_images["roles/artifactregistry.writer"].members == toset(["serviceAccount:cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com"]) && google_artifact_registry_repository_iam_binding.ci_images["roles/artifactregistry.reader"].members == toset(["serviceAccount:gke-nodes@tacplus-dev.iam.gserviceaccount.com"]) && alltrue([for b in values(google_artifact_registry_repository_iam_binding.ci_images) : b.repository == "ci-images" && b.location == "us-central1"])
    error_message = "ci-images is not written by cluster-admin-pipeline alone and read by the nodes alone."
  }
  assert {
    condition     = alltrue([for b in values(google_artifact_registry_repository_iam_binding.deploy) : !contains(b.members, "serviceAccount:cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com")])
    error_message = "cluster-admin-pipeline holds a role on a deploy registry."
  }
  # Cloud Build (#20): seatrials-deploy submits builds, as the builds' account, which pushes to the registry.
  assert {
    condition     = toset([for m in values(google_project_iam_member.deploy) : "${m.member} ${m.role}"]) == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com roles/cloudbuild.builds.editor", "serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com roles/serviceusage.serviceUsageConsumer"])
    error_message = "seatrials-deploy does not hold exactly cloudbuild.builds.editor and serviceusage.serviceUsageConsumer on the project."
  }
  assert {
    condition     = google_service_account.build["seatrials"].account_id == "seatrials-build" && google_service_account_iam_binding.build_user["seatrials"].role == "roles/iam.serviceAccountUser" && google_service_account_iam_binding.build_user["seatrials"].members == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"]) && google_service_account_iam_binding.build_user["seatrials"].service_account_id == "projects/tacplus-dev/serviceAccounts/seatrials-build@tacplus-dev.iam.gserviceaccount.com"
    error_message = "The builds do not run as seatrials-build, which seatrials-deploy alone may act as."
  }
  assert {
    condition     = toset([for m in values(google_project_iam_member.build) : "${m.member} ${m.role}"]) == toset(["serviceAccount:seatrials-build@tacplus-dev.iam.gserviceaccount.com roles/logging.logWriter"])
    error_message = "The builds' account holds more on the project than writing its logs."
  }
  assert {
    condition     = contains(keys(google_project_service.service), "cloudbuild.googleapis.com") && contains(keys(google_project_service.service), "artifactregistry.googleapis.com") && contains(keys(google_project_service.service), "storage.googleapis.com")
    error_message = "Cloud Build, Artifact Registry or Cloud Storage is not enabled in the project."
  }
  # The build bucket (#20): each submit's source and logs, deleted after 7 days.
  assert {
    condition     = google_storage_bucket.build["seatrials"].name == "tacplus-dev-seatrials-build" && google_storage_bucket.build["seatrials"].location == "US-CENTRAL1" && google_storage_bucket.build["seatrials"].uniform_bucket_level_access && google_storage_bucket.build["seatrials"].public_access_prevention == "enforced"
    error_message = "The build bucket is not tacplus-dev-seatrials-build, in us-central1, uniform access, public access prevented."
  }
  assert {
    condition     = length(google_storage_bucket.build["seatrials"].lifecycle_rule) == 1 && one(google_storage_bucket.build["seatrials"].lifecycle_rule[0].condition).age == 7 && one(google_storage_bucket.build["seatrials"].lifecycle_rule[0].action).type == "Delete"
    error_message = "The build bucket's objects are not deleted after 7 days."
  }
  assert {
    condition     = toset(keys(google_storage_bucket_iam_binding.build)) == toset(["seatrials/roles/storage.admin", "seatrials/roles/storage.objectAdmin", "seatrials/roles/storage.legacyBucketReader"]) && google_storage_bucket_iam_binding.build["seatrials/roles/storage.admin"].members == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"]) && google_storage_bucket_iam_binding.build["seatrials/roles/storage.objectAdmin"].members == toset(["serviceAccount:seatrials-build@tacplus-dev.iam.gserviceaccount.com"]) && google_storage_bucket_iam_binding.build["seatrials/roles/storage.legacyBucketReader"].members == toset(["serviceAccount:seatrials-build@tacplus-dev.iam.gserviceaccount.com"])
    error_message = "The build bucket is not seatrials-deploy's (storage.admin) and the builds' account's (storage.objectAdmin, and storage.legacyBucketReader for the bucket's storage.buckets.get, #68) alone."
  }
  assert {
    condition     = output.deployments["seatrials"].registry == "us-central1-docker.pkg.dev/tacplus-dev/seatrials" && output.deployments["seatrials"].build == { bucket = "gs://tacplus-dev-seatrials-build", sa = "seatrials-build@tacplus-dev.iam.gserviceaccount.com" } && output.deployments["seatrials"].environment_accounts == { test-idp = "test-idp-deploy@tacplus-dev.iam.gserviceaccount.com" }
    error_message = "The module does not give the deployment's registry, build bucket and builds' account, and its environment accounts."
  }
  # The fleet's CA and crypto file (#28, Jody's option D) and its root credential's key (#105, fleet-seatrials#77):
  # three secrets of the deployment, us-central1, no version; the init-secrets job's account adds versions and sees
  # their metadata (never a value), the deployment's identity reads them, nobody else holds a role (authoritative
  # bindings).
  assert {
    condition     = toset(keys(google_secret_manager_secret.fleet)) == toset(["fleet-ca-seatrials", "fleet-crypto-seatrials", "fleet-root-cred-seatrials"]) && alltrue([for s in google_secret_manager_secret.fleet : s.replication[0].user_managed[0].replicas[0].location == "us-central1" && s.labels["deployment"] == "seatrials" && s.labels["managed-by"] == "tacplus-dev-cloud"])
    error_message = "The deployment's fleet secrets are not fleet-ca-seatrials, fleet-crypto-seatrials and fleet-root-cred-seatrials, in us-central1."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.fleet)) == toset(flatten([for s in ["fleet-ca-seatrials", "fleet-crypto-seatrials", "fleet-root-cred-seatrials"] : [for r in ["secretVersionAdder", "viewer", "secretAccessor"] : "${s}/roles/secretmanager.${r}"]]))
    error_message = "The fleet secrets' roles are not exactly adding versions, seeing them and reading them."
  }
  assert {
    condition     = alltrue([for k, b in google_secret_manager_secret_iam_binding.fleet : b.members == toset([b.role == "roles/secretmanager.secretAccessor" ? "serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com" : "serviceAccount:seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com"])])
    error_message = "The fleet secrets' versions are added by someone besides the init-secrets job's account, or read by someone besides seatrials-deploy."
  }
  # The init-secrets job's account: its own, only fleet-seatrials' jobs in the environment init-secrets on protected
  # main become it (the provider's condition and this binding), and it holds no role but on the three secrets.
  assert {
    condition     = google_service_account.init_secrets["seatrials"].account_id == "seatrials-init-secrets" && google_service_account_iam_member.init_secrets_wif["seatrials"].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_member.init_secrets_wif["seatrials"].member == "principalSet://iam.googleapis.com/projects/555/locations/global/workloadIdentityPools/gitlab-com/attribute.project_environment/tacplus-dev/fleet-seatrials:init-secrets"
    error_message = "seatrials-init-secrets is not only tacplus-dev/fleet-seatrials' jobs in the environment init-secrets."
  }
  # GCP refuses a display_name over 100 characters at apply (2026-11-10: the first apply failed on 136).
  assert {
    condition     = length(google_service_account.init_secrets["seatrials"].display_name) <= 100
    error_message = "seatrials-init-secrets' display_name is over GCP's 100 characters."
  }
  assert {
    condition     = alltrue([for m in concat(values(google_project_iam_member.cluster_viewer), values(google_project_iam_member.deploy), values(google_project_iam_member.build)) : m.member != "serviceAccount:seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com"])
    error_message = "The init-secrets job's account holds a role on the project."
  }
  assert {
    condition     = output.deployments["seatrials"].fleet_secrets == { ca = "projects/tacplus-dev/secrets/fleet-ca-seatrials", crypto = "projects/tacplus-dev/secrets/fleet-crypto-seatrials", root_cred = "projects/tacplus-dev/secrets/fleet-root-cred-seatrials", environment = "init-secrets", sa = "seatrials-init-secrets@tacplus-dev.iam.gserviceaccount.com" }
    error_message = "The module does not give the deployment's fleet secrets and the init-secrets job's account."
  }
  assert {
    condition     = output.deployments["seatrials"].environment_certificates == { test-idp = { secrets = { tls = "projects/tacplus-dev/secrets/tls-test-idp", acme_account = "projects/tacplus-dev/secrets/acme-account-test-idp" }, challenge_zone = "acme-challenge-idp-test-tacplus-dev", name_servers = google_dns_managed_zone.acme_challenge["seatrials/test-idp"].name_servers } } && output.deployments["seatrials"].environment_secrets == { test-idp = ["projects/tacplus-dev/secrets/test-idp-seeds"] }
    error_message = "The module does not give the test IdP's certificate secrets, challenge zone and seed secret."
  }
  # seatrials' Google sign-in client (#37, fleet-seatrials#46): one secret of the deployment, us-central1, no version
  # (Jody adds them in the Console); the listed adders add versions, the deployment's identity alone reads them, nobody
  # else holds a role (authoritative bindings).
  assert {
    condition     = keys(google_secret_manager_secret.google_signin) == ["seatrials"] && google_secret_manager_secret.google_signin["seatrials"].secret_id == "google-signin-seatrials" && google_secret_manager_secret.google_signin["seatrials"].replication[0].user_managed[0].replicas[0].location == "us-central1" && length(google_secret_manager_secret.google_signin["seatrials"].replication[0].user_managed[0].replicas) == 1 && google_secret_manager_secret.google_signin["seatrials"].labels["deployment"] == "seatrials" && google_secret_manager_secret.google_signin["seatrials"].labels["managed-by"] == "tacplus-dev-cloud"
    error_message = "The deployment's Google sign-in secret is not google-signin-seatrials, in us-central1 alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.google_signin)) == toset(["seatrials/roles/secretmanager.secretAccessor", "seatrials/roles/secretmanager.secretVersionAdder"]) && alltrue([for k, b in google_secret_manager_secret_iam_binding.google_signin : b.secret_id == "google-signin-seatrials" && b.role == trimprefix(k, "seatrials/")])
    error_message = "The Google sign-in secret's roles are not exactly reading its versions and adding them."
  }
  assert {
    condition     = google_secret_manager_secret_iam_binding.google_signin["seatrials/roles/secretmanager.secretAccessor"].members == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"]) && google_secret_manager_secret_iam_binding.google_signin["seatrials/roles/secretmanager.secretVersionAdder"].members == toset(["user:jody@example.com"])
    error_message = "Someone besides seatrials-deploy reads the Google sign-in secret, or someone besides the listed adders adds its versions."
  }
  # The adders make the client in the Console's Google Auth Platform too, its branding first (#56): oauthconfig.editor
  # on the project, for each of them and nobody else, a member binding (not authoritative).
  assert {
    condition     = toset([for m in values(google_project_iam_member.google_signin_adders) : "${m.project} ${m.member} ${m.role}"]) == toset(["tacplus-dev user:jody@example.com roles/oauthconfig.editor"])
    error_message = "The Google sign-in adders do not hold roles/oauthconfig.editor on tacplus-dev, or someone else does."
  }
  assert {
    condition     = output.deployments["seatrials"].google_signin == "projects/tacplus-dev/secrets/google-signin-seatrials"
    error_message = "The module does not give the deployment's Google sign-in secret."
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
    condition     = length(google_compute_backend_service.lb["test-idp"].backend) == 1 && one(google_compute_backend_service.lb["test-idp"].backend[*].group) == "projects/tacplus-dev/zones/us-central1-a/networkEndpointGroups/seatrials-test-idp" && one(google_compute_backend_service.lb["test-idp"].backend[*].balancing_mode) == "CONNECTION"
    error_message = "The test IdP's backend is not the zonal NEG seatrials-test-idp in the cluster's zone, balanced by connection."
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.cluster]
}

# The looper pool is Axion too (#95).
run "x86_looper_pool_refused" {
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
      looper          = { machine_type = "e2-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.cluster]
}

# The looper pool can grow to a node (#95).
run "empty_looper_pool_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 0 }
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
      registry       = "ci-images"
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # Two pipelines would share one ACME account and one challenge zone.
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
      other     = { gitlab_project = "tacplus-dev/fleet-dev", environment = "seatrials", domain = "tacplus.dev", hostnames = [], account_id = "other-deploy", wif_provider = "tacplus-dev-fleet-dev" }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_account_as_deploy_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # The test IdP's jobs would run as the deploy account (#20: it must not be).
    deployments = {
      seatrials = {
        gitlab_project       = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts = { test-idp = "seatrials-deploy" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "init_secrets_account_as_deploy_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # The init-secrets job would run as the deploy account (#28: it must not be).
    deployments = {
      seatrials = {
        gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        init_secrets   = { environment = "init-secrets", account_id = "seatrials-deploy" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "init_secrets_environment_shared_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # The test IdP's jobs would become the init-secrets job's account too (#28: its environment is its own).
    deployments = {
      seatrials = {
        gitlab_project       = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts = { test-idp = "test-idp-deploy" }
        init_secrets         = { environment = "test-idp", account_id = "seatrials-init-secrets" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_certificate_without_account_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # A certificate for an environment that has no account of its own (#32): nobody would own it.
    deployments = {
      seatrials = {
        gitlab_project           = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_certificates = { test-idp = "idp.test.tacplus.dev" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_certificate_shared_domain_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # The test IdP's certificate on the deployment's domain (#32): two jobs would share one challenge zone.
    deployments = {
      seatrials = {
        gitlab_project           = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts     = { test-idp = "test-idp-deploy" }
        environment_certificates = { test-idp = "tacplus.dev" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_secret_taken_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # An environment's secret named as the deployment's certificate (#32): the test IdP's jobs would read it.
    deployments = {
      seatrials = {
        gitlab_project       = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts = { test-idp = "test-idp-deploy" }
        environment_secrets  = { test-idp = ["tls-seatrials"] }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_secret_fleet_taken_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # An environment's secret named as the deployment's fleet CA (#32, #28): the test IdP's jobs would read it.
    deployments = {
      seatrials = {
        gitlab_project       = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts = { test-idp = "test-idp-deploy" }
        environment_secrets  = { test-idp = ["fleet-ca-seatrials"] }
        init_secrets         = { environment = "init-secrets", account_id = "seatrials-init-secrets" }
      }
    }
  }
  expect_failures = [var.deployments]
}

run "environment_secret_root_cred_taken_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    # An environment's secret named as the deployment's root credential's key (#32, #105): the test IdP's jobs would
    # read it.
    deployments = {
      seatrials = {
        gitlab_project       = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        environment_accounts = { test-idp = "test-idp-deploy" }
        environment_secrets  = { test-idp = ["fleet-root-cred-seatrials"] }
        init_secrets         = { environment = "init-secrets", account_id = "seatrials-init-secrets" }
      }
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    deployments = {
      seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
    }
  }
  expect_failures = [var.zone]
}


run "google_signin_without_adders" {
  # Without GCP_GOOGLE_SIGNIN_ADDERS: the secret, its reader, and nobody adding versions (no binding of the role); a
  # deployment without google_signin has no such secret.
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    deployments = {
      seatrials = {
        gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
        google_signin  = true
      }
      other = {
        gitlab_project = "tacplus-dev/fleet-other", environment = "other", domain = "other.tacplus.dev", hostnames = ["other.tacplus.dev"], account_id = "other-deploy", wif_provider = "tacplus-dev-fleet-other"
      }
    }
    google_signin_adders = []
  }
  assert {
    condition     = keys(google_secret_manager_secret.google_signin) == ["seatrials"] && keys(google_secret_manager_secret_iam_binding.google_signin) == ["seatrials/roles/secretmanager.secretAccessor"]
    error_message = "Without adders, the Google sign-in secret has a binding besides its reader's, or a deployment without google_signin has the secret."
  }
  assert {
    condition     = google_secret_manager_secret_iam_binding.google_signin["seatrials/roles/secretmanager.secretAccessor"].members == toset([google_service_account.deploy["seatrials"].member]) && output.deployments["other"].google_signin == null
    error_message = "The Google sign-in secret is not read by the deployment's identity alone, or a deployment without it is given one."
  }
  assert {
    condition     = length(google_project_iam_member.google_signin_adders) == 0
    error_message = "Without adders, someone holds roles/oauthconfig.editor for the Google sign-in client."
  }
}

run "google_signin_adder_refused" {
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    google_signin_adders = ["jody@example.com"]
  }
  expect_failures = [var.google_signin_adders]
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
      looper          = { machine_type = "c4a-standard-2", max_nodes = 2 }
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
      registry       = "ci-images"
    }
    runner_token_adders = ["jody@example.com"]
  }
  expect_failures = [var.runner_token_adders]
}
