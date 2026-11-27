# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci stack's plan under a stub parent folder, with an empty project (mock providers: no credentials, no cloud):
# the stack plans, and its module, with the stack's inputs, gives the network and its NAT, the build cache and the
# GitHub Apps' keys as designed, with no runner pool, no manager and no SSH rule (#113) and no external address (#7),
# and the settings give tacplus-ci's quotas, counting the looper VMs and the reserved machines alone (#113), and the
# apps' signers (#19): import-only keys with no version, their import jobs, the importers
# from GCP_KMS_KEY_IMPORTERS alone, the looper project's federation and each key's own signers, the manager's never a
# report. (A test sees a module's resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_active_folder" {
    defaults = { name = "folders/222" }
  }
  mock_data "google_project" {
    defaults = { billing_account = "000000-111111-222222", number = "333" }
  }
  # Computed at apply; the stub gives values of the right form.
  mock_resource "google_service_account" {
    defaults = { email = "stub-account@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:stub-account@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/stub-account@tacplus-ci.iam.gserviceaccount.com" }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-com" }
  }
}

# The parent folder, as the pipeline gives it (GCP_PARENT_FOLDER).
variables {
  parent_folder = "111111111111"
  # The looper VMs' boot image (#108), which the stack gives every run of the module as module.settings.cos_arm64_image.
  looper_vm_os_image = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
}

run "stack" {
  command = plan
  assert {
    condition     = data.google_active_folder.ci.parent == "folders/111111111111"
    error_message = "The folder ci is not looked up under the parent folder."
  }
  assert {
    condition     = output.project_id == "tacplus-ci"
    error_message = "The ci project is not tacplus-ci."
  }
  # The looper project's variables (#19): its provider and key ring, and the apps' IDs, none of them secret.
  assert {
    condition = output.looper_variables == {
      GCP_WIF_PROVIDER               = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-looper"
      LOOPER_KMS_KEYRING             = "projects/tacplus-ci/locations/us-central1/keyRings/looper"
      LOOPER_MANAGER_APP_ID          = "5632100"
      LOOPER_MANAGER_INSTALLATION_ID = "179024536"
      LOOPER_REPORT_APP_ID           = "5632122"
      LOOPER_REPORT_INSTALLATION_ID  = "179024135"
    }
    error_message = "The looper project's variables are not its provider, its key ring and the apps' IDs."
  }
  assert {
    condition     = output.app_keys == { for k in ["tacplus-reader", "tacplus-manager", "tacplus-looper", "tacplus-admiral", "tacplus-check", "tacplus-merger"] : k => "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/${k}" }
    error_message = "The stack does not give each app's key."
  }
  # The reader's account and its pools (#30): the dev project's, which plan:ci reads after apply:dev made it, and
  # tacplus-bootstrap's.
  assert {
    condition     = output.app_accounts == { fleet-seatrials-reader = "fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com" } && data.google_project.dev.project_id == "tacplus-dev"
    error_message = "The stack does not give the reader's account fleet-seatrials-reader, or does not read the dev project."
  }
  # The audit job's account (#77), the CI file's GCP_AUDIT_SA.
  assert {
    condition     = output.hub_audit == "hub-audit@tacplus-ci.iam.gserviceaccount.com"
    error_message = "The stack does not give the audit's account hub-audit."
  }
  # The release registry (#115): tacplus-dev/build's BUILD_REGISTRY for a release, the publish account and provider it
  # federates as, and its one reader, seatrials' deploy identity in the dev project.
  assert {
    condition     = output.releases.registry == "us-central1-docker.pkg.dev/tacplus-ci/releases" && output.releases.service_account == "release-publish@tacplus-ci.iam.gserviceaccount.com" && output.releases.wif_provider == "projects/333/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-build-release" && output.releases.readers == tolist(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"])
    error_message = "The stack does not give the release registry us-central1-docker.pkg.dev/tacplus-ci/releases, its publish account and provider, and seatrials-deploy@tacplus-dev as its one reader."
  }
  # The Admiral's Config (#84): the dev project's provider for its fleet kernel and its audience, its account, its
  # App's key and IDs, and its secret, none of them secret.
  assert {
    condition = output.admiral == {
      wif_provider    = "projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials"
      audience        = "//iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials"
      subject         = "spiffe://tacplus.dev/system/services/admiral"
      service_account = "admiral@tacplus-ci.iam.gserviceaccount.com"
      key             = "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-admiral"
      key_version     = "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-admiral/cryptoKeyVersions/1"
      secret          = "projects/tacplus-ci/secrets/admiral-triage-gitlab"
      app_id          = "5853599"
      installation_id = "184144753"
    }
    error_message = "The stack does not give the Admiral's Config its provider, audience, account, key, secret and App IDs."
  }
  # The looper VMs (#108): tacplus's group, which the kicker resizes, and its account.
  assert {
    # The accounts' emails are the override's below, one for every VM: the module's run checks each its own.
    condition     = { for k, g in output.looper_vms : k => [g.group, g.zone] } == { tacplus = ["looper-vm-tacplus", "us-central1-b"], tacplus-dev = ["looper-vm-tacplus-dev", "us-central1-b"] } && output.looper_vms.tacplus.service_account == "looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com"
    error_message = "The stack does not give tacplus's and the org's looper VM groups (looper-vm-tacplus, looper-vm-tacplus-dev) in us-central1-b and its account."
  }
  # The reserved machines (#111): tacplus's rolling check, the org's, and the merger's.
  assert {
    condition     = { for k, g in output.reserved_vms : k => [g.group, g.zone] } == { check-tacplus = ["check-tacplus", "us-central1-b"], check-tacplus-dev = ["check-tacplus-dev", "us-central1-b"], merger = ["merger", "us-central1-b"] }
    error_message = "The stack does not give the reserved machines' groups (check-tacplus, check-tacplus-dev, merger) in us-central1-b."
  }
  override_resource {
    target = module.ci.google_service_account.looper_vm
    values = { email = "looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com" }
  }
  # Computed at apply: the provider's name and the key ring's and keys' IDs, as Google gives them.
  override_resource {
    target = module.ci.google_service_account.admiral
    values = { email = "admiral@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:admiral@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/admiral@tacplus-ci.iam.gserviceaccount.com" }
  }
  override_resource {
    target = module.ci.google_iam_workload_identity_pool_provider.looper
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-looper" }
  }
  override_resource {
    target = module.ci.google_service_account.app
    values = { email = "fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com" }
  }
  override_resource {
    target = module.ci.google_service_account.hub_audit
    values = { email = "hub-audit@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/hub-audit@tacplus-ci.iam.gserviceaccount.com" }
  }
  override_resource {
    target = module.ci.google_kms_key_ring.looper
    values = { id = "projects/tacplus-ci/locations/us-central1/keyRings/looper" }
  }
  override_resource {
    target = module.ci.google_service_account.release_publish
    values = { email = "release-publish@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:release-publish@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/release-publish@tacplus-ci.iam.gserviceaccount.com" }
  }
  override_resource {
    target = module.ci.google_iam_workload_identity_pool_provider.release
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-build-release" }
  }
}

# tacplus-ci's quotas (#55, #63), with no runner pool and no manager since #113: what runs there at its peak is the
# looper VMs (0..1 each, C4A) and the reserved machines with an image (#111: one VM each, C4A or T2A; none without).
run "settings" {
  command = plan
  module {
    source = "../../modules/settings"
  }
  # Their CPUs fit CPUS_ALL_REGIONS and the region's C4A and T2A limits, or a VM fails QUOTA_EXCEEDED (the second build
  # VM, 2026-11-13). A c4a-standard-N or t2a-standard-N has N CPUs; a looper VM is C4A.
  assert {
    condition     = output.ci_cpus == { quota = 32, c4a_quota = 24, t2a_quota = 24 } && alltrue([for v in values(output.reserved_vms) : can(regex("^(c4a|t2a)-standard-[0-9]+$", v.machine_type))]) && sum(concat([for v in values(output.looper_vms) : tonumber(regex("^c4a-standard-([0-9]+)$", v.machine_type)[0])], [for v in values(output.reserved_vms) : v.image == "" || !startswith(v.machine_type, "c4a-") ? 0 : tonumber(regex("-([0-9]+)$", v.machine_type)[0])])) <= output.ci_cpus.c4a_quota && sum([for v in values(output.reserved_vms) : v.image == "" || !startswith(v.machine_type, "t2a-") ? 0 : tonumber(regex("-([0-9]+)$", v.machine_type)[0])]) <= output.ci_cpus.t2a_quota && sum(concat([for v in values(output.looper_vms) : tonumber(regex("-([0-9]+)$", v.machine_type)[0])], [for v in values(output.reserved_vms) : v.image == "" ? 0 : tonumber(regex("-([0-9]+)$", v.machine_type)[0])])) <= output.ci_cpus.quota
    error_message = "The looper VMs and the reserved machines with an image need more CPUs than tacplus-ci's CPUS_ALL_REGIONS (32), C4A (24) or T2A (24) quota, or a machine type is no c4a-standard-N or t2a-standard-N."
  }
  # Their boot disks fit its GB in us-central1, a C4A VM's Hyperdisk Balanced and a T2A VM's pd-balanced (SSD_TOTAL_GB),
  # or a VM fails QUOTA_EXCEEDED and never comes.
  assert {
    condition     = output.ci_disks == { hyperdisk_balanced_quota_gb = 500, ssd_total_quota_gb = 500 } && sum(concat([for v in values(output.looper_vms) : v.disk_gb], [for v in values(output.reserved_vms) : v.image == "" || !startswith(v.machine_type, "c4a-") ? 0 : v.disk_gb])) <= output.ci_disks.hyperdisk_balanced_quota_gb && sum([for v in values(output.reserved_vms) : v.image == "" || !startswith(v.machine_type, "t2a-") ? 0 : v.disk_gb]) <= output.ci_disks.ssd_total_quota_gb
    error_message = "The looper VMs' and the reserved machines' (with an image) disks need more GB than tacplus-ci's Hyperdisk Balanced (500) or SSD_TOTAL_GB (500) quota in us-central1."
  }
  # The apps Jody created on 2026-11-05 (#19), and who signs with each: the looper app for the reports, the scans, the
  # plan and the kicker; the manager app for the manager and the scans (their commits to main) alone; the reader for
  # the namespace's protected refs, as in jody1-328023, and, off jody1-328023 (#30), for the drift issues of this
  # project (its jobs through tacplus-bootstrap's pool) and of tacplus-dev/cluster (through the dev project's pool),
  # and for fleet-seatrials' jobs as fleet-seatrials-reader (through the dev project's pool, which their
  # GCP_WIF_PROVIDER is a provider of). Every key is imported.
  assert {
    condition = { for k, a in output.github_apps.apps : k => [a.app_id, a.installation_id, a.import, a.namespace, toset(a.environments), a.accounts, a.projects] } == {
      tacplus-manager = ["5632100", "179024536", true, false, toset(["looper-manager", "looper-scan"]), {}, []]
      tacplus-looper  = ["5632122", "179024135", true, false, toset(["looper-report", "looper-scan", "looper-plan", "kicker"]), {}, []]
      tacplus-reader  = ["5531358", "176655068", true, true, toset([]), { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } }, [{ pool = "bootstrap", gitlab_project = "tacplus-dev/cloud" }, { pool = "dev", gitlab_project = "tacplus-dev/cluster" }]]
      tacplus-admiral = ["5853599", "184144753", true, false, toset([]), {}, []]
      # #111: no GitLab job signs with either (their machines do), and they wait for Jody's apps and imports.
      tacplus-check  = ["", "", false, false, toset([]), {}, []]
      tacplus-merger = ["", "", false, false, toset([]), {}, []]
    }
    error_message = "The apps, their IDs or their signers are not the ones #19, #30, #84 and #111 list."
  }
  # The Admiral's (#84; tacplus-dev/admiral#5): the seatrials fleet's kernel, by its one issuer URL, for the Admiral's
  # SPIFFE ID alone; its account, its App's key (no GitLab job signs with it, above) and its secret.
  assert {
    condition     = output.admiral == { pool = "fleet-kernels", provider = "seatrials", issuer = "https://seatrials.tacplus.dev", subject = "spiffe://tacplus.dev/system/services/admiral", account_id = "admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" } && contains(keys(output.github_apps.apps), output.admiral.key)
    error_message = "The Admiral's credentials are not seatrials' kernel's provider for its SPIFFE ID, the account admiral, the key tacplus-admiral and the secret admiral-triage-gitlab."
  }
  assert {
    condition     = output.github_apps.key_ring == "looper" && output.github_apps.pool == "gitlab-loopers" && output.github_apps.looper == { project = "tacplus-dev/looper", project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" } && output.github_apps.namespace == { path = "tacplus-dev", id = "145863835", wif_provider = "gitlab-com" }
    error_message = "The apps' federation is not tacplus-dev/looper's main (88136765) and tacplus-dev's namespace (145863835), in the pool gitlab-loopers."
  }
  # The looper VMs (#108; decisions/looper-build-vms-2026-11-24.md): tacplus first, the pilot, a spot c4a-standard-8
  # with a 200 GB cache disk, with no image until tacplus-dev/looper#239 publishes it (its group stays at 0).
  assert {
    condition     = output.looper_vms == { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper@sha256:c3a8b379342d988683c777b549e57e9b57f8e81eaf1ab557158806589fc89f5b" }, tacplus-dev = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper@sha256:c3a8b379342d988683c777b549e57e9b57f8e81eaf1ab557158806589fc89f5b", org = "tacplus-dev" } }
    error_message = "The looper VMs are not tacplus's alone, a spot c4a-standard-8 with 200 GB and no image yet."
  }
  # The reserved machines (#111; decisions/agentic-dev-flow-2026-11-25.md, the panel's 4, 5 and 8, Jody's yes of
  # 2026-11-25): tacplus's rolling check (C4A, 8 CPUs until the full gates are measured on it), the org's and the
  # merger's small machine (T2A), none spot, on the looper image of main-c0d53ba (tacplus-dev/looper#249, #251), each
  # signing as tacplus-manager until tacplus-check and tacplus-merger exist (the hub, for Jody, 2026-11-25).
  assert {
    condition     = output.reserved_vms == { check-tacplus = { role = "check", repo = "tacplus", machine_type = "c4a-standard-8", disk_gb = 100, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" }, check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "t2a-standard-4", disk_gb = 100, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" }, merger = { role = "merger", org = "tacplus-dev", machine_type = "t2a-standard-1", disk_gb = 30, image = "ghcr.io/tacplus-dev/looper@sha256:c61c27e6656694aca63a70addbc3cd40ab172a9b4ea23eb579745ef68ae41246", key = "tacplus-manager" } }
    error_message = "The reserved machines are not tacplus's check (c4a-standard-8 until measured, 100 GB), the org's (t2a-standard-4, 100 GB) and the merger's (t2a-standard-1, 30 GB), on main-c0d53ba's looper image, signing as tacplus-manager."
  }
}

