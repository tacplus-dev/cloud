# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The constants every stack shares, in one place: the parent folder this runs in, the region, the projects' IDs, the
# pipeline's identity and the runner pools. No resource, no provider: each stack reads them with
# `module "settings" { source = "../../modules/settings" }`. bootstrap/bootstrap.sh holds the same names for what
# it creates (tests/settings_test.sh checks they agree).

terraform {
  required_version = ">= 1.13.2"
}

# The one input: the folder the host organization hands to this repository (README, What the host organization
# provides). Never written here: the stacks that build under it take it as their variable parent_folder, which the
# pipeline sets from the protected GitLab variable GCP_PARENT_FOLDER (ci/lib.sh).
variable "parent_folder" {
  description = "The parent folder's numeric ID, as bootstrap/bootstrap.sh --folder takes it; null in a stack that builds nothing under it."
  type        = string
  default     = null
  validation {
    condition     = var.parent_folder == null || can(regex("^[0-9]+$", var.parent_folder))
    error_message = "The parent folder is its numeric ID (folders/<ID> without the prefix)."
  }
}

output "parent_folder" {
  description = "The parent folder's resource name, folders/<ID>: everything the pipeline builds is under it."
  value       = var.parent_folder == null ? null : "folders/${var.parent_folder}"
}

output "region" {
  description = "The region every resource is in (the host organization's gcp.resourceLocations must admit it: README)."
  value       = "us-central1"
}

output "bootstrap" {
  description = "What bootstrap/bootstrap.sh created: never changed by the pipeline."
  value = {
    folder       = "bootstrap"
    project      = "tacplus-bootstrap"
    state_bucket = "tacplus-bootstrap-tofu-state"
    pipeline_sa  = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    wif_pool     = "gitlab-com"
    wif_provider = "tacplus-dev-cloud"
    # The GitLab token the gitlab stack's provider uses (a group access token of tacplus-dev, Owner, scope api),
    # by version: a new token is a new version and a commit here (README, Rotating the GitLab token).
    gitlab_token_secret = "projects/tacplus-bootstrap/secrets/gitlab-token/versions/2"
  }
}

output "gitlab_project" {
  description = "This repository's GitLab project, where its pipeline runs (the cluster pattern)."
  value       = "tacplus-dev/cloud"
}

output "projects" {
  description = "The projects the pipeline builds, by folder: folder name and project ID."
  value = {
    ci  = { folder = "ci", project = "tacplus-ci", name = "tacplus ci" }
    dev = { folder = "dev", project = "tacplus-dev", name = "tacplus dev" }
  }
}

