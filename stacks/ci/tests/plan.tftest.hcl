# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci stack's plan under a stub parent folder, with an empty project (mock providers: no credentials, no cloud):
# the stack plans, and its module, with the stack's inputs, gives the runners, the buckets and the GitHub Apps' keys as
# designed, with no SSH but the runners' internal rule and no external address (#7), and the settings give the pools
# Jody decided (#5) and the apps' signers (#19): import-only keys with no version, their import jobs, the importers
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
  assert {
    condition     = toset(keys(output.runner_token_secrets)) == toset(["shared", "build", "deploy", "cluster"])
    error_message = "Not every runner pool has its token secret."
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
    condition     = output.app_keys == { for k in ["tacplus-reader", "tacplus-manager", "tacplus-looper", "tacplus-admiral"] : k => "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/${k}" }
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
  # The Admiral's Config (#84): the dev project's provider for its fleet kernel and its audience, its account, its
  # App's key and IDs, and its secret, none of them secret.
  assert {
    condition = output.admiral == {
      wif_provider    = "projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials"
      audience        = "//iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials"
      subject         = "spiffe://local.dev/system/services/admiral"
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
    condition     = output.looper_vms == { tacplus = { group = "looper-vm-tacplus", zone = "us-central1-b", service_account = "looper-vm-tacplus@tacplus-ci.iam.gserviceaccount.com" } }
    error_message = "The stack does not give tacplus's looper VM group looper-vm-tacplus in us-central1-b and its account."
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
}

# The pools Jody decided (#5): one shared pool, always on (one VM, kept idle, never more without a commit on his
# word), for agent, build and control jobs, a tacplus-dev group runner not protected, under the tags today's jobs
# carry; deploy and cluster their own protected pools, on demand, so their credentials never share a VM with agents.
# Every pool runs more than one job per VM, each limited, and none has an account on its VMs but none needs one.
run "settings" {
  command = plan
  module {
    source = "../../modules/settings"
  }
  assert {
    condition     = toset(keys(output.runner_pools)) == toset(["shared", "build", "deploy", "cluster"])
    error_message = "The pools are not shared, build, deploy and cluster."
  }
  assert {
    condition     = output.runner_pools.shared.machine_type == "t2a-standard-8" && output.runner_pools.shared.capacity == 13 && output.runner_pools.shared.idle_count == 1 && output.runner_pools.shared.max_instances == 2
    error_message = "The shared pool is not one always-on t2a-standard-8 and a second on demand (13 jobs a VM, #63; Jody 2026-11-14)."
  }
  # A full shared VM queues its jobs, it does not fail them (#63): on 2026-11-15 its 350 GB pd-standard disk (525
  # write IOPS, 42 MiB/s, shared by 24 jobs and Docker) stopped Docker answering containers/create within 120 s, and
  # every job placed on the VM failed runner_system_failure for hours while the VM's memory sat idle. The pool's disk
  # is pd-balanced (3000 IOPS and 140 MiB/s from its first GB), sized for its jobs under the SSD quota (below).
  assert {
    condition     = output.runner_pools.shared.disk_type == "pd-balanced" && output.runner_pools.shared.job.disk_gb == 8 && output.runner_pools.shared.os_disk_gb == 50
    error_message = "The shared pool's disk is not pd-balanced, 8 GB a job and 50 GB for the OS and the images (#63: a pd-standard disk shared by its jobs stalled Docker, and every job placed on the full VM failed)."
  }
  # Every pool at its peak fits tacplus-ci's CPU quota (#55): each pool's max_instances VMs, and two managers (a
  # handoff), never more CPUs than CPUS_ALL_REGIONS, or a pool's VM fails QUOTA_EXCEEDED (the second build VM,
  # 2026-11-13). A t2a-standard-N has N CPUs.
  assert {
    condition     = output.ci_cpus.quota == 32 && output.ci_cpus.managers == 2 && sum(concat([for p in values(output.runner_pools) : p.max_instances * tonumber(regex("^t2a-standard-([0-9]+)$", p.machine_type)[0])], [output.ci_cpus.managers * tonumber(regex("^t2a-standard-([0-9]+)$", output.ci_cpus.manager_machine_type)[0])])) <= output.ci_cpus.quota
    error_message = "The pools' VMs at their max_instances and two managers need more CPUs than tacplus-ci's CPUS_ALL_REGIONS quota (32), or a machine type is no t2a-standard-N."
  }
  # Every pool's SSD-backed disks at its peak fit tacplus-ci's SSD quota (#63): each pool on pd-balanced, pd-ssd or
  # pd-extreme, its max_instances VMs' disks (capacity times a job's share, plus the OS's), and the managers' boot
  # disks (a handoff), never more GB than SSD_TOTAL_GB in us-central1, or a pool's VM fails QUOTA_EXCEEDED and never
  # comes, as a VM over the CPU quota did on 2026-11-13.
  assert {
    condition     = output.ci_disks.ssd_quota_gb == 500 && output.ci_disks.manager_disk_gb == 20 && sum(concat([for p in values(output.runner_pools) : contains(["pd-balanced", "pd-ssd", "pd-extreme"], p.disk_type) ? p.max_instances * (p.capacity * p.job.disk_gb + p.os_disk_gb) : 0], [output.ci_cpus.managers * output.ci_disks.manager_disk_gb])) <= output.ci_disks.ssd_quota_gb
    error_message = "The pools' SSD-backed disks at their max_instances and the managers' need more GB than tacplus-ci's SSD_TOTAL_GB quota in us-central1 (500)."
  }
  assert {
    condition     = output.runner_pools.shared.job.cpus == "8" && output.runner_pools.shared.job.memory == "28g" && output.runner_pools.shared.job.memory_swap == "28g"
    error_message = "A shared pool's job may not use the whole VM's CPUs and all but 4 GB of its memory, without swap."
  }
  assert {
    condition     = output.runner_pools.shared.runner == { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale", "autoscale-16"], protected = false } && !output.runner_pools.shared.service_account
    error_message = "The shared pool is not an unprotected group runner of tacplus-dev under today's tags, with no account on its VM."
  }
  # The builds run a few at a time, never on the always-on nodes (Jody, 2026-11-10), on demand from zero since #55: five
  # build VMs were preempted on 2026-11-13, each under 10 minutes old, and a 3-hour tacplus gates run never finished.
  assert {
    condition     = !output.runner_pools.build.spot && !output.runner_pools.shared.spot && output.runner_pools.build.idle_count == 0 && output.runner_pools.build.max_instances * output.runner_pools.build.capacity <= 8 && output.runner_pools.build.runner.tags == ["arm64", "build", "build-docker"] && !contains(output.runner_pools.shared.runner.tags, "build")
    error_message = "Builds do not run on demand, from zero, a few at a time, apart from the always-on nodes."
  }
  # A zone out of spot t2a stalls no build (#49): the build pool spreads over every us-central1 zone with t2a, and the
  # other pools stay in the stack's zone.
  assert {
    condition     = output.runner_pools.build.zones == ["us-central1-a", "us-central1-b", "us-central1-f"] && alltrue([for k in ["shared", "deploy", "cluster"] : length(try(output.runner_pools[k].zones, [])) == 0])
    error_message = "The build pool does not spread over us-central1-a, -b and -f (the zones with t2a), or another pool leaves the stack's zone."
  }
  assert {
    condition     = alltrue([for k in ["deploy", "cluster"] : output.runner_pools[k].runner.protected && output.runner_pools[k].runner.type == "project_type" && output.runner_pools[k].idle_count == 0 && output.runner_pools[k].max_instances == 1])
    error_message = "deploy and cluster are not protected project runners, on demand."
  }
  assert {
    condition     = alltrue([for p in values(output.runner_pools) : p.capacity > 1 && p.job.cpus != "" && p.job.memory != "" && p.job.memory_swap == p.job.memory && p.job.disk_gb > 0 && !p.service_account])
    error_message = "A pool runs one job per VM, or a job without its CPU, memory (no swap) and disk share."
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
    }
    error_message = "The apps, their IDs or their signers are not the ones #19, #30 and #84 list."
  }
  # The Admiral's (#84; tacplus-dev/admiral#5): the seatrials fleet's kernel, by its one issuer URL, for the Admiral's
  # SPIFFE ID alone; its account, its App's key (no GitLab job signs with it, above) and its secret.
  assert {
    condition     = output.admiral == { pool = "fleet-kernels", provider = "seatrials", issuer = "https://seatrials.tacplus.dev", subject = "spiffe://local.dev/system/services/admiral", account_id = "admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" } && contains(keys(output.github_apps.apps), output.admiral.key)
    error_message = "The Admiral's credentials are not seatrials' kernel's provider for its SPIFFE ID, the account admiral, the key tacplus-admiral and the secret admiral-triage-gitlab."
  }
  assert {
    condition     = output.github_apps.key_ring == "looper" && output.github_apps.pool == "gitlab-loopers" && output.github_apps.looper == { project = "tacplus-dev/looper", project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" } && output.github_apps.namespace == { path = "tacplus-dev", id = "145863835", wif_provider = "gitlab-com" }
    error_message = "The apps' federation is not tacplus-dev/looper's main (88136765) and tacplus-dev's namespace (145863835), in the pool gitlab-loopers."
  }
  # The looper VMs (#108; decisions/looper-build-vms-2026-11-24.md): tacplus first, the pilot, a spot c4a-standard-8
  # with a 200 GB cache disk, with no image until tacplus-dev/looper#239 publishes it (its group stays at 0).
  assert {
    condition     = output.looper_vms == { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper@sha256:dc4a57abeb9def11dbcdd2b5a52953f30ec7120bca30ce8213b7d1650e79567f" } }
    error_message = "The looper VMs are not tacplus's alone, a spot c4a-standard-8 with 200 GB and no image yet."
  }
}

run "ci" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      with-account = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 2, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = true
      }
      no-account = {
        machine_type = "t2a-standard-4", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 3, max_instances = 2, idle_count = 0, idle_time = "30m"
        job          = { cpus = "1", memory = "4g", memory_swap = "4g", disk_gb = 20, security_opt = ["no-new-privileges"] }, service_account = false
        spot         = true, zones = ["us-central1-a", "us-central1-b", "us-central1-f"]
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = {
      key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }
      pools    = { bootstrap = "projects/111/locations/global/workloadIdentityPools/gitlab-com", dev = "projects/444/locations/global/workloadIdentityPools/gitlab-com" }
      keys     = { tacplus-reader = { import = true, namespace = true, environments = [], accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } }, projects = [{ pool = "bootstrap", gitlab_project = "tacplus-dev/cloud" }, { pool = "dev", gitlab_project = "tacplus-dev/cluster" }] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } }
    }
    # As GCP_KMS_KEY_IMPORTERS gives it: an account of the host's directory, which no file here names.
    kms_key_importers = ["user:jody@example.com"]
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

  # NAT gives each VM ports as its jobs need them: no slots means many connections at once (2026-11-11).
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
  # The one port-22 rule, exactly as ci/policy.sh admits it, until the runner VMs go (#11); no IAP SSH (#7).
  assert {
    condition     = google_compute_firewall.manager_to_workers.direction == "INGRESS" && length(coalesce(google_compute_firewall.manager_to_workers.source_ranges, [])) == 0 && google_compute_firewall.manager_to_workers.source_tags == toset(["runner-manager"]) && google_compute_firewall.manager_to_workers.target_tags == toset(["runner-worker"]) && length(google_compute_firewall.manager_to_workers.allow) == 1 && one(google_compute_firewall.manager_to_workers.allow).protocol == "tcp" && one(google_compute_firewall.manager_to_workers.allow).ports == tolist(["22"])
    error_message = "The runners' SSH rule is not the manager to its workers alone, by network tag, on port 22 alone."
  }
  assert {
    condition     = length(google_compute_instance.manager.network_interface[0].access_config) == 0
    error_message = "The runner manager has an external address."
  }
  assert {
    condition     = length(google_compute_instance_template.pool["no-account"].service_account) == 0
    error_message = "A pool without an account has one on its VMs."
  }
  assert {
    condition     = length(google_compute_instance_template.pool["with-account"].service_account) == 1 && keys(google_service_account.worker) == ["with-account"]
    error_message = "A pool with an account does not run as its own."
  }
  assert {
    condition     = alltrue([for t in google_compute_instance_template.pool : t.disk[0].source_image == "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12" && startswith(t.machine_type, "t2a-") && length(t.network_interface[0].access_config) == 0])
    error_message = "A pool's VMs are not arm64, on the pinned Container-Optimized OS, with no external address."
  }
  assert {
    condition     = alltrue([for g in concat(values(google_compute_instance_group_manager.pool), values(google_compute_region_instance_group_manager.pool)) : g.target_size == 0])
    error_message = "A pool's instance group is not empty at rest."
  }
  # A template change reaches every VM, one still creating included (#29): the group replaces them itself, never
  # above the size the manager set. A regional group's unavailable count is at least its zones'.
  assert {
    condition     = alltrue([for g in concat(values(google_compute_instance_group_manager.pool), values(google_compute_region_instance_group_manager.pool)) : length(g.update_policy) == 1 && g.update_policy[0].type == "PROACTIVE" && g.update_policy[0].minimal_action == "REPLACE" && g.update_policy[0].max_surge_fixed == 0 && g.update_policy[0].max_unavailable_fixed > 0]) && google_compute_region_instance_group_manager.pool["no-account"].update_policy[0].max_unavailable_fixed == 3
    error_message = "A pool's instance group does not replace its VMs proactively, with no surge, on a template change."
  }
  # A VM its group did not stop (a spot VM reclaimed, 2026-11-13 10:26Z) is left stopped, not repaired: the plugin
  # deletes it and the autoscaler's next VM goes where there is capacity (#53), as upstream's README recommends. A
  # repair recreates it in its own zone, retried there forever when that zone is out of capacity.
  assert {
    condition     = alltrue([for g in concat(values(google_compute_instance_group_manager.pool), values(google_compute_region_instance_group_manager.pool)) : g.instance_lifecycle_policy[0].default_action_on_failure == "DO_NOTHING"])
    error_message = "A pool's instance group repairs a VM it did not stop, in its zone, instead of leaving it to the plugin."
  }
  # A zone out of capacity stalls no pool spread over the region's zones (#49): its group is regional, over its zones,
  # and makes each new VM in a zone that has the capacity (target shape ANY, which never moves a VM to even the zones
  # out: redistribution off). The plugin is pointed at the region. A pool with no zones of its own stays in the stack's.
  assert {
    condition     = keys(google_compute_region_instance_group_manager.pool) == ["no-account"] && keys(google_compute_instance_group_manager.pool) == ["with-account"] && google_compute_instance_group_manager.pool["with-account"].zone == "us-central1-b"
    error_message = "The spread pool's group is not regional, or the other pool's not zonal in the stack's zone."
  }
  # Not runner-<pool>: a regional group makes a zonal instance group of its name in each of its zones, which would
  # collide with the pool's zonal group while it still exists (apply:ci of 580d4ca, 409 alreadyExists).
  assert {
    condition     = google_compute_region_instance_group_manager.pool["no-account"].name == "runner-no-account-region" && google_compute_region_instance_group_manager.pool["no-account"].region == "us-central1" && google_compute_region_instance_group_manager.pool["no-account"].distribution_policy_zones == toset(["us-central1-a", "us-central1-b", "us-central1-f"]) && google_compute_region_instance_group_manager.pool["no-account"].distribution_policy_target_shape == "ANY" && google_compute_region_instance_group_manager.pool["no-account"].update_policy[0].instance_redistribution_type == "NONE"
    error_message = "The spread pool's group does not make its VMs in whichever of its zones has the capacity (us-central1-a, -b, -f, shape ANY, no redistribution)."
  }
  assert {
    condition     = strcontains(google_compute_instance.manager.metadata["runner-config"], "name = \"runner-no-account-region\"\n      project = \"tacplus-ci\"\n      region = \"us-central1\"\n") && strcontains(google_compute_instance.manager.metadata["runner-config"], "name = \"runner-with-account\"\n      project = \"tacplus-ci\"\n      zone = \"us-central1-b\"\n")
    error_message = "The plugin is not pointed at the spread pool's region, or at the other pool's zone."
  }
  # An instance stuck creating on a capacity error is deleted, not retried forever (#49, #29): the manager's reaper
  # (files/manager-startup.sh) reads every pool's group from its metadata, so the autoscaler's next VM goes where there
  # is capacity. And a new manager empties each of them before its gitlab-runner starts,
  # once the old one has retired (#48).
  assert {
    condition     = google_compute_instance.manager.metadata["runner-groups"] == "regions/us-central1/instanceGroupManagers/runner-no-account-region zones/us-central1-b/instanceGroupManagers/runner-with-account"
    error_message = "The manager's reaper does not watch every pool's group, by its region or zone."
  }
  # The workers' accounts hold no role: the manager is the only account with a project role.
  assert {
    condition     = alltrue([for m in google_project_iam_member.manager : m.member == google_service_account.manager.member])
    error_message = "A project role is granted to an account other than the manager."
  }
  assert {
    condition     = !strcontains(google_compute_instance.manager.metadata["runner-config"], "glrt-") && strcontains(google_compute_instance.manager.metadata["runner-config"], "@TOKEN:no-account@") && strcontains(google_compute_instance.manager.metadata["runner-config"], "@TOKEN:with-account@")
    error_message = "The manager's config holds a token, or lacks a pool's placeholder."
  }
  # The pools' VMs are vanilla Container-Optimized OS: nothing installed at boot, no startup-script, no OS update
  # (the pin is the only way their OS changes); the manager connects as runner, which the guest agent creates with
  # the OS's docker group, and waits, at most ten minutes, until the OS's own container runtime has pulled the helper
  # image (#61: a fresh VM is up before its egress works, and an HTTPS answer from the VM itself, #50, was not enough).
  assert {
    condition     = alltrue([for t in google_compute_instance_template.pool : length(t.metadata) == 1 && t.metadata["cos-update-strategy"] == "update_disabled"])
    error_message = "A pool's VMs run a startup-script or update their OS."
  }
  assert {
    condition     = length(regexall("username = \"runner\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "The manager does not connect as runner."
  }
  assert {
    condition     = length(regexall("instance_ready_command = \"timeout 600 sh -c 'until timeout 120 docker pull registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893 >/dev/null 2>&1; do sleep 2; done'\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "A pool does not wait, bounded, until its VM's container runtime has pulled the helper image itself."
  }
  # Job containers share the pools' VMs (decisions/looper-job-per-issue-2026-11-03.md, #5): each pool runs its
  # capacity of jobs on a VM, each job's container limited in CPU and memory (no swap), the disk bounded per VM (its
  # capacity times a job's share, plus the OS's); the VMs are reused, and each job's containers and volumes discarded
  # (no cache volume kept); no job is privileged or gets the host's Docker socket.
  assert {
    condition = alltrue([for pool in [
      { name = "with-account", group = "runner-with-account", capacity = 2, limit = 2, max = 1, idle = 1, cpus = "4", memory = "14g", security_opt = "[]" },
      { name = "no-account", group = "runner-no-account-region", capacity = 3, limit = 6, max = 2, idle = 0, cpus = "1", memory = "4g", security_opt = "[\"no-new-privileges\"]" },
      ] : strcontains(google_compute_instance.manager.metadata["runner-config"], join("\n", [
        "  limit = ${pool.limit}",
        "  [runners.docker]",
        "    image = \"alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a\"",
        "    helper_image = \"registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893\"",
        "    privileged = false",
        "    disable_cache = true",
        "    volumes = []",
        "    cpus = \"${pool.cpus}\"",
        "    memory = \"${pool.memory}\"",
        "    memory_swap = \"${pool.memory}\"",
        "    security_opt = ${pool.security_opt}",
        "  [runners.autoscaler]",
        "    plugin = \"/usr/local/bin/fleeting-plugin-googlecloud\"",
        "    capacity_per_instance = ${pool.capacity}",
        "    max_use_count = 0",
        "    max_instances = ${pool.max}",
      ])) && strcontains(google_compute_instance.manager.metadata["runner-config"], "name = \"${pool.group}\"")
    ])
    error_message = "A pool does not run its capacity of jobs per reused VM, each limited in CPU and memory without swap, discarded with its volumes, unprivileged."
  }
  assert {
    condition     = length(regexall("idle_count = 1\n      idle_time = \"30m\"", google_compute_instance.manager.metadata["runner-config"])) == 1 && length(regexall("idle_count = 0\n      idle_time = \"30m\"", google_compute_instance.manager.metadata["runner-config"])) == 1
    error_message = "A pool does not keep its idle VMs as it says."
  }
  assert {
    condition     = !strcontains(google_compute_instance.manager.metadata["runner-config"], "docker.sock") && !strcontains(google_compute_instance.manager.metadata["runner-config"], "privileged = true")
    error_message = "A pool's jobs get the host's Docker socket, or run privileged."
  }
  assert {
    condition     = google_compute_instance_template.pool["with-account"].disk[0].disk_size_gb == 250 && google_compute_instance_template.pool["no-account"].disk[0].disk_size_gb == 110
    error_message = "A pool's disk is not its capacity times a job's share, plus the OS's."
  }
  # COS's root file system is read-only: no job mounts a host directory outside the runtime's own.
  assert {
    condition     = length(regexall("\"/builds:/builds\"", google_compute_instance.manager.metadata["runner-config"])) == 0
    error_message = "A pool mounts the host's /builds, which COS's read-only root does not have."
  }
  assert {
    condition     = google_compute_instance.manager.boot_disk[0].initialize_params[0].image == "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024" && google_compute_instance.manager.boot_disk[0].initialize_params[0].size == 20 && google_compute_instance.manager.boot_disk[0].initialize_params[0].type == "pd-balanced"
    error_message = "The manager does not boot the pinned Ubuntu image from a 20 GB pd-balanced disk (the SSD quota counts it, #63)."
  }
  assert {
    condition     = google_compute_instance.manager.metadata["runner-pools"] == "no-account with-account"
    error_message = "The manager does not run every pool."
  }
  assert {
    condition     = length(regexall("image = \"alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "A pool's default image is not the pinned alpine 3.24."
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
  # The manager's binaries (#40): our builds, in a private bucket only the manager's account reads, each object named
  # by its pinned SHA-256 and uploaded from the tools job's bin/manager.
  assert {
    condition     = google_storage_bucket.runner_bin.name == "tacplus-ci-runner-bin" && google_storage_bucket.runner_bin.uniform_bucket_level_access && google_storage_bucket.runner_bin.public_access_prevention == "enforced" && google_storage_bucket.runner_bin.location == "US-CENTRAL1"
    error_message = "The runner bucket is not tacplus-ci-runner-bin, uniform, private and in us-central1."
  }
  assert {
    condition     = google_storage_bucket_iam_binding.runner_bin.bucket == google_storage_bucket.runner_bin.name && google_storage_bucket_iam_binding.runner_bin.role == "roles/storage.objectViewer" && google_storage_bucket_iam_binding.runner_bin.members == toset([google_service_account.manager.member])
    error_message = "The runner bucket's objects are readable by someone other than the manager's account alone."
  }
  assert {
    condition     = !anytrue([for m in google_storage_bucket_iam_binding.runner_bin.members : contains(["allUsers", "allAuthenticatedUsers"], m)])
    error_message = "The runner bucket is granted to allUsers or allAuthenticatedUsers."
  }
  assert {
    condition     = { for k, o in google_storage_bucket_object.runner_bin : k => [o.bucket, o.name, o.source] } == { gitlab-runner = [google_storage_bucket.runner_bin.name, "gitlab-runner/c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee", "../../bin/manager/gitlab-runner"], fleeting-plugin-googlecloud = [google_storage_bucket.runner_bin.name, "fleeting-plugin-googlecloud/429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb", "../../bin/manager/fleeting-plugin-googlecloud"] }
    error_message = "The runner bucket's objects are not the two builds of bin/manager, each named by its pinned SHA-256."
  }
  # The manager installs them from there, by SHA-256, and nothing from upstream or a package archive at boot.
  assert {
    condition     = google_compute_instance.manager.metadata["runner-bucket"] == google_storage_bucket.runner_bin.name && google_compute_instance.manager.metadata["runner-sha256"] == "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee" && google_compute_instance.manager.metadata["fleeting-plugin-sha256"] == "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
    error_message = "The manager's metadata does not name the runner bucket and the two builds' pinned SHA-256s."
  }
  assert {
    condition     = join(" ", keys(google_compute_instance.manager.metadata)) == "fleeting-plugin-sha256 runner-bucket runner-config runner-groups runner-handoff-limit runner-pools runner-sha256 startup-script" && !anytrue([for v in values(google_compute_instance.manager.metadata) : strcontains(v, "gitlab-runner-downloads") || strcontains(v, "/packages/generic/") || strcontains(v, "apt-get")])
    error_message = "The manager's metadata still pins an upstream download or a package archive."
  }
  # The handoff's cap (#51): 30 minutes by default, config pushed to the running manager (not its build), in seconds.
  assert {
    condition     = google_compute_instance.manager.metadata["runner-handoff-limit"] == "1800"
    error_message = "The manager's metadata does not cap a handoff at 30 minutes (runner-handoff-limit, in seconds)."
  }
  # A cut reports its jobs (#54): gitlab-runner's forced stop waits 7 minutes for them, not the default 30 seconds.
  assert {
    condition     = length(regexall("(?m)^shutdown_timeout = 420$", google_compute_instance.manager.metadata["runner-config"])) == 1
    error_message = "The manager's config.toml does not give a forced stop 7 minutes (shutdown_timeout = 420) to report its aborted jobs."
  }
  # Never without a manager (#46): its name is its build's, so a new build makes the new one before the old one goes.
  # This build's (these inputs and files/manager-startup.sh): a commit that changes it replaces the manager.
  assert {
    condition     = google_compute_instance.manager.name == "runner-manager-d510c62b" && google_compute_instance.manager.metadata["startup-script"] == file("../../modules/projects/ci/files/manager-startup.sh")
    error_message = "The manager's name is not runner-manager-<its build's hash>, or its build changed: then this test's name, knowingly (a new build replaces the manager)."
  }
  assert {
    condition     = length(regexall("helper_image = \"registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "Each runner's helper image is not the runner version's, by digest."
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
    condition     = alltrue([for m in google_project_iam_member.manager : m.member != google_service_account.app["fleet-seatrials-reader"].member])
    error_message = "The reader's account holds a project role."
  }
  assert {
    condition     = !contains(google_kms_crypto_key_iam_binding.signer["tacplus-manager"].members, "principalSet://iam.googleapis.com/projects/333/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:looper-report")
    error_message = "tacplus-manager signs for looper-report: a report's code could mint the bypass."
  }
  assert {
    condition     = alltrue([for k, b in google_kms_crypto_key_iam_binding.signer : b.crypto_key_id == google_kms_crypto_key.app[k].id])
    error_message = "A signer binding is not on its own key."
  }
  assert {
    condition     = alltrue([for s in google_secret_manager_secret.runner_token : s.replication[0].user_managed[0].replicas[0].location == "us-central1"])
    error_message = "A runner-token secret is replicated outside us-central1."
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 4, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud", autoscaler_log = true }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
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

# A pool that runs one job per VM, or lets a job swap, is refused (#5).
run "one_job_per_vm_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      swap = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 1, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "28g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.pools]
}

# A write role to hub-audit, the audit job's account, is refused (#77): it reads only.
run "hub_audit_write_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      swap = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 2, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.admin", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.hub_audit]
}

# A pool spread over a zone outside the region, or over one zone (which is the stack's zone's job), is refused (#49).
run "zone_outside_region_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      spread = {
        machine_type = "t2a-standard-8", disk_type = "pd-standard", os_disk_gb = 50, capacity = 4, max_instances = 2, idle_count = 0, idle_time = "15m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
        spot         = true, zones = ["us-central1-a", "us-east1-b"]
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.pools]
}

run "one_zone_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      spread = {
        machine_type = "t2a-standard-8", disk_type = "pd-standard", os_disk_gb = 50, capacity = 4, max_instances = 2, idle_count = 0, idle_time = "15m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
        spot         = true, zones = ["us-central1-a"]
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.pools]
}

run "unpinned_runner_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.runner]
}

# A file in bin/manager that is not the pinned build (#40): not uploaded.
run "unpinned_build_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [google_storage_bucket_object.runner_bin]
}


# A family resolves the newest image at each VM's creation, which no commit fixes: refused, as is any image but
# Container-Optimized OS for arm64.
run "family_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/family/cos-arm64-stable"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.pool_image]
}