run "ci" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = {
      key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }
      pools    = { bootstrap = "projects/111/locations/global/workloadIdentityPools/gitlab-com", dev = "projects/444/locations/global/workloadIdentityPools/gitlab-com" }
      keys     = { tacplus-reader = { import = true, namespace = true, environments = [], accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } }, projects = [{ pool = "bootstrap", gitlab_project = "tacplus-dev/cloud" }, { pool = "dev", gitlab_project = "tacplus-dev/cluster" }] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } }
    }
    # As GCP_KMS_KEY_IMPORTERS gives it: an account of the host's directory, which no file here names.
    kms_key_importers = ["user:jody@example.com"]
    releases          = { repository = "releases", location = "us-central1", account_id = "release-publish", gitlab_project = "tacplus-dev/build", environment = "registry", wif_provider = "tacplus-dev-build-release", readers = ["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"] }
  }
  override_resource {
    target = google_service_account.release_publish
    values = { email = "release-publish@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:release-publish@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/release-publish@tacplus-ci.iam.gserviceaccount.com" }
  }
  # Computed at apply: the pool's name, as Google gives it.
  override_resource {
    target = google_iam_workload_identity_pool.loopers
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers" }
  }
  override_resource {
    target = google_service_account.app
    values = { email = "fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com" }
  }

  # NAT gives each VM ports as its jobs need them: a VM's jobs open many connections at once (2026-11-11).
  assert {
    condition     = google_compute_router_nat.runners.enable_dynamic_port_allocation && google_compute_router_nat.runners.min_ports_per_vm >= 1024 && google_compute_router_nat.runners.max_ports_per_vm >= 16384
    error_message = "The runners' NAT does not allocate ports dynamically, from at least 1024 up to 16384 a VM."
  }
  # A connection NAT drops is logged, errors only (#61): a VM's failed pull leaves a record of its cause, if NAT's.
  assert {
    condition     = google_compute_router_nat.runners.log_config[0].enable && google_compute_router_nat.runners.log_config[0].filter == "ERRORS_ONLY"
    error_message = "The runners' NAT does not log its errors."
  }
  assert {
    condition     = google_project.ci.folder_id == "folders/222" && google_project.ci.billing_account == "000000-111111-222222" && !google_project.ci.auto_create_network && google_project.ci.deletion_policy == "PREVENT"
    error_message = "The project is not in its folder, billed, without a default network and protected from deletion."
  }
  # The IAM gate waits for the pipeline's permissions in the new project before its first creates (#16).
  assert {
    condition     = terraform_data.iam_ready.input.project == "tacplus-ci" && alltrue([for x in ["iam.workloadIdentityPools.create", "cloudkms.keyRings.create"] : contains(terraform_data.iam_ready.input.permissions, x)])
    error_message = "The IAM gate does not wait for the pipeline's permissions in tacplus-ci."
  }
  # The build cache (decisions/builds-in-containers-2026-11-03.md, #5): a bucket and a Docker registry, written and
  # read only by the build identity, which only the build jobs (tacplus-dev/build's) may become, through Workload
  # Identity Federation from gitlab.com; an entry unused for 30 days is deleted.
  assert {
    condition     = google_storage_bucket.cache.name == "tacplus-ci-build-cache" && google_storage_bucket.cache.uniform_bucket_level_access && google_storage_bucket.cache.public_access_prevention == "enforced" && google_storage_bucket.cache.location == "US-CENTRAL1"
    error_message = "The cache bucket is not tacplus-ci-build-cache, uniform, private and in us-central1."
  }
  assert {
    condition     = google_artifact_registry_repository.cache.repository_id == "build-cache" && google_artifact_registry_repository.cache.format == "DOCKER" && google_artifact_registry_repository.cache.location == "us-central1"
    error_message = "The cache registry is not the Docker repository build-cache in us-central1."
  }
  assert {
    condition     = google_storage_bucket_iam_binding.cache.role == "roles/storage.objectUser" && google_storage_bucket_iam_binding.cache.members == toset([google_service_account.build_cache.member]) && google_artifact_registry_repository_iam_binding.cache.role == "roles/artifactregistry.writer" && google_artifact_registry_repository_iam_binding.cache.members == toset([google_service_account.build_cache.member])
    error_message = "The cache's write role is held by someone other than the build identity alone."
  }
  assert {
    condition     = alltrue([for m in concat(tolist(google_storage_bucket_iam_binding.cache.members), tolist(google_artifact_registry_repository_iam_binding.cache.members), [google_service_account_iam_member.build_cache_wif.member]) : !contains(["allUsers", "allAuthenticatedUsers"], m)])
    error_message = "The cache is granted to allUsers or allAuthenticatedUsers."
  }
  assert {
    condition     = google_service_account.build_cache.account_id == "build-cache" && google_iam_workload_identity_pool_provider.build.attribute_condition == "assertion.project_path == 'tacplus-dev/build'" && google_iam_workload_identity_pool_provider.build.oidc[0].issuer_uri == "https://gitlab.com" && google_iam_workload_identity_pool_provider.build.attribute_mapping["attribute.project_path"] == "assertion.project_path"
    error_message = "The build identity is not federated from tacplus-dev/build's jobs only."
  }
  assert {
    condition     = google_service_account_iam_member.build_cache_wif.role == "roles/iam.workloadIdentityUser" && google_service_account_iam_member.build_cache_wif.member == "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/build"
    error_message = "Something other than tacplus-dev/build's jobs may become the build identity."
  }
  assert {
    condition     = length(google_storage_bucket.cache.lifecycle_rule) == 1 && one(google_storage_bucket.cache.lifecycle_rule[0].condition).age == 30 && one(google_storage_bucket.cache.lifecycle_rule[0].action).type == "Delete"
    error_message = "The cache bucket does not delete an entry 30 days after it was last written."
  }
  assert {
    condition     = !google_artifact_registry_repository.cache.cleanup_policy_dry_run && length(google_artifact_registry_repository.cache.cleanup_policies) == 1 && one(google_artifact_registry_repository.cache.cleanup_policies).action == "DELETE" && one(google_artifact_registry_repository.cache.cleanup_policies).condition[0].tag_state == "ANY" && one(google_artifact_registry_repository.cache.cleanup_policies).condition[0].older_than == "2592000s"
    error_message = "The cache registry does not delete a version 30 days after it was pushed."
  }
  # The GitHub Apps' keys (#19): import-only RS256 keys with no version until their app's key is imported, software
  # (Cloud KMS's own: no external key manager holds them), in the key ring looper in us-central1. Cloud KMS never
  # exports a key's material: imported once, it never leaves.
  assert {
    condition     = toset(keys(google_kms_crypto_key.app)) == toset(["tacplus-reader", "tacplus-manager", "tacplus-looper"]) && google_kms_key_ring.looper.name == "looper" && google_kms_key_ring.looper.location == "us-central1"
    error_message = "The apps' keys are not tacplus-reader, tacplus-manager and tacplus-looper, in the key ring looper in us-central1."
  }
  assert {
    condition     = alltrue([for k in google_kms_crypto_key.app : k.import_only && k.skip_initial_version_creation && k.purpose == "ASYMMETRIC_SIGN" && k.version_template[0].algorithm == "RSA_SIGN_PKCS1_2048_SHA256" && k.version_template[0].protection_level == "SOFTWARE"])
    error_message = "An app's key has an initial version, or is not an import-only RS256 software key of Cloud KMS's own."
  }
  # One import job per key that is imported (the reader's too, since #30), RSA-OAEP-3072 wrapping, for software keys.
  assert {
    condition     = toset(keys(google_kms_key_ring_import_job.app)) == toset(["tacplus-reader", "tacplus-manager", "tacplus-looper"]) && alltrue([for k, j in google_kms_key_ring_import_job.app : j.import_job_id == "${k}-import" && j.import_method == "RSA_OAEP_3072_SHA256_AES_256" && j.protection_level == "SOFTWARE"])
    error_message = "tacplus-reader, tacplus-manager and tacplus-looper have not each their own RSA_OAEP_3072_SHA256_AES_256 import job."
  }
  # Who imports: the members of GCP_KMS_KEY_IMPORTERS alone, the importer on each import job (a binding on the key ring
  # conditioned on the import jobs' names: the provider has no import job IAM) and the versions-create permission
  # alone on each imported key.
  assert {
    condition     = google_project_iam_custom_role.key_version_importer.role_id == "kmsKeyVersionImporter" && google_project_iam_custom_role.key_version_importer.permissions == toset(["cloudkms.cryptoKeyVersions.create"])
    error_message = "The importers' role on the keys is not the versions-create permission alone."
  }
  assert {
    condition     = toset(keys(google_kms_crypto_key_iam_binding.importer)) == toset(["tacplus-reader", "tacplus-manager", "tacplus-looper"]) && alltrue([for b in google_kms_crypto_key_iam_binding.importer : b.members == toset(["user:jody@example.com"]) && b.role == "projects/tacplus-ci/roles/kmsKeyVersionImporter"])
    error_message = "The keys' versions are created by someone other than the importers, or on a key with no import job."
  }
  assert {
    condition     = length(google_kms_key_ring_iam_binding.importer) == 1 && google_kms_key_ring_iam_binding.importer[0].role == "roles/cloudkms.importer" && google_kms_key_ring_iam_binding.importer[0].members == toset(["user:jody@example.com"]) && google_kms_key_ring_iam_binding.importer[0].condition[0].expression == join(" || ", [for k in ["tacplus-looper", "tacplus-manager", "tacplus-reader"] : "resource.name == \"projects/tacplus-ci/locations/us-central1/keyRings/looper/importJobs/${k}-import\""])
    error_message = "The importer role is not the importers' alone, on the three import jobs alone."
  }
  # The looper project's federation: a pool of its own, gitlab-loopers; its provider admits tacplus-dev/looper's
  # (88136765) protected refs alone, and maps role to project_id:ref:ref_protected:environment, GitLab's word for each.
  assert {
    condition     = google_iam_workload_identity_pool.loopers.workload_identity_pool_id == "gitlab-loopers" && google_iam_workload_identity_pool_provider.looper.workload_identity_pool_provider_id == "gitlab-looper" && google_iam_workload_identity_pool_provider.looper.oidc[0].issuer_uri == "https://gitlab.com"
    error_message = "The looper project's provider is not gitlab-looper, for gitlab.com, in the pool gitlab-loopers."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.looper.attribute_condition == "assertion.project_id == \"88136765\" && assertion.ref_protected == \"true\"" && google_iam_workload_identity_pool_provider.looper.attribute_mapping == tomap({ "google.subject" = "assertion.project_id + \":\" + assertion.job_id", "attribute.role" = "assertion.project_id + \":\" + assertion.ref + \":\" + assertion.ref_protected + \":\" + assertion.environment" })
    error_message = "The looper provider admits more than tacplus-dev/looper's protected refs, or its role is not project_id:ref:ref_protected:environment."
  }
  # The namespace's provider, for the reader: tacplus-dev's (145863835) protected refs, mapping the namespace alone.
  assert {
    condition     = google_iam_workload_identity_pool_provider.namespace.workload_identity_pool_provider_id == "gitlab-com" && google_iam_workload_identity_pool_provider.namespace.attribute_condition == "assertion.namespace_id == \"145863835\" && assertion.ref_protected == \"true\"" && google_iam_workload_identity_pool_provider.namespace.attribute_mapping == tomap({ "google.subject" = "assertion.project_id + \":\" + assertion.job_id", "attribute.namespace_id" = "assertion.namespace_id" })
    error_message = "The namespace's provider admits more than tacplus-dev's protected refs, or maps more than its namespace."
  }
  # Each key's own signers, never at the key ring (no binding there but the importers'): tacplus-looper for the
  # reports, scans, plan and kicker; tacplus-manager for the manager and the scans alone, never a report; the reader
  # for the namespace's protected refs, tacplus-dev/cloud's and tacplus-dev/cluster's jobs through their pools (their
  # drift issues), and its account fleet-seatrials-reader (#30).
  assert {
    condition = { for k, b in google_kms_crypto_key_iam_binding.signer : k => b.members if b.role == "roles/cloudkms.signer" } == {
      tacplus-looper  = toset([for e in ["looper-report", "looper-scan", "looper-plan", "kicker"] : "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:${e}"])
      tacplus-manager = toset([for e in ["looper-manager", "looper-scan"] : "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:${e}"])
      tacplus-reader = toset([
        "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.namespace_id/145863835",
        "principalSet://iam.googleapis.com/projects/111/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cloud",
        "principalSet://iam.googleapis.com/projects/444/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cluster",
        "serviceAccount:fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com",
      ])
    }
    error_message = "The keys' signers are not exactly the looper's environments, the namespace, tacplus-dev/cloud, tacplus-dev/cluster and fleet-seatrials-reader the README lists."
  }
  # The reader's account (#30), in tacplus-ci: fleet-seatrials' jobs alone become it, through the dev project's pool
  # (their provider maps project_path), and it holds no role but its signer on the reader's key.
  assert {
    condition     = keys(google_service_account.app) == ["fleet-seatrials-reader"] && google_service_account.app["fleet-seatrials-reader"].account_id == "fleet-seatrials-reader" && google_service_account.app["fleet-seatrials-reader"].project == "tacplus-ci"
    error_message = "The reader's account is not fleet-seatrials-reader in tacplus-ci, or another app has one."
  }
  assert {
    condition     = google_service_account_iam_binding.app["fleet-seatrials-reader"].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_binding.app["fleet-seatrials-reader"].members == toset(["principalSet://iam.googleapis.com/projects/444/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/fleet-seatrials"]) && google_service_account_iam_binding.app["fleet-seatrials-reader"].service_account_id == google_service_account.app["fleet-seatrials-reader"].name
    error_message = "Something other than fleet-seatrials' jobs, through the dev project's pool, may become fleet-seatrials-reader."
  }
  assert {
    condition     = !contains(google_kms_crypto_key_iam_binding.signer["tacplus-manager"].members, "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:looper-report")
    error_message = "tacplus-manager signs for looper-report: a report's code could mint the bypass."
  }
  assert {
    condition     = alltrue([for k, b in google_kms_crypto_key_iam_binding.signer : b.crypto_key_id == google_kms_crypto_key.app[k].id])
    error_message = "A signer binding is not on its own key."
  }
  # hub-audit (#77): the audit job's account, which only tacplus-dev/cloud's jobs become through the bootstrap pool, and
  # its six read roles on each project, granted to its member as written out (so the plan's policy check sees it).
  assert {
    condition     = google_service_account.hub_audit.account_id == "hub-audit" && google_service_account.hub_audit.project == "tacplus-ci"
    error_message = "The audit's account is not hub-audit in tacplus-ci."
  }
  assert {
    condition     = google_service_account_iam_binding.hub_audit.role == "roles/iam.workloadIdentityUser" && google_service_account_iam_binding.hub_audit.members == toset(["principalSet://iam.googleapis.com/projects/111/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cloud"]) && google_service_account_iam_binding.hub_audit.service_account_id == google_service_account.hub_audit.name
    error_message = "Something other than tacplus-dev/cloud's jobs, through the bootstrap pool, may become hub-audit."
  }
  assert {
    condition     = { for k, m in google_project_iam_member.hub_audit : k => [m.project, m.role, m.member] } == { for g in setproduct(["tacplus-ci", "tacplus-dev"], ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"]) : "${g[0]}:${g[1]}" => [g[0], g[1], "serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com"] }
    error_message = "hub-audit does not hold exactly its six read roles on tacplus-ci and tacplus-dev."
  }
  # The registries' IAM (#115): on each project, hub-audit's own role, which lists the repositories and reads their
  # policies and nothing else (no image), granted as written out.
  assert {
    condition     = toset(keys(google_project_iam_custom_role.hub_audit_registries)) == toset(["tacplus-ci", "tacplus-dev"]) && alltrue([for k, r in google_project_iam_custom_role.hub_audit_registries : r.project == k && r.role_id == "hubAuditRegistries" && toset(r.permissions) == toset(["artifactregistry.locations.list", "artifactregistry.repositories.get", "artifactregistry.repositories.getIamPolicy", "artifactregistry.repositories.list"])])
    error_message = "hub-audit's registries role is not, on each project, list and getIamPolicy alone."
  }
  assert {
    condition     = { for k, m in google_project_iam_member.hub_audit_registries : k => [m.project, m.role, m.member, length(m.condition)] } == { for p in ["tacplus-ci", "tacplus-dev"] : p => [p, "projects/${p}/roles/hubAuditRegistries", "serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com", 0] }
    error_message = "hub-audit does not hold its registries role on each project, as written out."
  }
  # The release registry (#115): DOCKER in us, no cleanup policy (a pinned release is never deleted), labelled; one
  # writer, release-publish, which only tacplus-dev/build's protected main, in its environment registry, becomes,
  # through a provider of its own in the build cache's pool (not the build cache's, which admits any ref); one reader,
  # seatrials' deploy identity. Every binding authoritative.
  assert {
    condition     = google_artifact_registry_repository.releases[0].repository_id == "releases" && google_artifact_registry_repository.releases[0].location == "us-central1" && google_artifact_registry_repository.releases[0].format == "DOCKER" && length(google_artifact_registry_repository.releases[0].cleanup_policies) == 0 && length(google_artifact_registry_repository.releases[0].labels) == 1 && google_artifact_registry_repository.releases[0].labels["managed-by"] == "tacplus-dev-cloud"
    error_message = "The release registry is not releases, DOCKER in us-central1, labelled, with no cleanup policy."
  }
  assert {
    condition     = google_service_account.release_publish[0].account_id == "release-publish" && google_service_account.release_publish[0].project == "tacplus-ci"
    error_message = "The release publish account is not release-publish in tacplus-ci."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.release[0].workload_identity_pool_id == "gitlab-com" && google_iam_workload_identity_pool_provider.release[0].workload_identity_pool_provider_id == "tacplus-dev-build-release" && google_iam_workload_identity_pool_provider.release[0].attribute_condition == "assertion.project_path == 'tacplus-dev/build' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'" && google_iam_workload_identity_pool_provider.release[0].attribute_mapping["attribute.project_environment"] == "assertion.project_path + ':' + (has(assertion.environment) ? assertion.environment : '')" && google_iam_workload_identity_pool_provider.release[0].oidc[0].issuer_uri == "https://gitlab.com"
    error_message = "The release provider does not admit tacplus-dev/build's protected main alone, or does not map its project and environment."
  }
  assert {
    condition     = google_service_account_iam_binding.release_publish[0].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_binding.release_publish[0].members == toset(["principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-com/attribute.project_environment/tacplus-dev/build:registry"]) && google_service_account_iam_binding.release_publish[0].service_account_id == google_service_account.release_publish[0].name
    error_message = "Something other than tacplus-dev/build's jobs in its environment registry may become release-publish."
  }
  assert {
    condition     = google_artifact_registry_repository_iam_binding.releases_writer[0].role == "roles/artifactregistry.writer" && google_artifact_registry_repository_iam_binding.releases_writer[0].members == toset(["serviceAccount:release-publish@tacplus-ci.iam.gserviceaccount.com"]) && google_artifact_registry_repository_iam_binding.releases_writer[0].location == "us-central1" && google_artifact_registry_repository_iam_binding.releases_writer[0].repository == "releases"
    error_message = "The release registry's writer is not release-publish alone."
  }
  assert {
    condition     = google_artifact_registry_repository_iam_binding.releases_reader[0].role == "roles/artifactregistry.reader" && google_artifact_registry_repository_iam_binding.releases_reader[0].members == toset(["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"]) && google_artifact_registry_repository_iam_binding.releases_reader[0].location == "us-central1" && google_artifact_registry_repository_iam_binding.releases_reader[0].repository == "releases"
    error_message = "The release registry's reader is not seatrials-deploy@tacplus-dev alone."
  }
  # The cluster autoscaler's log (#85): no view and no grant on one until autoscaler_log is true, which waits for the
  # host's roles/logging.configWriter (the stack's input, modules/settings' autoscaler_log, is false).
  assert {
    condition     = length(google_logging_log_view.hub_audit_autoscaler) == 0 && length(google_project_iam_member.hub_audit_autoscaler) == 0
    error_message = "With autoscaler_log unset, the plan makes a log view or grants hub-audit viewAccessor: the host's logging.configWriter may not be in place."
  }
  # Without looper VMs (#108), no VM, no account, and no grant: the kicker resizes nothing, nobody reads the model token.
  assert {
    condition     = length(google_compute_instance_group_manager.looper_vm) == 0 && length(google_service_account.looper_vm) == 0 && length(google_project_iam_member.looper_vm_kicker) == 0 && length(google_project_iam_member.looper_vm_plan) == 0 && length(google_secret_manager_secret_iam_binding.looper_model_token) == 0
    error_message = "Without looper VMs, the plan makes one, an account, the kicker's resize or a reader of looper-model-token."
  }
}

# With autoscaler_log true (#85, Jody's option A), hub-audit reads the cluster autoscaler's log alone: on each project's
# _Default bucket the view hub-audit-autoscaler holds that log, and nothing else; and hub-audit holds
# roles/logging.viewAccessor on each project conditioned on that project's view alone, never logging.viewer (a job's
# output may hold a secret). Its six read roles are unchanged.
run "hub_audit_autoscaler_log" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud", autoscaler_log = true }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = { for k, v in google_logging_log_view.hub_audit_autoscaler : k => [v.name, v.bucket, v.filter] } == { for p in ["tacplus-ci", "tacplus-dev"] : p => ["hub-audit-autoscaler", "projects/${p}/locations/global/buckets/_Default", "LOG_ID(\"container.googleapis.com/cluster-autoscaler-visibility\")"] }
    error_message = "Each project's _Default bucket does not have the one view hub-audit-autoscaler, of the cluster autoscaler's visibility log alone."
  }
  assert {
    condition     = { for k, m in google_project_iam_member.hub_audit_autoscaler : k => [m.project, m.role, m.member, length(m.condition), m.condition[0].expression] } == { for p in ["tacplus-ci", "tacplus-dev"] : p => [p, "roles/logging.viewAccessor", "serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com", 1, "resource.name == \"projects/${p}/locations/global/buckets/_Default/views/hub-audit-autoscaler\""] }
    error_message = "hub-audit does not hold roles/logging.viewAccessor on each project conditioned on that project's view hub-audit-autoscaler alone."
  }
  assert {
    condition     = length(google_project_iam_member.hub_audit) == 12 && alltrue([for m in google_project_iam_member.hub_audit : !startswith(m.role, "roles/logging.")])
    error_message = "autoscaler_log changes hub-audit's read roles, or gives it another logging role."
  }
}

