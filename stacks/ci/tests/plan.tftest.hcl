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
    condition     = output.app_keys == { for k in ["tacplus-reader", "tacplus-manager", "tacplus-looper"] : k => "projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/${k}" }
    error_message = "The stack does not give each app's key."
  }
  # The reader's account and its pools (#30): the dev project's, which plan:ci reads after apply:dev made it, and
  # tacplus-bootstrap's.
  assert {
    condition     = output.app_accounts == { fleet-seatrials-reader = "fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com" } && data.google_project.dev.project_id == "tacplus-dev"
    error_message = "The stack does not give the reader's account fleet-seatrials-reader, or does not read the dev project."
  }
  # Computed at apply: the provider's name and the key ring's and keys' IDs, as Google gives them.
  override_resource {
    target = module.ci.google_iam_workload_identity_pool_provider.looper
    values = { name = "projects/333/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-looper" }
  }
  override_resource {
    target = module.ci.google_service_account.app
    values = { email = "fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com" }
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
    condition     = output.runner_pools.shared.machine_type == "t2a-standard-8" && output.runner_pools.shared.capacity == 25 && output.runner_pools.shared.idle_count == 3 && output.runner_pools.shared.max_instances == 3
    error_message = "The shared pool is not three always-on t2a-standard-8s with no slots (25 jobs a VM, Jody 2026-11-10)."
  }
  assert {
    condition     = output.runner_pools.shared.job.cpus == "8" && output.runner_pools.shared.job.memory == "28g" && output.runner_pools.shared.job.memory_swap == "28g" && output.runner_pools.shared.capacity * output.runner_pools.shared.job.disk_gb + output.runner_pools.shared.os_disk_gb <= 500
    error_message = "A shared pool's job may not use the whole VM's CPUs and all but 4 GB of its memory, without swap, or the VM's disk is over 500 GB."
  }
  assert {
    condition     = output.runner_pools.shared.runner == { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale", "autoscale-16"], protected = false } && !output.runner_pools.shared.service_account
    error_message = "The shared pool is not an unprotected group runner of tacplus-dev under today's tags, with no account on its VM."
  }
  # The builds run on spot, a few at a time, never on the always-on nodes (Jody, 2026-11-10).
  assert {
    condition     = output.runner_pools.build.spot && !output.runner_pools.shared.spot && output.runner_pools.build.idle_count == 0 && output.runner_pools.build.max_instances * output.runner_pools.build.capacity <= 4 && output.runner_pools.build.runner.tags == ["arm64", "build"] && !contains(output.runner_pools.shared.runner.tags, "build")
    error_message = "Builds do not run only on spot, from zero, a few at a time, apart from the always-on nodes."
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
    }
    error_message = "The apps, their IDs or their signers are not the ones #19 and #30 list."
  }
  assert {
    condition     = output.github_apps.key_ring == "looper" && output.github_apps.pool == "gitlab-loopers" && output.github_apps.looper == { project = "tacplus-dev/looper", project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" } && output.github_apps.namespace == { path = "tacplus-dev", id = "145863835", wif_provider = "gitlab-com" }
    error_message = "The apps' federation is not tacplus-dev/looper's main (88136765) and tacplus-dev's namespace (145863835), in the pool gitlab-loopers."
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools = {
      with-account = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 2, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }, service_account = true
      }
      no-account = {
        machine_type = "t2a-standard-4", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 3, max_instances = 2, idle_count = 0, idle_time = "30m"
        job          = { cpus = "1", memory = "4g", memory_swap = "4g", disk_gb = 20, security_opt = ["no-new-privileges"] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
    condition     = alltrue([for g in google_compute_instance_group_manager.pool : g.target_size == 0])
    error_message = "A pool's instance group is not empty at rest."
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
  # the OS's docker group, and waits, at most ten minutes, for the OS's own container runtime to answer.
  assert {
    condition     = alltrue([for t in google_compute_instance_template.pool : length(t.metadata) == 1 && t.metadata["cos-update-strategy"] == "update_disabled"])
    error_message = "A pool's VMs run a startup-script or update their OS."
  }
  assert {
    condition     = length(regexall("username = \"runner\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "The manager does not connect as runner."
  }
  assert {
    condition     = length(regexall("instance_ready_command = \"timeout 600 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'\"", google_compute_instance.manager.metadata["runner-config"])) == 2
    error_message = "A pool does not wait, bounded, for its VM's container runtime."
  }
  # Job containers share the pools' VMs (decisions/looper-job-per-issue-2026-11-03.md, #5): each pool runs its
  # capacity of jobs on a VM, each job's container limited in CPU and memory (no swap), the disk bounded per VM (its
  # capacity times a job's share, plus the OS's); the VMs are reused, and each job's containers and volumes discarded
  # (no cache volume kept); no job is privileged or gets the host's Docker socket.
  assert {
    condition = alltrue([for pool in [
      { name = "with-account", capacity = 2, limit = 2, max = 1, idle = 1, cpus = "4", memory = "14g", security_opt = "[]" },
      { name = "no-account", capacity = 3, limit = 6, max = 2, idle = 0, cpus = "1", memory = "4g", security_opt = "[\"no-new-privileges\"]" },
      ] : strcontains(google_compute_instance.manager.metadata["runner-config"], join("\n", [
        "  limit = ${pool.limit}",
        "  [runners.docker]",
        "    image = \"alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a\"",
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
      ])) && strcontains(google_compute_instance.manager.metadata["runner-config"], "name = \"runner-${pool.name}\"")
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
    condition     = google_compute_instance.manager.boot_disk[0].initialize_params[0].image == "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    error_message = "The manager does not boot the pinned Ubuntu image."
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools = {
      swap = {
        machine_type = "t2a-standard-8", disk_type = "pd-balanced", os_disk_gb = 50, capacity = 1, max_instances = 1, idle_count = 1, idle_time = "30m"
        job          = { cpus = "4", memory = "14g", memory_swap = "28g", disk_gb = 100, security_opt = [] }, service_account = false
      }
    }
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24"
    }
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, keys = { tacplus-reader = { import = false, namespace = true, environments = [] }, tacplus-manager = { import = true, namespace = false, environments = ["looper-manager", "looper-scan"] }, tacplus-looper = { import = true, namespace = false, environments = ["kicker", "looper-plan", "looper-report", "looper-scan"] } } }
  }
  expect_failures = [var.runner]
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/family/cos-arm64-stable"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools             = {}
    build_cache       = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
    apt_snapshot         = "20261024T000000Z"
    pool_image           = "projects/cos-cloud/global/images/cos-arm64-121-18867-652-12"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    }
    pools       = {}
    build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    github_apps = { key_ring = "looper", wif_pool = "gitlab-loopers", namespace = { id = "145863835", wif_provider = "gitlab-com" }, looper = { project_id = "88136765", ref = "main", wif_provider = "gitlab-looper" }, pools = { dev = "projects/444/locations/global/workloadIdentityPools/gitlab-com" }, keys = { tacplus-reader = { import = true, namespace = true, environments = [], accounts = { fleet-seatrials-reader = { pool = "elsewhere", gitlab_project = "tacplus-dev/fleet-seatrials" } } }, tacplus-looper = { import = true, namespace = false, environments = [], accounts = { fleet-seatrials-reader = { pool = "dev", gitlab_project = "tacplus-dev/fleet-seatrials" } } } } }
  }
  expect_failures = [var.github_apps]
}