# Without importers (GCP_KMS_KEY_IMPORTERS unset or cleared, as a later commit does once the keys are imported),
# nobody imports: no importer binding at all, on the import jobs or the keys. The signers stay.
run "no_importers" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin        = "../../bin/manager"
    pools             = {}
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, pools = { dev = "projects/444/locations/global/workloadIdentityPools/gitlab-com" }, keys = { tacplus-reader = { import = true, namespace = true, environments = [], accounts = { fleet-seatrials-reader = { pool = "elsewhere", gitlab_project = "tacplus-dev/fleet-seatrials" } } }, tacplus-looper = { import = true, namespace = false, environments = [], accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } } } } }
  }
  expect_failures = [var.github_apps]
}

# What replaces the manager and what is pushed to it (#61): gitlab-runner reads a pool's [runners.autoscaler] once,
# and a reload changes only its policy, so the rest of it is the manager's build, like the startup script: a change
# to it is a new manager (its handoff, #48, drains the old one's jobs first), never config pushed in place, which the
# running gitlab-runner would not apply (#50's ready check, until it restarted). The policy and the job settings are
# pushed: gitlab-runner reloads them.
run "manager_build" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 4, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = google_compute_instance.manager.name == "runner-manager-f496242a"
    error_message = "This build's name changed: then the names of this test and the next ones, knowingly (a new build replaces the manager)."
  }
}