# A write role to hub-audit, the audit job's account, is refused (#77): it reads only.
run "hub_audit_write_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.admin", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.hub_audit]
}

# Only a deployment's service account reads the release registry (#115): a user, a group or anyone else is refused.
run "release_reader_not_service_account_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    releases        = { repository = "releases", location = "us-central1", account_id = "release-publish", gitlab_project = "tacplus-dev/build", environment = "registry", wif_provider = "tacplus-dev-build-release", readers = ["user:someone@example.com"] }
  }
  expect_failures = [var.releases]
}

# The release registry is in the region (#120): the host's gcp.resourceLocations, in:us-central1-locations, admits
# the region alone, and the multi-region us failed apply:ci (Error 400: Location "us" violates organization policy).
run "release_location_outside_region_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    releases        = { repository = "releases", location = "us", account_id = "release-publish", gitlab_project = "tacplus-dev/build", environment = "registry", wif_provider = "tacplus-dev-build-release", readers = ["serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com"] }
  }
  expect_failures = [var.releases]
}

# A family resolves the newest image at each VM's creation, which no commit fixes: refused, as is any image but
# Container-Optimized OS for arm64, for the looper VMs and the reserved machines.
run "family_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id         = "tacplus-ci"
    name               = "tacplus ci"
    folder             = "folders/222"
    billing_account    = "000000-111111-222222"
    region             = "us-central1"
    zone               = "us-central1-b"
    subnet_cidr        = "10.10.0.0/20"
    looper_vm_os_image = "projects/cos-cloud/global/images/family/cos-arm64-stable"
    build_cache        = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit          = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps        = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.looper_vm_os_image]
}


