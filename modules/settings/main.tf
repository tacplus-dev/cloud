# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The constants every stack shares, in one place: the parent folder this runs in, the region, the projects' IDs, the
# pipeline's identity, the looper VMs and the reserved machines. No resource, no provider: each stack reads them with
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

output "autoscaler_log" {
  description = "Whether the cluster autoscaler's log is read by the audit (#85; README, The hub's audit): the log view hub-audit-autoscaler on each project's _Default bucket, hub-audit's conditional roles/logging.viewAccessor on it alone, and ci/hub-audit.sh's read of it. False until the host organization grants cloud-admin-pipeline roles/logging.configWriter on the parent folder, which the views need (README, What the host organization provides); then true, in a commit of its own, so that no apply:ci fails before the grant."
  value       = false
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
      # The Admiral's (#84; tacplus-dev/admiral#5, option A; Jody created it on 2026-11-20: issues write, metadata read,
      # every repository of tacplus-dev, no webhook). No GitLab job signs with it: its one signer is the account admiral
      # (below, admiral), on the key alone.
      tacplus-admiral = { app_id = "5853599", installation_id = "184144753", import = true, namespace = false, environments = [], accounts = {}, projects = [] }
      # The rolling check's and the merger's (#111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md, the
      # panel's 4, 5 and 8). No GitLab job signs with either: tacplus-check's signers are the rolling check's machines
      # alone (reserved_vms), so its status of main and its main-green are what a report cannot mint; tacplus-merger's
      # is the merger's machine alone, which runs no project code, and once the managers retire it is the only identity
      # that accepts and merges. Jody creates both apps (their IDs here then) and imports their keys (import true then).
      tacplus-check  = { app_id = "", installation_id = "", import = false, namespace = false, environments = [], accounts = {}, projects = [] }
      tacplus-merger = { app_id = "", installation_id = "", import = false, namespace = false, environments = [], accounts = {}, projects = [] }
    }
  }
}

output "admiral" {
  description = <<-EOT
    The Admiral's credentials (#84; tacplus-dev/admiral#5, Jody's option A, 2026-11-20): what the Admiral of the dev
    cluster's fleet reaches with its own kernel-signed identity (its ES256 JWT, sub its SPIFFE ID, subject), through
    Workload Identity Federation: the pool pool of the dev project, whose provider provider trusts the fleet kernel's
    OIDC issuer issuer (by discovery) for subject alone; the service account account_id in the ci project, which only
    that subject becomes; key, its GitHub App's import-only key in github_apps' key ring, on which the account alone
    is roles/cloudkms.signerVerifier; and secret, a Secret Manager secret in the ci project with no version, which the
    account alone reads (the triage project's GitLab access token, which the ci stack's admiral_secret_adders add by
    hand). None of it is secret.
  EOT
  value = {
    # The fleet whose kernel issues it: the seatrials fleet in the dev cluster, the issuer llmproxy's Anthropic
    # identity trusts too (deployments' llmproxy, #34). One issuer URL, never a pattern: the SPIFFE ID's trust domain
    # tacplus.dev is the fleet's spiffe_prefix (fleet-seatrials#16, #119), not a key, so another fleet's Admiral is
    # another provider.
    pool       = "fleet-kernels"
    provider   = "seatrials"
    issuer     = "https://seatrials.tacplus.dev"
    subject    = "spiffe://tacplus.dev/system/services/admiral"
    account_id = "admiral"
    key        = "tacplus-admiral"
    secret     = "admiral-triage-gitlab"
  }
}