run "manager_build_policy_pushed" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 4, max_instances = 1, idle_count = 0, idle_time = "15m"
        job          = { cpus = "2", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = strcontains(google_compute_instance.manager.metadata["runner-config"], "idle_count = 0") && strcontains(google_compute_instance.manager.metadata["runner-config"], "cpus = \"2\"")
    error_message = "The pool's policy and its jobs' settings are not this run's."
  }
  assert {
    condition     = google_compute_instance.manager.name == "runner-manager-f496242a"
    error_message = "A change to a pool's policy or its jobs' settings, which gitlab-runner reloads, replaces the manager."
  }
}

run "manager_build_autoscaler_replaces" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 2, max_instances = 3, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = google_compute_instance.manager.name != "runner-manager-f496242a"
    error_message = "A change to a pool's autoscaler (its capacity, its VMs), which gitlab-runner reads only once, does not replace the manager."
  }
}

run "manager_build_ready_check_replaces" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:0000000000000000000000000000000000000000000000000000000000000000"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 4, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = google_compute_instance.manager.name != "runner-manager-f496242a"
    error_message = "A change to the pools' ready check (the helper image it pulls), which gitlab-runner reads only once, does not replace the manager."
  }
}

# A change to the manager's build (its image here) replaces it under a new name, so the new one is made before the old
# one goes (create_before_destroy; ci/policy.sh refuses a plan that would destroy it first).
run "manager_build_replaced" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261101"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin = "../../bin/manager"
    pools = {
      shared = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 4, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  assert {
    condition     = google_compute_instance.manager.name != "runner-manager-f496242a" && can(regex("^runner-manager-[0-9a-f]{8}$", google_compute_instance.manager.name))
    error_message = "A new build of the manager keeps its name: the new one could not be made before the old one goes."
  }
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-looper = { import = true, namespace = false, environments = ["looper-report"] }, tacplus-admiral = { import = true, namespace = false, environments = [] } } }
    # As GCP_KMS_KEY_IMPORTERS and GCP_ADMIRAL_SECRET_ADDERS give them: accounts of the host's directory.
    kms_key_importers     = ["user:jody@example.com"]
    admiral               = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://local.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
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
    condition     = google_service_account_iam_binding.admiral["admiral"].role == "roles/iam.workloadIdentityUser" && google_service_account_iam_binding.admiral["admiral"].members == toset(["principal://iam.googleapis.com/projects/444/locations/global/workloadIdentityPools/fleet-kernels/subject/spiffe://local.dev/system/services/admiral"])
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-admiral = { import = true, namespace = false, environments = [] } } }
    admiral     = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://local.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-admiral = { import = true, namespace = false, environments = ["looper-report"] } } }
    admiral     = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://local.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
  }
  expect_failures = [google_kms_crypto_key_iam_binding.admiral]
}