# Without importers (GCP_KMS_KEY_IMPORTERS unset or cleared, as a later commit does once the keys are imported),
# nobody imports: no importer binding at all, on the import jobs or the keys. The signers stay.
run "no_importers" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = length(google_kms_crypto_key_iam_binding.importer) == 0 && length(google_kms_key_ring_iam_binding.importer) == 0
    error_message = "Someone imports with no importer in GCP_KMS_KEY_IMPORTERS."
  }
  assert {
    condition     = length(google_kms_key_ring_import_job.app) == 2 && length(google_kms_crypto_key_iam_binding.signer) == 3 && length(google_service_account.app) == 0
    error_message = "Clearing the importers changed the import jobs or the signers."
  }
}

# The manager's key never signs for a report (tacplus-dev/looper#90: a report's code would mint the bypass), and an
# importer is a member as IAM writes it.
run "manager_signs_for_report_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id        = "tacplus-ci"
    name              = "tacplus ci"
    folder            = "folders/222"
    billing_account   = "000000-111111-222222"
    region            = "us-central1"
    zone              = "us-central1-b"
    subnet_cidr       = "10.10.0.0/20"
    build_cache       = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit         = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps       = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-report"] } } }
    kms_key_importers = ["jody@example.com"]
  }
  expect_failures = [var.github_apps, var.kms_key_importers]
}