output "github_apps" {
  description = <<-EOT
    The GitHub Apps whose private keys are Cloud KMS signing keys in the ci project's key ring key_ring (#19;
    tacplus-dev/looper README, Only the manager writes main), and who signs with each, through Workload Identity
    Federation from gitlab.com, the ci project's workload identity pool, pool. Each key is import-only: the app's key, generated on
    GitHub, is imported once (import: through an import job of its own, by the protected GitLab variable
    GCP_KMS_KEY_IMPORTERS's members) and never leaves KMS. A key's signers are its own bindings, never the key
    ring's: environments, the jobs of looper's ref in those GitLab environments (its provider's attribute role,
    project_id:ref:ref_protected:environment); namespace, every protected ref of the namespace (its provider's
    attribute namespace_id); accounts (#30), by account ID, an account in the ci project that signs, which only
    gitlab_project's jobs, federated through pool, may become (for a project whose jobs' one provider is another
    project's: fleet-seatrials', the dev project's); projects, GitLab projects whose jobs, federated through pool, sign
    as themselves. A pool is bootstrap (tacplus-bootstrap's, this pipeline's) or dev (the dev project's, the
    deployments'), both gitlab-com, whose providers map attribute.project_path. The IDs are GitHub's and GitLab's,
    none of them secret.
  EOT
  value = {
    key_ring = "looper"
    pool     = "gitlab-loopers"
    # tacplus-dev's GitLab group: namespace_id in a job's id_token (CI_PROJECT_NAMESPACE_ID), which a renamed or
    # re-created path does not take over.
    namespace = { path = "tacplus-dev", id = "145863835", wif_provider = "gitlab-com" }
    looper    = { project = "tacplus-dev/looper", project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }
    apps = {
      # The bypass actor of main's ruleset: the managers, and the scans for their commits to main, never a report,
      # whose code runs in its job (looper#90).
      tacplus-manager = { app_id = "5632100", installation_id = "179024536", import = true, namespace = false, environments = ["looper-manager", "looper-scan"], accounts = {}, projects = [] }
      # Pushes branches, comments and labels, nothing to main.
      tacplus-looper = { app_id = "5632122", installation_id = "179024135", import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"], accounts = {}, projects = [] }
      # Read-only. Off jody1-328023 (#30; Jody, 2026-11-08): a new key, imported here, then the old one revoked on
      # the app. It signs for the namespace's protected refs (through gitlab-loopers' provider gitlab-com: what else
      # signed in jody1-328023, tacplus-dev/kernel's looper-identity prepare, once it exchanges its id_token there),
      # for the drift issues of this project (through its own pool) and of tacplus-dev/cluster (through the dev
      # project's, its GCP_WIF_PROVIDER's), github_app_token's direct call, and for fleet-seatrials' jobs as
      # fleet-seatrials-reader (their .github-reader's TACPLUS_READER_SA: their GCP_WIF_PROVIDER is the dev project's
      # tacplus-dev-fleet-seatrials). tacplus-dev/build holds a key as a file variable.
      tacplus-reader = {
        app_id   = "5531358", installation_id = "176655068", import = true, namespace = true, environments = []
        accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } }
        projects = [{ pool = "bootstrap", gitlab_project = "tacplus-dev/cloud" }, { pool = "dev", gitlab_project = "tacplus-dev/cluster" }]
      }
    }
  }
}

output "deployments" {
  description = <<-EOT
    The deployments whose pipelines own their TLS certificates (decisions/certificates-by-pipeline-2026-11-03.md,
    #6), each with an identity of its own in the dev project, federated from its GitLab project's protected main:
    gitlab_project, account_id and wif_provider. It alone adds and reads the versions of the secrets
    tls-<deployment> (the certificate and its key) and acme-account-<environment> (its ACME account key; environment
    is the deployment's GitLab environment), and it alone administers the zone for _acme-challenge.<domain> (the
    certificate is <domain> and *.<domain>, so DNS-01 writes there only), delegated from <domain>'s zone. Its
    hostnames are A records of the zone (zone, below) to the gateway's address, the one public IP (#13). It gets the
    dev cluster's credentials (container.clusterViewer on that cluster alone; its rights inside are
    tacplus-dev/cluster's). Optionally (#20): images, its Cloud Build builds (registry, the Docker registry its
    images go to, which the builds' account writes and it and the nodes read; bucket, after the project ID, where
    its submits stage their source and write their logs, kept for days; account_id, the account the builds run as);
    and environment_accounts, by GitLab environment, an account only its project's jobs in that environment, on
    protected main, may become, with the cluster's credentials and no other role but, by environment (#32):
    environment_certificates, its certificate's domain, whose secrets tls-<environment> and acme-account-<environment>
    and challenge zone (delegated from the zone when the domain is in it) are the account's alone, as a deployment's
    are its identity's; and environment_secrets, the IDs of the secrets only the account adds versions to and reads;
    and init_secrets (#28), the GitLab environment of its init-secrets job and the account only its project's jobs in
    that environment, on protected main, may become: it alone adds the versions of fleet-ca-<deployment> and
    fleet-crypto-<deployment> (the fleet's CA and crypto file; it sees their metadata, never a value), which its
    identity alone reads; and google_signin (#37), true when it has a Google sign-in client: the secret
    google-signin-<deployment> (the client JSON the Console downloads), whose versions the dev stack's
    google_signin_adders add by hand, in the Console (Google has no API that makes a web client), and which its
    identity alone reads.
  EOT
  value = {
    # Its pipeline still runs as seatrials-deploy@jody1-328023 against the interim secrets and zone there (README,
    # Certificates); it becomes this identity when seatrials moves off jody1-328023.
    # idp.test.tacplus.dev is its test IdP's (tacplus-dev/fleet-seatrials, test-idp/), on the same address: the
    # gateway's address is the one public IP (#13), and the test IdP has a port of its own on it (load_balancer, #21).
    # Its images (#20, fleet-seatrials#39): built on Cloud Build as seatrials-build, from source staged in the bucket
    # tacplus-dev-seatrials-build, into the deploy registry us-central1-docker.pkg.dev/tacplus-dev/seatrials. Cloud
    # Build is for now (Jody, 2026-11-06): its roles and the bucket come out once builds move to the cluster's build
    # pool (tacplus-dev/looper#84). Its test IdP's jobs, in the GitLab environment test-idp, run as test-idp-deploy,
    # which owns the test IdP's certificate (idp.test.tacplus.dev: *.tacplus.dev does not cover it) and its seeds,
    # test-idp-seeds, in Secret Manager rather than GitLab variables (#32, fleet-seatrials#27; as #28). Its
    # init-secrets job, in the GitLab environment init-secrets, runs as seatrials-init-secrets (#28,
    # fleet-seatrials#44). Its Google sign-in client is in tacplus-dev, its secret google-signin-seatrials (#37,
    # fleet-seatrials#46): Jody makes the client and adds the secret's versions in the Console.
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
}

output "load_balancer" {
  description = <<-EOT
    The public entry (decisions/network-exposure-2026-11-03.md, its addendum "we terminate TLS, not the cloud", #21):
    Google's global external proxy Network Load Balancer (TCP proxy) on the global address gateway (#13), the one
    public IP, passing each connection, TLS unopened, to the pods behind a standalone zonal network endpoint group (NEG)
    in the dev cluster. One listener per port of the address (a TCP proxy does not route by SNI): port, its forwarding
    rule's; neg, the NEG's name, which this pipeline names and the Service's cloud.google.com/neg annotation gives it
    ({"exposed_ports": {"<service port>": {"name": "<neg>"}}}), a contract with whoever renders that Service;
    endpoint_port, the port of the NEG's endpoints, the pods' (the Service's targetPort), which the health check probes
    and the nodes admit from Google's ranges only; ready, true once GKE has made the NEG in the cluster's zone: until
    then the backend service has no backend (the API refuses one that names a NEG that does not exist), and the
    commit that sets it adds it.
  EOT
  value = {
    # tacplus.dev's gateway: tacplus-dev/operator renders seatrials' gateway Service (port 443, targetPort 8443, every
    # gateway replica) with this NEG (tacplus-dev/operator#22). Its NEG's name is <deployment>-gateway.
    gateway = { port = 443, neg = "seatrials-gateway", endpoint_port = 8443, ready = false }
    # The test IdP (idp.test.tacplus.dev, tacplus-dev/fleet-seatrials#27), on a port of its own of the same address:
    # https://idp.test.tacplus.dev:8443, Keycloak's own TLS on its default HTTPS port, rendered by fleet-seatrials'
    # test-idp/ with this NEG. Test only: a second address would be a second public IP, and SNI routing in the
    # gateway is a gateway change (#21).
    test-idp = { port = 8443, neg = "seatrials-test-idp", endpoint_port = 8443, ready = false }
  }
}

output "zone" {
  description = <<-EOT
    tacplus.dev's zone, in the dev project, written only by this pipeline (#13): it replaces the zone tacplus-dev of
    jody1-328023, which was written by hand. records are that zone's records, copied as they are there (each name
    with its trailing dot, rrdatas as Cloud DNS writes them: a TXT string in quotes), except what the dev stack
    writes itself: the deployments' hostnames (A, to the gateway's address), the delegations of dev.tacplus.dev and
    of the challenge zones (NS), and the zone's own SOA and NS. A record changed in the old zone during the cutover is
    changed here too (README, The tacplus.dev cutover); after it, a record is a commit here.
  EOT
  value = {
    zone   = "tacplus-dev"
    domain = "tacplus.dev."
    # As jody1-328023's zone served them on 2026-11-04: the site (GitHub Pages) and its verification, and DMARC.
    records = [
      { name = "tacplus.dev.", type = "A", ttl = 3600, rrdatas = ["185.199.108.153", "185.199.109.153", "185.199.110.153", "185.199.111.153"] },
      { name = "tacplus.dev.", type = "AAAA", ttl = 3600, rrdatas = ["2606:50c0:8000::153", "2606:50c0:8001::153", "2606:50c0:8002::153", "2606:50c0:8003::153"] },
      { name = "tacplus.dev.", type = "TXT", ttl = 300, rrdatas = ["\"google-site-verification=BBk1Mdc_mSNbbRfqhsfEK9bHKALRrMo7qCnZyGd99i4\""] },
      { name = "www.tacplus.dev.", type = "CNAME", ttl = 3600, rrdatas = ["tacplus-dev.github.io."] },
      { name = "_dmarc.tacplus.dev.", type = "TXT", ttl = 3600, rrdatas = ["\"v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;\""] },
      # GitHub Pages' domain verification for tacplus-dev (kept so the verified domain stays verified).
      { name = "_github-pages-challenge-tacplus-dev.tacplus.dev.", type = "TXT", ttl = 3600, rrdatas = ["\"cf48f188ca7e110f048f0a59ca6a92\""] },
    ]
  }
}

output "ubuntu_arm64_image" {
  description = "The runner manager's boot image: one Ubuntu 24.04 arm64 image by name (never a family), and the Ubuntu archive snapshot its packages come from."
  value = {
    image    = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    snapshot = "20261024T000000Z"
  }
}

output "cos_arm64_image" {
  description = <<-EOT
    The runner pools' boot image: Google's Container-Optimized OS for arm64, one image by name, never a family
    (decisions/builds-in-containers-2026-11-03.md, #4). The VM is vanilla: nothing is installed at boot, and the
    container runtime is the OS's own. A newer COS reaches the workers only as a commit of this pin, its plan and its
    apply; a revert is the rollback. This one is the build the cos-arm64-stable family served on 2026-11-03.
  EOT
  value       = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
}

locals {
  # The always-on shared VM's machine type (Jody, #5: "B for now"). Moving to t2a-standard-16, four jobs at once, is
  # this one line, on Jody's word (if the recap shows jobs queueing): its capacity and its disk follow.
  shared_machine_type = "t2a-standard-8"
  # How many jobs a machine type runs at once. Jody, 2026-11-10: "If it's a looper and it wants to run, it runs,
  # period" (as on his Mac): no slots. A job is not a reservation of CPUs or memory; the jobs share the VM like
  # processes, and 25 is a ceiling no day reaches, not a slot count.
  shared_capacity = { "t2a-standard-8" = 25, "t2a-standard-16" = 25 }

  # The job containers' settings, the agents' and the builds' kept apart (#5): the shared pool runs both under one
  # registration, so with one setting, today the builds' (the same as the agents'). If the build jobs need settings
  # the agents must not get (rootless BuildKit's seccomp and apparmor, tacplus-dev/tacplus#315), the split is a
  # build pool of its own with job = local.jobs.build, and the shared pool's job = local.jobs.agent. disk_gb is a
  # job's share of its VM's disk: the disk is bounded per VM, not per job (Container-Optimized OS has no per-container
  # disk limit, #5), so a job that fills it fails the jobs beside it.
  jobs = {
    agent = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }
    build = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }
    # The shared pool's (Jody, 2026-11-10, no slots): a job may use the whole VM's CPUs and all but 4 GB of its
    # memory (the OS's, Docker's and the runner's), so one job can't starve the VM's own processes. Its disk share is
    # what a looper job needs (its checkout and its tools' caches); the disk is the VM's, shared.
    shared = { cpus = "8", memory = "28g", memory_swap = "28g", disk_gb = 12, security_opt = [] }
  }
}

output "runner_pools" {
  description = <<-EOT
    The runner pools of the ci project: each a managed instance group of arm64 VMs, sized by the manager's
    autoscaler, and its runner registration in GitLab. Job containers share a pool's VMs (capacity at once, each
    within its job's CPU and memory limits, without swap) and the VMs are reused; each job's containers and volumes
    are discarded (decisions/looper-job-per-issue-2026-11-03.md, #5). idle_count VMs are kept running, never more
    than max_instances: raising max_instances is a commit, on Jody's word. A VM's disk is capacity times a job's
    share, plus os_disk_gb for the OS and the jobs' images. A pool with service_account = true runs as an account of
    its own with no role; false, with no account and no scopes at all. Registered paused: moving the runners off
    jody1-328023 is a later issue, which unpauses them.
  EOT
  value = {
    # pd-standard (not SSD: the project's SSD_TOTAL_GB quota is 500 in us-central1, two 250 GB balanced disks) and
    # max_instances 3 (CPUS_ALL_REGIONS is 32: three 8-CPU VMs and the manager), 2026-11-08. Raised temporarily (Jody, 2026-11-07: "raise the number of nodes temporarily"): three more on-demand
    # t2a-standard-8 VMs, about $0.93/h, to clear the queue to seatrials' first deploy; back to 1 once the in-cluster
    # runners take the looper jobs (tacplus-dev/looper#84).
    # The three always-on nodes for now (Jody, 2026-11-10): every looper and control job, with no slots (capacity
    # above): "The loopers run as many as needed divided across the 3 always on nodes." Builds are not here: they run
    # on the spot build pool below. It replaces the jody1-328023 pools, whose settings change only over SSH. The
    # in-cluster runners take this arrangement over (tacplus-dev/looper#84, tacplus-dev/cluster#18). The build identity is not on the VM: build jobs become it
    # through Workload Identity Federation (the ci module's build cache).
    shared = {
      machine_type    = local.shared_machine_type, disk_type = "pd-standard", os_disk_gb = 50
      capacity        = local.shared_capacity[local.shared_machine_type], max_instances = 3, idle_count = 3, idle_time = "30m"
      job             = local.jobs.shared
      service_account = false
      spot            = false
      runner          = { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale", "autoscale-16"], protected = false }
    }
    # The builds (Jody, 2026-11-10): "Builds run on the spot instances. And builds can be limited to a few at a time."
    # Up to two spot t2a-standard-8s, from zero (no VM while no build waits), four builds a VM, each allowed 4 CPUs and
    # 14g (they share the VM like processes): eight builds at once (Jody, 2026-11-11, "Yes": two builds at a time left
    # 13 queued and every manager timing out). 16 CPUs at peak, inside CPUS_ALL_REGIONS 48. tacplus-dev/build's jobs only.
    build = {
      machine_type    = "t2a-standard-8", disk_type = "pd-standard", os_disk_gb = 50
      capacity        = 4, max_instances = 2, idle_count = 0, idle_time = "15m"
      job             = local.jobs.build
      service_account = false
      spot            = true
      runner          = { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "build"], protected = false }
    }
    # On demand, protected: their credentials never share a VM with agents. A VM stays for 30 minutes idle.
    deploy = {
      machine_type    = "t2a-standard-4", disk_type = "pd-balanced", os_disk_gb = 30
      capacity        = 2, max_instances = 1, idle_count = 0, idle_time = "30m"
      job             = { cpus = "2", memory = "6g", memory_swap = "6g", disk_gb = 25, security_opt = [] }
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/fleet-seatrials", tags = ["deploy"], protected = true }
    }
    # Also tacplus-dev/cloud's own pipeline (tag cloud), 2026-11-10: its jody1-328023 runner (58307471) stopped taking
    # jobs, and nothing stays in the thescottsweb.com org. Both are Jody's infrastructure pipelines on protected main,
    # as on jody1. Two jobs of 2 CPUs and 7g (tofu, trivy, the scanners).
    cluster = {
      machine_type    = "t2a-standard-4", disk_type = "pd-balanced", os_disk_gb = 30
      capacity        = 2, max_instances = 1, idle_count = 0, idle_time = "30m"
      job             = { cpus = "2", memory = "7g", memory_swap = "7g", disk_gb = 20, security_opt = [] }
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/cluster", also_projects = ["tacplus-dev/cloud"], tags = ["cluster", "cloud"], protected = true }
    }
  }
}