run "admiral_unknown_key_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-looper = { import = true, namespace = false, environments = ["looper-report"] } } }
    admiral     = { account_id = "admiral", pool = "projects/444/locations/global/workloadIdentityPools/fleet-kernels", subject = "spiffe://local.dev/system/services/admiral", key = "tacplus-admiral", secret = "admiral-triage-gitlab" }
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms = {
      tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper/looper-vm@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
      small   = { machine_type = "c4a-standard-2", disk_gb = 50, spot = false, image = "" }
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
    condition     = alltrue([for k, t in google_compute_instance_template.looper_vm : !contains(keys(t.metadata), "ssh-keys") && !contains(keys(t.metadata), "sshKeys") && t.metadata["block-project-ssh-keys"] == "true" && join(" ", sort(keys(t.metadata))) == "block-project-ssh-keys cos-update-strategy google-logging-enabled looper-group looper-image looper-repo user-data" && t.metadata["looper-repo"] == k && t.metadata["looper-group"] == "projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/looper-vm-${k}" && t.metadata["google-logging-enabled"] == "true" && t.metadata["cos-update-strategy"] == "update_disabled"]) && google_compute_instance_template.looper_vm["tacplus"].metadata["looper-image"] == "ghcr.io/tacplus-dev/looper/looper-vm@sha256:1111111111111111111111111111111111111111111111111111111111111111" && google_compute_instance_template.looper_vm["small"].metadata["looper-image"] == ""
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
  assert {
    condition     = !anytrue([for b in google_secret_manager_secret_iam_member.manager_reads_token : startswith(b.member, "serviceAccount:looper-vm-")])
    error_message = "A looper VM's account reads a runner token."
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
    condition     = alltrue([for m in concat(values(google_project_iam_member.manager), values(google_project_iam_member.hub_audit), values(google_project_iam_member.looper_vm_log)) : !strcontains(m.role, "looperVmResizer")])
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
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
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms  = { tacplus = { machine_type = "c4a-standard-8", disk_gb = 200, spot = true, image = "ghcr.io/tacplus-dev/looper/looper-vm:1.0" } }
  }
  expect_failures = [var.looper_vms]
}

run "looper_vm_not_c4a_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version        = "v19.6.0", branch = "19-6-stable", commit = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0", runner_sha256 = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
      plugin_version = "v1.3.1", plugin_commit = "31ea56d71b16c75e37999262293b273be509f13d", plugin_sha256 = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
      helper_image   = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
      default_image  = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    runner_bin  = "../../bin/manager"
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    hub_audit   = { account_id = "hub-audit", projects = ["tacplus-ci", "tacplus-dev"], roles = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], pool = "projects/111/locations/global/workloadIdentityPools/gitlab-com", gitlab_project = "tacplus-dev/cloud" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
    looper_vms  = { tacplus = { machine_type = "t2a-standard-8", disk_gb = 200, spot = true, image = "" } }
  }
  expect_failures = [var.looper_vms]
}