# A key's account or project federates only through a pool the stack gives (#30), and an account signs for one key.
run "unknown_pool_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, pools = { dev = "projects/444/locations/global/workloadIdentityPools/gitlab-com" }, keys = { tacplus-reader = { import = true, namespace = true, environments = [], accounts = { fleet-seatrials-reader = { pool = "elsewhere", gitlab_project = "tacplus-dev/fleet-seatrials" } } }, tacplus-looper = { import = true, namespace = false, environments = [], accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } } } } }
  }
  expect_failures = [var.github_apps]
}

# The Admiral's credentials (#84; tacplus-dev/admiral#5, option A): its account, which only its SPIFFE ID, through the
# dev project's pool for its fleet kernel, becomes; its App's import-only key, imported like the others, on which it
# alone is signerVerifier; its secret, made with no version, which it alone reads and the adders alone add to.
run "admiral" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-looper = { import = true, namespace = false, environments = ["looper-report"] }, tacplus-admiral = { import = true, namespace = false, environments = [] } } }
    # As GCP_KMS_KEY_IMPORTERS and GCP_ADMIRAL_SECRET_ADDERS give them: accounts of the host's directory.
    kms_key_importers     = ["user:jody@example.com"]
    admiral               = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://tacplus.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
    admiral_secret_adders = ["user:jody@example.com"]
  }
  override_resource {
    target = google_service_account.admiral
    values = { email = "admiral@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:admiral@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/admiral@tacplus-ci.iam.gserviceaccount.com" }
  }
  override_resource {
    target = google_kms_key_ring.looper
    values = { id = "projects/tacplus-ci/locations/us-central1/keyRings/looper" }
  }
  assert {
    condition     = google_service_account.admiral["admiral"].account_id == "admiral" && google_service_account.admiral["admiral"].project == "tacplus-ci"
    error_message = "The Admiral's account is not admiral in tacplus-ci."
  }
  assert {
    condition     = google_service_account_iam_binding.admiral["admiral"].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_binding.admiral["admiral"].members == toset(["principal://iam.googleapis.com/projects/444/locations/global/workloadIdentityPools/fleet-kernels/subject/spiffe://tacplus.dev/system/services/admiral"])
    error_message = "Someone besides the Admiral's SPIFFE ID, through the fleet kernels' pool, becomes its account."
  }
  # Its key is an app's like the others: import-only, no version, imported through its own job by the importers.
  assert {
    condition     = google_kms_crypto_key.app["tacplus-admiral"].import_only && google_kms_crypto_key.app["tacplus-admiral"].skip_initial_version_creation && google_kms_crypto_key.app["tacplus-admiral"].purpose == "ASYMMETRIC_SIGN" && google_kms_crypto_key.app["tacplus-admiral"].version_template[0].algorithm == "RSA_SIGN_PKCS1_2048_SHA256" && google_kms_key_ring_import_job.app["tacplus-admiral"].import_job_id == "tacplus-admiral-import" && google_kms_crypto_key_iam_binding.importer["tacplus-admiral"].members == toset(["user:jody@example.com"])
    error_message = "The Admiral's key is not an import-only RSA 2048 signing key with no version, imported through tacplus-admiral-import by the importers."
  }
  assert {
    condition     = google_kms_crypto_key_iam_binding.admiral["admiral"].role == "roles/cloudkms.signerVerifier" && google_kms_crypto_key_iam_binding.admiral["admiral"].members == toset(["serviceAccount:admiral@tacplus-ci.iam.gserviceaccount.com"]) && !contains(keys(google_kms_crypto_key_iam_binding.signer), "tacplus-admiral")
    error_message = "Someone besides the Admiral's account signs with its key, or it does not."
  }
  assert {
    condition     = google_secret_manager_secret.admiral["admiral"].secret_id == "admiral-triage-gitlab" && google_secret_manager_secret.admiral["admiral"].project == "tacplus-ci" && google_secret_manager_secret.admiral["admiral"].replication[0].user_managed[0].replicas[0].location == "us-central1" && length(google_secret_manager_secret.admiral["admiral"].replication[0].user_managed[0].replicas) == 1
    error_message = "The Admiral's secret is not admiral-triage-gitlab in tacplus-ci, in us-central1 alone."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_binding.admiral)) == toset(["roles/secretmanager.secretAccessor", "roles/secretmanager.secretVersionAdder"]) && google_secret_manager_secret_iam_binding.admiral["roles/secretmanager.secretAccessor"].members == toset(["serviceAccount:admiral@tacplus-ci.iam.gserviceaccount.com"]) && google_secret_manager_secret_iam_binding.admiral["roles/secretmanager.secretVersionAdder"].members == toset(["user:jody@example.com"])
    error_message = "Someone besides the Admiral's account reads its secret, or besides the adders adds its versions."
  }
  assert {
    condition = output.admiral == {
      service_account = "admiral@tacplus-ci.iam.gserviceaccount.com"
      key             = "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-admiral"
      key_version     = "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-admiral/cryptoKeyVersions/1"
      secret          = "projects/tacplus-ci/secrets/admiral-triage-gitlab"
    }
    error_message = "The module does not give the Admiral's account, key, key version and secret."
  }
}

