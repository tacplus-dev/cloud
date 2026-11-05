# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci stack's plan under a stub parent folder, with an empty project (mock providers: no credentials, no cloud):
# the stack plans, and its module, with the stack's inputs, gives the runners, the buckets and the reader's key as
# designed, with no SSH but the runners' internal rule and no external address (#7), and the settings give the pools
# Jody decided (#5). (A test sees a module's resources only when it runs
# that module itself.)

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
    condition     = toset(keys(output.runner_token_secrets)) == toset(["shared", "deploy", "cluster"])
    error_message = "Not every runner pool has its token secret."
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
    condition     = toset(keys(output.runner_pools)) == toset(["shared", "deploy", "cluster"])
    error_message = "The pools are not shared, deploy and cluster."
  }
  assert {
    condition     = output.runner_pools.shared.machine_type == "t2a-standard-8" && output.runner_pools.shared.capacity == 2 && output.runner_pools.shared.idle_count == 1 && output.runner_pools.shared.max_instances == 1
    error_message = "The shared pool is not one always-on t2a-standard-8 running two jobs."
  }
  assert {
    condition     = output.runner_pools.shared.job.cpus == "4" && output.runner_pools.shared.job.memory == "14g" && output.runner_pools.shared.job.memory_swap == "14g"
    error_message = "A shared pool's job is not limited to 4 CPUs and 14g, without swap."
  }
  assert {
    condition     = output.runner_pools.shared.runner == { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale", "autoscale-16", "build"], protected = false } && !output.runner_pools.shared.service_account
    error_message = "The shared pool is not an unprotected group runner of tacplus-dev under today's tags, with no account on its VM."
  }
  assert {
    condition     = alltrue([for k in ["deploy", "cluster"] : output.runner_pools[k].runner.protected && output.runner_pools[k].runner.type == "project_type" && output.runner_pools[k].idle_count == 0 && output.runner_pools[k].max_instances == 1])
    error_message = "deploy and cluster are not protected project runners, on demand."
  }
  assert {
    condition     = alltrue([for p in values(output.runner_pools) : p.capacity > 1 && p.job.cpus != "" && p.job.memory != "" && p.job.memory_swap == p.job.memory && p.job.disk_gb > 0 && !p.service_account])
    error_message = "A pool runs one job per VM, or a job without its CPU, memory (no swap) and disk share."
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
    build_cache    = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
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
  assert {
    condition     = google_kms_crypto_key.reader.import_only && google_kms_crypto_key.reader.skip_initial_version_creation && google_kms_crypto_key.reader.version_template[0].algorithm == "RSA_SIGN_PKCS1_2048_SHA256" && google_kms_key_ring.reader.location == "us-central1"
    error_message = "The reader app's key is not an import-only RS256 key in us-central1."
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
    build_cache    = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
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
    pools          = {}
    build_cache    = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
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
    pools          = {}
    build_cache    = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
  }
  expect_failures = [var.pool_image]
}