output "releases" {
  description = <<-EOT
    The release registry (#115; the hub's approval of its design B, on Jody's standing word, 2026-11-26:
    tacplus-dev/looper#265): the Docker repository repository of the ci project in location, the region (#120: the
    host's gcp.resourceLocations, in:us-central1-locations, admits it alone; the multi-region us failed apply:ci),
    no cleanup policy, where tacplus-dev/build's release builds publish <repo>:<branch>-<commit, 12 hex> by digest
    (tacplus-dev/looper#252). Its one writer, the ci project's account account_id, which only gitlab_project's jobs on
    its protected main in its GitLab environment environment (the publish jobs) become, through the ci project's
    gitlab-com pool and its provider publish_provider (not wif_provider, the bootstrap's name alone here:
    tests/settings_test.sh). Its readers, by deployment: each one's identity (deployments'
    account_id, in the dev project), which copies a release by digest into its own deploy registry
    (tacplus-dev/fleet-seatrials#82: seatrials' releases job, as seatrials-deploy). Nobody else reads it.
  EOT
  value = {
    repository       = "releases"
    location         = "us-central1"
    account_id       = "release-publish"
    gitlab_project   = "tacplus-dev/build"
    environment      = "registry"
    publish_provider = "tacplus-dev-build-release"
    readers          = ["seatrials"]
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
    are its identity's; and environment_secrets, the IDs of the secrets only the account and the deployment's identity
    add versions to and read (#73); and init_secrets (#28), the GitLab environment of its init-secrets job and the
    account only its project's jobs in that environment, on protected main, may become: it alone adds the versions of
    fleet-ca-<deployment>, fleet-crypto-<deployment> and (#105) fleet-root-cred-<deployment> (the fleet's CA, crypto
    file and root credential's key; it sees their metadata, never a value), which its identity alone reads; and
    google_signin (#37), true when it has a Google sign-in client: the
    secret google-signin-<deployment> (the client JSON the Console downloads), whose versions the dev stack's
    google_signin_adders add by hand, in the Console (Google has no API that makes a web client), and which its
    identity alone reads. Optionally (#34): llmproxy, its llmproxy's identity in the Anthropic organization, which the
    anthropic stack owns: the federation issuer (its fleet's OIDC issuer, url), the service account (an explicit member
    of workspace_id with workspace_role) and the rule that lets the issuer's tokens whose sub is subject act as that
    account in workspace_id with oauth_scope (and, when set, only for audience, its tokens living
    token_lifetime_seconds; unset, the provider's defaults); each description (optional), its text in the Console; each
    adopt, the ID of the one made by hand that the stack adopts rather than makes (null: it makes it).
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
    # fleet-seatrials#44), and adds the root credential's key to fleet-root-cred-seatrials (#105, fleet-seatrials#77),
    # which seatrials-deploy alone reads, for its client-steps job. Its Google sign-in client is in tacplus-dev, its
    # secret google-signin-seatrials (#37, fleet-seatrials#46): Jody makes the client and adds the secret's versions in the Console.
    # Its llmproxy's Anthropic identity (#34), made by hand in the Console on 2026-10-24 and adopted by the anthropic
    # stack by these IDs, which its llmproxy names (fleet-seatrials deploy/bootstrap/services/llmproxy.yaml): the
    # issuer is the fleet's kernel (OIDC discovery at its public name), the rule matches llmproxy's own identity. The
    # account's membership of the workspace is made by the stack, not adopted: the hand-made account had none. The
    # descriptions, the rule's audience and its token lifetime are the Console's, as the refused plan:anthropic of
    # 2026-11-13 listed them (job 18022609528).
    # The rule is narrowed to workspace:inference (Jody, 2026-11-10: llmproxy calls inference only), in the commit after
    # the adoption (apply:anthropic job 18024991252): an adoption plans no change (ci/policy.sh); this is an update in
    # place, the same ID.
    seatrials = {
      gitlab_project           = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", hostnames = ["seatrials.tacplus.dev", "idp.test.tacplus.dev"], account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials"
      images                   = { registry = "seatrials", bucket = "seatrials-build", account_id = "seatrials-build", days = 7 }
      environment_accounts     = { test-idp = "test-idp-deploy" }
      environment_certificates = { test-idp = "idp.test.tacplus.dev" }
      environment_secrets      = { test-idp = ["test-idp-seeds"] }
      init_secrets             = { environment = "init-secrets", account_id = "seatrials-init-secrets" }
      google_signin            = true
      llmproxy = {
        workspace_id = "wrkspc_017AfVbSBgLY399kXGDRtQ6e"
        issuer       = { name = "seatrials", url = "https://seatrials.tacplus.dev", adopt = "fdis_01JKxG3CyMXqfgcG8HoqorvT" }
        service_account = {
          name           = "llmproxy-seatrials"
          description    = "llmproxy on the seatrials proof fleet (seatrials.tacplus.dev); tokens by federation only"
          workspace_role = "workspace_developer"
          adopt          = "svac_01EoVk8wqp7sVYgBkRyyd5MT"
        }
        rule = {
          name                   = "llmproxy-seatrials"
          description            = "llmproxy on the seatrials fleet mints its own kernel-signed assertion; inference only"
          subject                = "spiffe://tacplus.dev/system/services/llmproxy"
          audience               = "https://api.anthropic.com"
          token_lifetime_seconds = 600
          oauth_scope            = "workspace:inference"
          adopt                  = "fdrl_01Fvxu1oSKHN6rwtdZmRbGY8"
        }
      }
    }
  }
}

output "anthropic" {
  description = <<-EOT
    The Anthropic organization's bootstrap (#34; README, The Anthropic organization): the one federation rule this
    pipeline exchanges its GitLab ID tokens through for an org:admin token, made by hand in the Console (an OAuth
    caller can neither make an org:admin rule nor give an account the admin role) and never in a stack's state. The
    anthropic stack only reads it and checks it is still this: an issuer of issuer_url, the rule's scope org:admin, its
    subject exactly this project's protected main, its claims and audience these, its target an admin account.
  EOT
  value = {
    admin = {
      issuer_url = "https://gitlab.com"
      subject    = "project_path:tacplus-dev/cloud:ref_type:branch:ref:main"
      claims     = { ref_protected = "true" }
      audience   = "https://api.anthropic.com"
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
    # gateway is a gateway change (#21). Its NEG exists since fleet-seatrials' first test-idp run (2026-11-17, #42).
    test-idp = { port = 8443, neg = "seatrials-test-idp", endpoint_port = 8443, ready = true }
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

output "cos_arm64_image" {
  description = <<-EOT
    The looper VMs' and the reserved machines' boot image (#108, #111), the runner pools' until #113: Google's
    Container-Optimized OS for arm64, one image by name, never a family (decisions/builds-in-containers-2026-11-03.md,
    #4). The VM is vanilla: nothing is installed at boot, and the container runtime is the OS's own. A newer COS
    reaches the VMs only as a commit of this pin, its plan and its apply; a revert is the rollback. This one is the
    build the cos-arm64-stable family served on 2026-11-03.
  EOT
  value       = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
}

# The looper VMs of the ci project (#108; tacplus-dev/roadmap decisions/looper-build-vms-2026-11-24.md), by
# tacplus-dev repository: tacplus first, the pilot, on its own; tacplus-dev, the org's shared VM (decision point 12,
# Jody 2026-11-25), every other tacplus-dev repository (a repository given its own entry leaves it). Each project's
# spec will come from its own looper.yaml (tacplus-dev/looper#240) and is right-sized from measured use (point 9);
# until then it is here. image is the looper-vm image by digest: the looper image (looper-vm is in it).
output "looper_vms" {
  description = "The looper VMs (the ci module's looper_vms): per repository, its machine type (C4A), its Hyperdisk Balanced disk in GB, spot or not, and its image by digest (empty: none yet)."
  value = {
    tacplus     = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper@sha256:c3a8b379342d988683c777b549e57e9b57f8e81eaf1ab557158806589fc89f5b" }
    tacplus-dev = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper@sha256:c3a8b379342d988683c777b549e57e9b57f8e81eaf1ab557158806589fc89f5b", org = "tacplus-dev" }
  }
}

# The reserved machines of the ci project (#111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md, the
# panel's items 4, 5 and 8; capacity approved by Jody 2026-11-25, "go with what you all agreed with"), by name: the
# rolling check of main for tacplus, the heavy project, and one for the org's other repositories, each running only
# while there is something to check (its VM stopped otherwise, its disk kept: Jody, 2026-11-25); and the merger's small
# always-on machine, for every org repository, which starts them. On demand, never spot; none is a looper VM (no model
# token, not the reports' key, no kicker) nor the GitLab build project; each its own cache (its boot disk). Sized by
# the quotas, none raised (Jody, 2026-11-25: "why do we need a CPU quota request??"; ci_cpus, ci_disks): tacplus's
# check on C4A, 8 CPUs until the full gates are measured on it (tacplus-dev/looper#249 posts the peaks), the org's
# check and the merger on T2A (pd-balanced), outside the C4A and Hyperdisk Balanced limits the looper VMs fill. image
# is the looper image by digest: main-c0d53ba, the first with looper-vm check and merger (tacplus-dev/looper#249,
# #251; image.yml run 45964797642). key is the GitHub App key its account signs with: tacplus-manager, the identity that
# merges today, until Jody makes tacplus-check and tacplus-merger (the hub, for Jody, 2026-11-25: a setting, no new App
# to go live); the ci stack gives each its app's IDs (github_apps).
output "reserved_vms" {
  description = "The reserved machines (the ci module's reserved_vms): per name, its role (check, the rolling check of main; merger, the merger), the tacplus-dev repository (repo) or org (org) it serves, its machine type (C4A, on Hyperdisk Balanced, or T2A, on pd-balanced), its disk in GB, its image by digest (empty: none yet, and no VM), and its GitHub App key."
  value = {
    check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-8", disk_gb = 100, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" }
    check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "t2a-standard-4", disk_gb = 100, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" }
    merger            = { role = "merger", org = "tacplus-dev", machine_type = "t2a-standard-1", disk_gb = 30, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" }
  }
}

output "ci_cpus" {
  description = <<-EOT
    tacplus-ci's CPUs (#55): quota, its CPUS_ALL_REGIONS (the project's limit, 32, as Google set it); c4a_quota, the
    region's C4A family limit (24, the audit's Quotas table); and t2a_quota, the region's T2A_CPUS (24, the audit's
    Quotas table, unused since the runner pools went, #113). A raise is a request to Google, then this line. The ci
    stack's test refuses VMs that need more CPUs than any of them at their peak: a VM over it fails QUOTA_EXCEEDED, as
    the build pool's second did on 2026-11-13. The looper VMs (0..1 each), 8 + 8 = 16 C4A CPUs (Jody, 2026-11-26), and
    the reserved machines (#111) with an image: check-tacplus's 8 more (24 of 24 C4A), the org's check's 4 and the
    merger's 1 on T2A (5 of 24): 29 of 32 in all. No quota is raised for them (Jody, 2026-11-25: "why do we need a CPU
    quota request??"): the limits are met by sizing (check-tacplus is 8 CPUs until a measurement of the full gates on
    it says it needs more).
  EOT
  value = {
    quota     = 32
    c4a_quota = 24
    t2a_quota = 24
  }
}

output "ci_disks" {
  description = <<-EOT
    tacplus-ci's disk GB in us-central1 (#113; the audit's Quotas table: the region's limits, as Google set them; a raise
    is a request to Google, then this line): hyperdisk_balanced_quota_gb (500), which every C4A VM's boot disk counts
    against, and ssd_total_quota_gb (SSD_TOTAL_GB, 500, unused since the runner pools and their manager went), which a
    T2A VM's pd-balanced boot disk does. The ci stack's test refuses VMs whose disks need more GB than either: a VM over
    it fails QUOTA_EXCEEDED and never comes. Today: the looper VMs 200 + 200 = 400 of 500 Hyperdisk Balanced; the
    reserved machines (#111) with an image, check-tacplus's 100 more (500 of 500), the org's check's 100 and the
    merger's 30 of pd-balanced (130 of 500). A stopped check machine keeps its disk, so each counts all the time.
  EOT
  value = {
    hyperdisk_balanced_quota_gb = 500
    ssd_total_quota_gb          = 500
  }
}