# Without adders (GCP_ADMIRAL_SECRET_ADDERS unset or cleared), nobody adds the secret's versions: no binding of the
# role. The reader stays. Without admiral, nothing of it.
run "admiral_without_adders" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-admiral = { import = true, namespace = false, environments = [] } } }
    admiral         = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://tacplus.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
  }
  assert {
    condition     = keys(google_secret_manager_secret_iam_binding.admiral) == ["roles/secretmanager.secretAccessor"] && google_secret_manager_secret_iam_binding.admiral["roles/secretmanager.secretAccessor"].members == toset(["serviceAccount:admiral@tacplus-ci.iam.gserviceaccount.com"])
    error_message = "Without adders, someone adds the Admiral's secret's versions, or its account does not read it."
  }
}

# The Admiral alone signs with its key: a github_apps signer on it is refused, and a key that is not one of the apps'.
run "admiral_other_signer_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-admiral = { import = true, namespace = false, environments = ["looper-report"] } } }
    admiral         = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://tacplus.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
  }
  expect_failures = [google_kms_crypto_key_iam_binding.admiral]
}

run "admiral_unknown_key_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-looper = { import = true, namespace = false, environments = ["looper-report"] } } }
    admiral         = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://tacplus.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
  }
  expect_failures = [var.admiral]
}

# The looper VMs (#108; tacplus-dev/roadmap decisions/looper-build-vms-2026-11-24.md): per project a zonal group of
# 0..1 C4A VMs on the pinned Container-Optimized OS, spot or not, with no external address and no SSH in any form, its
# one generic cloud-init and its project, image and group as metadata alone; its own account, which writes logs,
# reads looper-model-token and no other secret, signs with the reports' key (never the manager's) and resizes its own
# group alone; and the kicker, which resizes the looper VMs' groups alone.
run "looper_vms" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms = {
      tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper/looper-vm@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
      small   = { machine_type = "c4a-standard-2", disk_gb = 50, spot = false, image = "", org = "tacplus-dev" }
    }
  }
  override_resource {
    target = google_iam_workload_identity_pool.loopers
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers" }
  }
  assert {
    condition     = { for k, a in google_service_account.looper_vm : k => [a.account_id, a.project] } == { tacplus = ["looper-vm-tacplus", "tacplus-ci"], small = ["looper-vm-small", "tacplus-ci"] }
    error_message = "Each looper VM does not run as its own account, looper-vm-<name>, in tacplus-ci."
  }
  # Arm64 C4A on the pinned COS, Hyperdisk Balanced (C4A has no pd-*), the spec's size; on the runners' subnet with no
  # external address (NAT only); tagged looper-vm, which no firewall rule targets.
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.looper_vm : t.disk[0].source_image == "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12" && t.disk[0].disk_type == "hyperdisk-balanced" && t.disk[0].boot && t.disk[0].auto_delete && length(t.network_interface) == 1 && length(t.network_interface[0].access_config) == 0 && length(t.network_interface[0].ipv6_access_config) == 0 && t.tags == toset(["looper-vm"]) && t.labels == tomap({ managed-by = "tacplus-dev-cloud", looper-vm = k })]) && google_compute_instance_template.looper_vm["tacplus"].machine_type == "c4a-standard-8" && google_compute_instance_template.looper_vm["tacplus"].disk[0].disk_size_gb == 200 && google_compute_instance_template.looper_vm["small"].disk[0].disk_size_gb == 50
    error_message = "A looper VM is not its C4A machine on the pinned Container-Optimized OS with its Hyperdisk Balanced disk, or has an external address."
  }
  assert {
    condition     = google_compute_instance_template.looper_vm["tacplus"].scheduling[0].provisioning_model == "SPOT" && google_compute_instance_template.looper_vm["tacplus"].scheduling[0].preemptible && google_compute_instance_template.looper_vm["tacplus"].scheduling[0].instance_termination_action == "STOP" && !google_compute_instance_template.looper_vm["tacplus"].scheduling[0].automatic_restart && google_compute_instance_template.looper_vm["tacplus"].scheduling[0].on_host_maintenance == "TERMINATE"
    error_message = "A spot looper VM is not SPOT, stopped when reclaimed (its group recreates it), with no automatic restart."
  }
  assert {
    condition     = google_compute_instance_template.looper_vm["small"].scheduling[0].provisioning_model == "STANDARD" && !google_compute_instance_template.looper_vm["small"].scheduling[0].preemptible
    error_message = "A looper VM that is not spot is not STANDARD."
  }
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.looper_vm : length(t.service_account) == 1 && length(one(t.service_account).scopes) == 1 && endswith(one(one(t.service_account).scopes), "cloud-platform")])
    error_message = "A looper VM does not run as its account with the cloud-platform scope."
  }
  # No SSH in any form: no key in the metadata, the project's keys blocked. The metadata is the project, its image
  # (none: nothing runs), its group, the one cloud-init, logging on and no OS update: no secret.
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.looper_vm : !contains(keys(t.metadata), "ssh-keys") && !contains(keys(t.metadata), "sshKeys") && t.metadata["block-project-ssh-keys"] == "true" && join(" ", sort(keys(t.metadata))) == "block-project-ssh-keys cos-update-strategy google-logging-enabled looper-except looper-group looper-image looper-org looper-repo user-data" && t.metadata["looper-group"] == "projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/looper-vm-${k}" && t.metadata["google-logging-enabled"] == "true" && t.metadata["cos-update-strategy"] == "update_disabled"]) && google_compute_instance_template.looper_vm["tacplus"].metadata["looper-image"] == "ghcr.io/tacplus-dev/looper/looper-vm@sha256:1111111111111111111111111111111111111111111111111111111111111111" && google_compute_instance_template.looper_vm["small"].metadata["looper-image"] == "" && [for k in ["tacplus", "small"] : [for m in ["looper-repo", "looper-org", "looper-except"] : google_compute_instance_template.looper_vm[k].metadata[m]]] == [["tacplus", "", ""], ["", "tacplus-dev", "tacplus"]]
    error_message = "A looper VM's metadata has an SSH key, does not block the project's, or holds more than its project, image, group, cloud-init and logging."
  }
  # One cloud-init for every project: the script, and the unit that runs it (an idle exit not restarted, a stop given
  # 30 s), the same text whatever the project.
  assert {
    condition     = google_compute_instance_template.looper_vm["tacplus"].metadata["user-data"] == google_compute_instance_template.looper_vm["small"].metadata["user-data"] && startswith(google_compute_instance_template.looper_vm["tacplus"].metadata["user-data"], "#cloud-config\n") && alltrue([for l in split("\n", trimspace(file("../../modules/projects/ci/files/looper-vm.sh"))) : strcontains(google_compute_instance_template.looper_vm["tacplus"].metadata["user-data"], l)]) && alltrue([for l in ["Restart=on-failure", "TimeoutStopSec=30", "ExecStart=/bin/bash /etc/looper-vm/looper-vm.sh run", "ExecStop=/bin/bash /etc/looper-vm/looper-vm.sh stop", "ExecStopPost=/bin/bash /etc/looper-vm/looper-vm.sh post"] : strcontains(google_compute_instance_template.looper_vm["tacplus"].metadata["user-data"], "      ${l}\n")])
    error_message = "A looper VM's cloud-init is not the one generic script and its unit."
  }
  # Sized by the kicker and the VM, never by a plan: at 0, replaced with no surge on a template change.
  assert {
    condition     = alltrue([for k, g in google_compute_instance_group_manager.looper_vm : g.name == "looper-vm-${k}" && g.base_instance_name == "looper-vm-${k}" && g.zone == "us-central1-b" && g.target_size == 0 && length(g.update_policy) == 1 && g.update_policy[0].type == "PROACTIVE" && g.update_policy[0].minimal_action == "REPLACE" && g.update_policy[0].max_surge_fixed == 0 && g.update_policy[0].max_unavailable_fixed == 1])
    error_message = "A looper VM's group is not looper-vm-<name> in the stack's zone, at 0, replacing its VM with no surge."
  }
  # Each account signs with the reports' key (tacplus-looper), never the manager's; the key's other signers stay.
  assert {
    condition     = google_kms_crypto_key_iam_binding.signer["tacplus-looper"].members == toset(concat([for e in ["kicker", "looper-plan", "looper-report", "looper-scan"] : "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:${e}"], ["serviceAccount:looper-vm-small@tacplus-ci.iam.gserviceaccount.com", "serviceAccount:looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com"]))
    error_message = "The looper VMs' accounts do not sign with tacplus-looper's key, or its other signers changed."
  }
  assert {
    condition     = !anytrue([for m in google_kms_crypto_key_iam_binding.signer["tacplus-manager"].members : startswith(m, "serviceAccount:looper-vm-")])
    error_message = "A looper VM's account signs with tacplus-manager's key: its code would mint the bypass of main's ruleset."
  }
  # The model token: looper-model-token, no version here, read by the looper VMs' accounts alone, and no adder.
  assert {
    condition     = google_secret_manager_secret.looper_model_token.secret_id == "looper-model-token" && google_secret_manager_secret.looper_model_token.replication[0].user_managed[0].replicas[0].location == "us-central1" && length(google_secret_manager_secret_iam_binding.looper_model_token) == 1 && google_secret_manager_secret_iam_binding.looper_model_token[0].role == "roles/secretmanager.secretAccessor" && google_secret_manager_secret_iam_binding.looper_model_token[0].members == toset(["serviceAccount:looper-vm-small@tacplus-ci.iam.gserviceaccount.com", "serviceAccount:looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com"])
    error_message = "looper-model-token is read by someone besides the looper VMs' accounts, or has another binding."
  }
  # Its one adder (#108): the looper project's job in environment looper-vm-secret, nobody else.
  assert {
    condition     = length(google_secret_manager_secret_iam_binding.looper_model_token_adder) == 1 && google_secret_manager_secret_iam_binding.looper_model_token_adder[0].role == "roles/secretmanager.secretVersionAdder" && length(google_secret_manager_secret_iam_binding.looper_model_token_adder[0].members) == 1 && endswith(one(google_secret_manager_secret_iam_binding.looper_model_token_adder[0].members), ":main:true:looper-vm-secret")
    error_message = "looper-model-token's versions are added by someone besides the looper project's looper-vm-secret job."
  }
  # Its project roles: logWriter, and the resize of its own group alone.
  assert {
    condition     = { for k, m in google_project_iam_member.looper_vm_log : k => [m.role, m.member] } == { for k in ["small", "tacplus"] : k => ["roles/logging.logWriter", "serviceAccount:looper-vm-${k}@tacplus-ci.iam.gserviceaccount.com"] }
    error_message = "A looper VM's account does not write logs, or holds another role."
  }
  assert {
    condition     = google_project_iam_custom_role.looper_vm_resizer.role_id == "looperVmResizer" && google_project_iam_custom_role.looper_vm_resizer.permissions == toset(["compute.instanceGroupManagers.get", "compute.instanceGroupManagers.update"])
    error_message = "The looper VMs' resize role is more than an instance group's get and update."
  }
  assert {
    condition     = { for k, m in google_project_iam_member.looper_vm_self_stop : k => [m.role, m.member, m.condition[0].expression] } == { for k in ["small", "tacplus"] : k => ["projects/tacplus-ci/roles/looperVmResizer", "serviceAccount:looper-vm-${k}@tacplus-ci.iam.gserviceaccount.com", "resource.name == \"projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/looper-vm-${k}\""] }
    error_message = "A looper VM's account resizes something other than its own group."
  }
  # The kicker (tacplus-dev/looper#241): the looper project's jobs of its environment kicker, on the looper VMs' groups
  # alone; nobody else but each VM on its own group holds the role.
  assert {
    condition     = length(google_project_iam_member.looper_vm_kicker) == 1 && google_project_iam_member.looper_vm_kicker[0].role == "projects/tacplus-ci/roles/looperVmResizer" && google_project_iam_member.looper_vm_kicker[0].member == "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:kicker" && google_project_iam_member.looper_vm_kicker[0].condition[0].expression == "resource.name.startsWith(\"projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/looper-vm-\")"
    error_message = "The kicker does not resize the looper VMs' groups, or resizes more."
  }
  # The plan's identity too (looper#241), on the same groups alone.
  assert {
    condition     = length(google_project_iam_member.looper_vm_plan) == 1 && google_project_iam_member.looper_vm_plan[0].role == "projects/tacplus-ci/roles/looperVmResizer" && endswith(google_project_iam_member.looper_vm_plan[0].member, ":main:true:looper-plan") && google_project_iam_member.looper_vm_plan[0].condition[0].expression == google_project_iam_member.looper_vm_kicker[0].condition[0].expression
    error_message = "The plan cannot read or start the looper VMs' groups, or can reach more than them."
  }
  assert {
    condition     = alltrue([for m in concat(values(google_project_iam_member.hub_audit), values(google_project_iam_member.looper_vm_log)) : !strcontains(m.role, "looperVmResizer")])
    error_message = "Someone besides the kicker and each looper VM holds the looper VMs' resize role."
  }
  assert {
    condition     = { for k, g in output.looper_vms : k => [g.group, g.zone] } == { small = ["looper-vm-small", "us-central1-b"], tacplus = ["looper-vm-tacplus", "us-central1-b"] }
    error_message = "The module does not give each looper VM's group and zone."
  }
}

# The looper VMs never sign with the manager's key (tacplus-dev/looper#90): their code runs on the VM.
run "looper_vm_manager_key_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    # The manager's key, which a looper VM's account would sign with.
    looper_vms        = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    looper_vm_app_key = "tacplus-manager"
  }
  expect_failures = [var.looper_vm_app_key]
}

# A looper VM's image is pinned by digest, and its machine is C4A (arm64, Hyperdisk Balanced).
run "looper_vm_unpinned_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper/looper-vm:1.0" } }
  }
  expect_failures = [var.looper_vms]
}

run "looper_vm_not_c4a_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms      = { tacplus = { machine_type = "t2a-standard-8", disk_gb = 200, spot = true, image = "" } }
  }
  expect_failures = [var.looper_vms]
}

# The reserved machines (#111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md, the panel's 4, 5 and 8):
# the rolling check of tacplus, the org's, and the merger's machine, each a zonal group of one on-demand VM (C4A on
# Hyperdisk Balanced, T2A on pd-balanced), on the looper VMs' OS and cloud-init with its role, group, app and (the
# merger's) check machines as metadata, no external address and no SSH; its own account, which writes logs and signs
# as tacplus-manager beside the managers' jobs and no looper VM. A check machine's group is 0..1, never the plan's: its
# VM stops itself through it, and the merger's machine starts it; the merger's is at 1 with an image.
run "reserved_vms" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-8", disk_gb = 100, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-manager", app_id = "5632100", installation_id = "179024536" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "t2a-standard-4", disk_gb = 100, image = "", key = "tacplus-manager", app_id = "5632100", installation_id = "179024536" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "t2a-standard-1", disk_gb = 30, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-manager", app_id = "5632100", installation_id = "179024536" }
    }
  }
  override_resource {
    target = google_iam_workload_identity_pool.loopers
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers" }
  }
  assert {
    condition     = { for k, a in google_service_account.reserved_vm : k => [a.account_id, a.project] } == { check-tacplus = ["check-tacplus", "tacplus-ci"], check-tacplus-dev = ["check-tacplus-dev", "tacplus-ci"], merger = ["merger", "tacplus-ci"] }
    error_message = "Each reserved machine does not run as its own account, <name>, in tacplus-ci."
  }
  # Never spot (the panel's 8): on demand, restarted after a host event.
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.reserved_vm : t.scheduling[0].provisioning_model == "STANDARD" && !t.scheduling[0].preemptible && t.scheduling[0].automatic_restart])
    error_message = "A reserved machine is spot, or is not restarted after a host event."
  }
  # The looper VMs' OS, its family's disk (C4A Hyperdisk Balanced, T2A pd-balanced), no external address, tagged
  # looper-vm (no SSH in any form, ci/policy.sh).
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.reserved_vm : t.disk[0].source_image == "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12" && t.disk[0].boot && t.disk[0].auto_delete && length(t.network_interface) == 1 && length(t.network_interface[0].access_config) == 0 && length(t.network_interface[0].ipv6_access_config) == 0 && t.tags == toset(["looper-vm"]) && t.labels == tomap({ managed-by = "tacplus-dev-cloud", reserved-vm = k }) && length(t.service_account) == 1 && endswith(one(one(t.service_account).scopes), "cloud-platform")]) && { for k, t in google_compute_instance_template.reserved_vm : k => [t.machine_type, t.disk[0].disk_type, t.disk[0].disk_size_gb] } == { check-tacplus = ["c4a-standard-8", "hyperdisk-balanced", 100], check-tacplus-dev = ["t2a-standard-4", "pd-balanced", 100], merger = ["t2a-standard-1", "pd-balanced", 30] }
    error_message = "A reserved machine is not its machine on the pinned Container-Optimized OS with its family's disk (C4A Hyperdisk Balanced, T2A pd-balanced), has an external address, or is not tagged looper-vm."
  }
  # Its role, repository or org, image, group and settings as metadata alone, the looper VMs' cloud-init, no SSH key;
  # the org's check leaves the repositories with a check of their own; the merger's names the check machines it starts.
  assert {
    condition     = alltrue([for k, t in google_compute_instance_template.reserved_vm : join(" ", sort(keys(t.metadata))) == "block-project-ssh-keys cos-update-strategy google-logging-enabled looper-checks looper-env looper-except looper-group looper-image looper-org looper-repo looper-role user-data" && t.metadata["block-project-ssh-keys"] == "true" && t.metadata["google-logging-enabled"] == "true" && t.metadata["cos-update-strategy"] == "update_disabled" && t.metadata["user-data"] == google_compute_instance_template.looper_vm["tacplus"].metadata["user-data"] && t.metadata["looper-group"] == "projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/${k}"]) && [for k in ["check-tacplus", "check-tacplus-dev", "merger"] : [for m in ["looper-role", "looper-repo", "looper-org", "looper-except", "looper-image", "looper-checks"] : google_compute_instance_template.reserved_vm[k].metadata[m]]] == [["check", "tacplus", "", "", "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", ""], ["check", "", "tacplus-dev", "tacplus", "", ""], ["merger", "", "tacplus-dev", "", "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", "projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus --repo tacplus\nprojects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus-dev --org tacplus-dev --except tacplus"]]
    error_message = "A reserved machine's metadata is not its role, repository or org, image, group, the looper VMs' cloud-init and logging, or the merger's check machines, or it has an SSH key."
  }
  # Its container's settings: the key ring and its app's IDs, as looper-token's role reads them; the merger's gate trusts
  # the checks' login.
  assert {
    condition     = { for k, t in google_compute_instance_template.reserved_vm : k => t.metadata["looper-env"] } == { check-tacplus = "LOOPER_KMS_KEYRING=projects/tacplus-ci/locations/us-central1/keyRings/looper\nLOOPER_MANAGER_APP_ID=5632100\nLOOPER_MANAGER_INSTALLATION_ID=179024536", check-tacplus-dev = "LOOPER_KMS_KEYRING=projects/tacplus-ci/locations/us-central1/keyRings/looper\nLOOPER_MANAGER_APP_ID=5632100\nLOOPER_MANAGER_INSTALLATION_ID=179024536", merger = "LOOPER_CHECK_LOGIN=tacplus-manager[bot]\nLOOPER_KMS_KEYRING=projects/tacplus-ci/locations/us-central1/keyRings/looper\nLOOPER_MERGER_APP_ID=5632100\nLOOPER_MERGER_INSTALLATION_ID=179024536\nLOOPER_MERGER_KEY=tacplus-manager\nLOOPER_ORG=tacplus-dev" }
    error_message = "A reserved machine's looper-env is not the key ring and its app's IDs (the merger's with the checks' login)."
  }
  # The merger's group is at 1 with an image (0 without), the plan's; a check machine's is 0..1, never the plan's, its
  # stopped VM a manual standby; each replaces its VM with no surge.
  assert {
    condition     = { for k, g in google_compute_instance_group_manager.reserved_vm : k => [g.name, g.base_instance_name, g.zone, g.target_size] } == { merger = ["merger", "merger", "us-central1-b", 1] } && { for k, g in google_compute_instance_group_manager.reserved_vm_check : k => [g.name, g.base_instance_name, g.zone, g.target_size, g.target_stopped_size, g.standby_policy[0].mode] } == { check-tacplus = ["check-tacplus", "check-tacplus", "us-central1-b", 0, 0, "MANUAL"], check-tacplus-dev = ["check-tacplus-dev", "check-tacplus-dev", "us-central1-b", 0, 0, "MANUAL"] } && alltrue([for g in concat(values(google_compute_instance_group_manager.reserved_vm), values(google_compute_instance_group_manager.reserved_vm_check)) : g.update_policy[0].minimal_action == "REPLACE" && g.update_policy[0].max_surge_fixed == 0])
    error_message = "The merger's group is not at 1 with an image, a check machine's not a manual standby group created at 0, or one does not replace its VM with no surge."
  }
  # Until tacplus-check and tacplus-merger exist, all three sign as tacplus-manager beside the managers' jobs, and no
  # looper VM does (the hub, for Jody, 2026-11-25); the two apps' keys have no signer yet.
  assert {
    condition     = google_kms_crypto_key_iam_binding.signer["tacplus-manager"].members == toset(["principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:looper-manager", "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:looper-scan", "serviceAccount:check-tacplus-dev@tacplus-ci.iam.gserviceaccount.com", "serviceAccount:check-tacplus@tacplus-ci.iam.gserviceaccount.com", "serviceAccount:merger@tacplus-ci.iam.gserviceaccount.com"]) && !contains(keys(google_kms_crypto_key_iam_binding.signer), "tacplus-check") && !contains(keys(google_kms_crypto_key_iam_binding.signer), "tacplus-merger")
    error_message = "tacplus-manager is not signed by the managers' jobs and the three reserved machines alone, or tacplus-check or tacplus-merger has a signer."
  }
  assert {
    condition     = !anytrue([for m in google_kms_crypto_key_iam_binding.signer["tacplus-manager"].members : startswith(m, "serviceAccount:looper-vm-")]) && !anytrue([for m in google_kms_crypto_key_iam_binding.signer["tacplus-looper"].members : contains([for k in ["check-tacplus", "check-tacplus-dev", "merger"] : "serviceAccount:${k}@tacplus-ci.iam.gserviceaccount.com"], m)])
    error_message = "A looper VM's account signs with the manager's key, or a reserved machine's with the reports'."
  }
  # It writes logs; a check machine stops its own group's VM, the merger's starts the check machines' (the resizer
  # role, on those groups alone); none reads the model token.
  assert {
    condition     = { for k, m in google_project_iam_member.reserved_vm_log : k => [m.role, m.member] } == { for k in ["check-tacplus", "check-tacplus-dev", "merger"] : k => ["roles/logging.logWriter", "serviceAccount:${k}@tacplus-ci.iam.gserviceaccount.com"] } && google_secret_manager_secret_iam_binding.looper_model_token[0].members == toset(["serviceAccount:looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com"])
    error_message = "A reserved machine's account does not write logs, or reads looper-model-token."
  }
  assert {
    condition     = { for k, m in google_project_iam_member.reserved_vm_self_stop : k => [m.role, m.member, m.condition[0].expression] } == { for k in ["check-tacplus", "check-tacplus-dev"] : k => ["projects/tacplus-ci/roles/looperVmResizer", "serviceAccount:${k}@tacplus-ci.iam.gserviceaccount.com", "resource.name == \"projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/${k}\""] } && { for k, m in google_project_iam_member.reserved_vm_kick : k => [m.role, m.member, m.condition[0].expression] } == { merger = ["projects/tacplus-ci/roles/looperVmResizer", "serviceAccount:merger@tacplus-ci.iam.gserviceaccount.com", "resource.name == \"projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus\" || resource.name == \"projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus-dev\""] }
    error_message = "A check machine's account resizes more than its own group, or the merger's more than the check machines' groups."
  }
  assert {
    condition     = { for k, g in output.reserved_vms : k => [g.group, g.zone] } == { check-tacplus = ["check-tacplus", "us-central1-b"], check-tacplus-dev = ["check-tacplus-dev", "us-central1-b"], merger = ["merger", "us-central1-b"] }
    error_message = "The module does not give each reserved machine's group and zone."
  }
}

# The merger's key is the merger's machine's alone: a GitLab job that signs with it too is refused.
run "reserved_vm_merger_key_shared_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = ["looper-manager"] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-check" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}

# A reserved machine never signs with the reports' key: a report would mint the rolling check's status.
run "reserved_vm_reports_key_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-looper" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}

# The checks share one key, the login the merger's gate trusts; nor does a check share the merger's own key.
run "reserved_vm_check_keys_differ_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-manager" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}

run "reserved_vm_check_merger_key_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-merger" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}

# A reserved machine serves a repository or an org, not both, in a role it knows, on C4A.
run "reserved_vm_repo_and_org_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", org = "tacplus-dev", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-check" }
      merger            = { role = "merger", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}

run "reserved_vm_role_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id      = "tacplus-ci"
    name            = "tacplus ci"
    folder          = "folders/222"
    billing_account = "000000-111111-222222"
    region          = "us-central1"
    zone            = "us-central1-b"
    subnet_cidr     = "10.10.0.0/20"
    build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit       = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps     = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] }, tacplus-check = { import = false, namespace = false, environments = [] }, tacplus-merger = { import = false, namespace = false, environments = [] } } }
    looper_vms      = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "" } }
    reserved_vms = {
      check-tacplus     = { role = "check", repo = "tacplus", machine_type = "c4a-standard-16", disk_gb = 200, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-check", app_id = "1", installation_id = "2" }
      check-tacplus-dev = { role = "check", org = "tacplus-dev", machine_type = "c4a-standard-4", disk_gb = 200, image = "", key = "tacplus-check" }
      merger            = { role = "build", org = "tacplus-dev", machine_type = "c4a-standard-1", disk_gb = 10, image = "ghcr.io/tacplus-dev/looper@sha256:2222222222222222222222222222222222222222222222222222222222222222", key = "tacplus-merger", app_id = "1", installation_id = "2" }
    }
  }
  expect_failures = [var.reserved_vms]
}
