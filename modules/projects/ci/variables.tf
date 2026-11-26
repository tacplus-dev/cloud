# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

variable "project_id" {
  description = "The ci project's ID."
  type        = string
}

variable "name" {
  description = "The ci project's display name."
  type        = string
}

variable "folder" {
  description = "The folder the project is in (folders/N)."
  type        = string
}

variable "billing_account" {
  description = "The billing account the project is linked to (the bootstrap project's)."
  type        = string
}

variable "region" {
  description = "The region of every regional resource."
  type        = string
}

variable "zone" {
  description = "The zone of the runner manager and the pools' instance groups (one that has t2a, arm64)."
  type        = string
}

variable "subnet_cidr" {
  description = "The runners' subnet."
  type        = string
}

variable "image" {
  description = "The runner manager's boot image, by name (never a family)."
  type        = string
}

variable "pool_image" {
  description = "The pools' boot image: Container-Optimized OS for arm64, by name (never a family)."
  type        = string
  validation {
    condition     = can(regex("^projects/cos-cloud/global/images/cos-arm64-[0-9]+-[0-9]+-[0-9]+-[0-9]+$", var.pool_image))
    error_message = "The pools boot Container-Optimized OS for arm64 pinned by its image name (projects/cos-cloud/global/images/cos-arm64-<milestone>-<build>), never a family."
  }
}

variable "manager_machine_type" {
  description = "The runner manager's machine type (arm64)."
  type        = string
}

variable "manager_disk_gb" {
  description = "The runner manager's pd-balanced boot disk, in GB (modules/settings ci_disks: counted against SSD_TOTAL_GB with the pools' SSD-backed disks, #63). Part of the manager's build: a change replaces it (a handoff)."
  type        = number
  default     = 20
}

variable "manager_handoff_minutes" {
  description = "The cap on a manager handoff (#51): a new manager starts taking jobs at most this long after it boots. The old one drains until 12 minutes before it, then the jobs still on it are cut (failed as runner_interrupted, with up to 8 minutes to tell GitLab, #54; the cloud pipeline's handoff job runs them again); the last minutes delete the old manager and empty the groups."
  type        = number
  default     = 30
  validation {
    condition     = var.manager_handoff_minutes >= 17 && floor(var.manager_handoff_minutes) == var.manager_handoff_minutes
    error_message = "The handoff's cap is a whole number of minutes, 17 or more: 12 are kept for the cut, its report and the emptied groups, and 5 left to drain."
  }
}

variable "runner" {
  description = "GitLab Runner on the manager: our builds of its and the googlecloud fleeting plugin's tags (ci/runner.sh: version, branch and commit; plugin_version and plugin_commit), each installed by its SHA-256 (runner_sha256, plugin_sha256); the helper image its jobs run beside, and the default job image, by digest."
  type = object({
    version        = string
    branch         = string
    commit         = string
    runner_sha256  = string
    plugin_version = string
    plugin_commit  = string
    plugin_sha256  = string
    helper_image   = string
    default_image  = string
  })
  validation {
    condition     = alltrue([for h in [var.runner.runner_sha256, var.runner.plugin_sha256] : can(regex("^[0-9a-f]{64}$", h))]) && alltrue([for c in [var.runner.commit, var.runner.plugin_commit] : can(regex("^[0-9a-f]{40}$", c))]) && alltrue([for i in [var.runner.helper_image, var.runner.default_image] : can(regex("@sha256:[0-9a-f]{64}$", i))])
    error_message = "Every build is pinned by its SHA-256, each source by its commit, and the helper and default images by digest."
  }
}

variable "runner_bin" {
  description = "The directory of our builds of GitLab Runner and the fleeting plugin (ci/runner.sh; the tools job's bin/manager), uploaded to the manager's bucket."
  type        = string
}

variable "pools" {
  description = "The runner pools (modules/settings runner_pools): one instance template and managed instance group each, a runner-token secret, and with service_account, an account of its own with no role. Each VM runs capacity jobs at once (more than one), each container within its job's limits; its disk is capacity times a job's disk_gb, plus os_disk_gb."
  type = map(object({
    machine_type  = string
    disk_type     = string
    os_disk_gb    = number
    capacity      = number
    max_instances = number
    idle_count    = number
    idle_time     = string
    job = object({
      cpus         = string
      memory       = string
      memory_swap  = string
      disk_gb      = number
      security_opt = list(string)
    })
    service_account = bool
    # Spot VMs (Jody, 2026-11-10: "builds run on the spot instances"): GCP may reclaim one at any time, and the job on
    # it fails and is retried; the always-on nodes are never spot.
    spot = optional(bool, false)
    # The zones of the region the pool spreads over (#49): its group is regional, and makes each VM in whichever of
    # them has the capacity. Empty: a zonal group in zone.
    zones = optional(list(string), [])
  }))
  validation {
    condition     = alltrue([for p in values(var.pools) : length(p.zones) == 0 || (length(p.zones) > 1 && length(distinct(p.zones)) == length(p.zones) && alltrue([for z in p.zones : can(regex("^${var.region}-[a-z]$", z))]))])
    error_message = "A pool spreads over two zones or more of the region, each once (one zone is the stack's zone's job)."
  }
  validation {
    condition     = alltrue([for p in values(var.pools) : p.capacity > 1 && p.idle_count <= p.max_instances && can(regex("^[0-9.]+$", p.job.cpus)) && can(regex("^[0-9]+[mg]$", p.job.memory)) && p.job.memory_swap == p.job.memory && p.job.disk_gb > 0])
    error_message = "Every pool runs more than one job per VM, keeps no more idle VMs than its maximum, and limits each job's CPUs, memory (no swap: memory_swap the same) and disk share."
  }
}

variable "build_cache" {
  description = "The build cache (decisions/builds-in-containers-2026-11-03.md): a bucket <project>-<name> and a Docker registry <name>, an entry deleted once unused for days; written and read by the service account account_id only, which only the jobs of gitlab_project become, through the Workload Identity Federation pool wif_pool and its provider wif_provider for gitlab.com."
  type = object({
    name           = string
    days           = number
    gitlab_project = string
    account_id     = string
    wif_pool       = string
    wif_provider   = string
  })
}

variable "github_apps" {
  description = "The GitHub Apps' keys (modules/settings github_apps): the key ring key_ring, the workload identity pool wif_pool, the namespace's provider (namespace: its GitLab ID and provider ID) and the looper project's (looper: its GitLab project ID, the ref its signers run on and its provider ID); pools, other projects' workload identity pools by name (projects/N/locations/global/workloadIdentityPools/P), whose providers map attribute.project_path; per key, import (an import job, and the importers' bindings), namespace (the namespace's protected refs sign), environments (the looper project's environments that sign), accounts (by account ID, an account here that signs, which only gitlab_project's jobs federated through pool may become) and projects (GitLab projects whose jobs, federated through pool, sign as themselves)."
  type = object({
    key_ring  = string
    wif_pool  = string
    namespace = object({ id = string, wif_provider = string })
    looper    = object({ project_id = string, ref = string, wif_provider = string })
    pools     = optional(map(string), {})
    keys = map(object({
      import       = bool
      namespace    = bool
      environments = list(string)
      accounts     = optional(map(object({ pool = string, gitlab_project = string })), {})
      projects     = optional(list(object({ pool = string, gitlab_project = string })), [])
    }))
  })
  validation {
    condition     = can(regex("^[0-9]+$", var.github_apps.namespace.id)) && can(regex("^[0-9]+$", var.github_apps.looper.project_id)) && alltrue([for k in values(var.github_apps.keys) : alltrue([for e in k.environments : can(regex("^[a-z0-9][a-z0-9-]*$", e))])])
    error_message = "The namespace and the looper project are GitLab's numeric IDs, and an environment is a GitLab environment's name."
  }
  validation {
    condition     = alltrue(flatten([for k in values(var.github_apps.keys) : [for s in concat(values(k.accounts), k.projects) : contains(keys(var.github_apps.pools), s.pool) && can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.github_apps.pools[s.pool])) && can(regex("^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$", s.gitlab_project))]])) && alltrue([for id in flatten([for k in values(var.github_apps.keys) : keys(k.accounts)]) : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", id))])
    error_message = "An account's or a project's pool is not one of pools, a pool's resource name, or its GitLab project not a project's path; or an account ID is not a service account's."
  }
  validation {
    condition     = length(flatten([for k in values(var.github_apps.keys) : keys(k.accounts)])) == length(distinct(flatten([for k in values(var.github_apps.keys) : keys(k.accounts)])))
    error_message = "Two keys have the same account: an account signs for one key."
  }
  validation {
    condition     = !contains(try(var.github_apps.keys["tacplus-manager"].environments, []), "looper-report")
    error_message = "tacplus-manager never signs for looper-report: a report's code runs in its job, and would mint the bypass of main's ruleset (tacplus-dev/looper#90)."
  }
}

variable "kms_key_importers" {
  description = "Who imports the apps' keys (github-apps.tf): roles/cloudkms.importer on each import job and the versions-create permission on each key with one. Members as IAM writes them (user:, group:, serviceAccount:), of a domain the host organization's iam.allowedPolicyMemberDomains admits. Empty: nobody."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for m in var.kms_key_importers : can(regex("^(user|group|serviceAccount):[^@]+@[^@]+$", m))])
    error_message = "An importer is user:, group: or serviceAccount: and an email."
  }
}

variable "admiral" {
  description = "The Admiral's credentials (admiral.tf, #84): its account's ID, here; the workload identity pool (projects/N/locations/global/workloadIdentityPools/P) whose provider admits its fleet kernel's issuer, and its subject there (its SPIFFE ID), which alone becomes it; key, the github_apps key it alone signs with; and secret, the ID of the secret it alone reads. Null: none."
  type = object({
    account_id = string
    pool       = string
    subject    = string
    key        = string
    secret     = string
  })
  default = null
  validation {
    condition     = var.admiral == null ? true : (can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.admiral.account_id)) && can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.admiral.pool)) && can(regex("^spiffe://[a-z0-9.-]+(/[A-Za-z0-9._-]+)+$", var.admiral.subject)) && contains(keys(var.github_apps.keys), var.admiral.key) && can(regex("^[A-Za-z0-9_-]{1,255}$", var.admiral.secret)))
    error_message = "The Admiral's account ID is not a service account's, its pool not a pool's resource name, its subject not a SPIFFE ID, its key not one of github_apps' keys, or its secret not a secret's ID."
  }
}

variable "admiral_secret_adders" {
  description = "Who adds the Admiral's secret's versions by hand (admiral.tf): secretVersionAdder on it, which adds versions and reads none. Members as IAM writes them (user:, group:, serviceAccount:), of a domain the host organization's iam.allowedPolicyMemberDomains admits. Empty: nobody."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for m in var.admiral_secret_adders : can(regex("^(user|group|serviceAccount):[^@]+@[^@]+$", m))])
    error_message = "An adder is user:, group: or serviceAccount: and an email."
  }
}

variable "hub_audit" {
  description = "The audit job's account (#77, hub-audit.tf): its account ID, here; the projects it reads and its roles on each, read roles only; the workload identity pool (projects/N/locations/global/workloadIdentityPools/P, whose provider maps attribute.project_path) and the GitLab project whose jobs alone become it; and autoscaler_log (#85), whether it reads the cluster autoscaler's log: the view hub-audit-autoscaler on each project's _Default bucket and roles/logging.viewAccessor on that view alone, false (none) until the host grants the pipeline roles/logging.configWriter, which the views need."
  type = object({
    account_id     = string
    projects       = list(string)
    roles          = list(string)
    pool           = string
    gitlab_project = string
    autoscaler_log = optional(bool, false)
  })
  validation {
    condition     = alltrue([for r in var.hub_audit.roles : contains(["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"], r)])
    error_message = "hub-audit reads only: its roles are compute, container, monitoring, secretmanager and cloudquotas viewer and serviceusage.serviceUsageConsumer (ci/policy.sh refuses any other in a plan too)."
  }
  validation {
    condition     = can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.hub_audit.pool)) && can(regex("^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$", var.hub_audit.gitlab_project))
    error_message = "hub-audit's pool is not a pool's resource name, or its GitLab project not a project's path."
  }
}

variable "looper_vms" {
  description = "The looper VMs (looper-vms.tf, #108; decisions/looper-build-vms-2026-11-24.md), by tacplus-dev repository name, or with org set an org's shared VM (decision point 12) by any name: each a zonal instance group of 0..1 arm64 VMs on looper_vm_os_image, machine_type (C4A) with a disk_gb Hyperdisk Balanced boot disk (its cache), spot or not, running image (the looper-vm image, by digest; empty: the VM runs nothing), as an account of its own, looper-vm-<name>. A shared VM works every org repository but those with a VM of their own (the entries with no org)."
  type = map(object({
    machine_type = string
    disk_gb      = number
    spot         = bool
    image        = string
    org          = optional(string, "")
  }))
  default = {}
  validation {
    condition     = alltrue([for k, v in var.looper_vms : can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", k)) && can(regex("^c4a-", v.machine_type)) && v.disk_gb >= 10 && floor(v.disk_gb) == v.disk_gb && (v.image == "" || can(regex("^[^[:space:]@]+@sha256:[0-9a-f]{64}$", v.image))) && (v.org == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", v.org)))])
    error_message = "A looper VM is named by its repository (lowercase, 2 to 20 characters: looper-vm-<name> is its account's ID), is a C4A machine (arm64, Hyperdisk Balanced), has a whole disk of 10 GB or more, runs an image by digest, or none (\"\"), and names an org (a shared VM) or none."
  }
}

variable "looper_vm_os_image" {
  description = "The looper VMs' boot image: stock Container-Optimized OS for arm64, by name (never a family), as pool_image."
  type        = string
  validation {
    condition     = can(regex("^projects/cos-cloud/global/images/cos-arm64-[0-9]+-[0-9]+-[0-9]+-[0-9]+$", var.looper_vm_os_image))
    error_message = "The looper VMs boot Container-Optimized OS for arm64 pinned by its image name (projects/cos-cloud/global/images/cos-arm64-<milestone>-<build>), never a family."
  }
}

variable "looper_vm_app_key" {
  description = "The GitHub App key (github_apps' keys) each looper VM's account signs with: the reports' (tacplus-looper), never the manager's."
  type        = string
  default     = "tacplus-looper"
  validation {
    condition     = (length(var.looper_vms) == 0 || contains(keys(var.github_apps.keys), var.looper_vm_app_key)) && var.looper_vm_app_key != "tacplus-manager"
    error_message = "The looper VMs' key is not one of github_apps' keys (with looper VMs), or is tacplus-manager: a looper VM's code runs on its VM, and would mint the bypass of main's ruleset (tacplus-dev/looper#90)."
  }
}

variable "reserved_vms" {
  description = "The reserved machines (reserved-vms.tf, #111; tacplus-dev/roadmap decisions/agentic-dev-flow-2026-11-25.md), by name: each a zonal instance group of one on-demand arm64 VM on looper_vm_os_image (none while image is empty), machine_type (C4A) with a disk_gb Hyperdisk Balanced boot disk (its own cache), running image (the looper image, by digest) in its role, check (the rolling check of main: looper-vm check, its builds through the container socket) or merger (looper-vm merger, no container socket: it runs no project code), for the tacplus-dev repository repo or every repository of the org org (an org's check, every one but those with a check of their own), as an account of its own, <name>, which writes logs and signs with key alone. A merger's key has no other signer."
  type = map(object({
    role         = string
    repo         = optional(string, "")
    org          = optional(string, "")
    machine_type = string
    disk_gb      = number
    image        = string
    key          = string
  }))
  default = {}
  validation {
    condition     = alltrue([for k, v in var.reserved_vms : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", k)) && contains(["check", "merger"], v.role) && ((v.repo == "") != (v.org == "")) && (v.repo == "" || can(regex("^[a-z0-9][a-z0-9._-]*$", v.repo))) && (v.org == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", v.org))) && can(regex("^c4a-", v.machine_type)) && v.disk_gb >= 10 && floor(v.disk_gb) == v.disk_gb && (v.image == "" || can(regex("^[^[:space:]@]+@sha256:[0-9a-f]{64}$", v.image)))])
    error_message = "A reserved machine is named as an account (6 to 30 characters: <name> is its account's ID), is a check or a merger, serves a repository or an org (one of them), is a C4A machine (arm64, Hyperdisk Balanced), has a whole disk of 10 GB or more, and runs an image by digest, or none (\"\")."
  }
  # Its key is its own (the panel's finding 5): never the reports' (looper_vm_app_key, which model-written code signs
  # with) nor the managers' (the bypass of main's ruleset); a merger's, the one that accepts and merges, signed by no
  # job, account or other machine, and a check's never a merger's.
  validation {
    condition     = alltrue([for k, v in var.reserved_vms : contains(keys(var.github_apps.keys), v.key) && v.key != var.looper_vm_app_key && v.key != "tacplus-manager" && (v.role != "merger" || (length(var.github_apps.keys[v.key].environments) == 0 && !var.github_apps.keys[v.key].namespace && length(var.github_apps.keys[v.key].accounts) == 0 && length(var.github_apps.keys[v.key].projects) == 0 && length([for o, w in var.reserved_vms : o if w.key == v.key]) == 1)) && (v.role != "check" || !anytrue([for o, w in var.reserved_vms : w.role == "merger" && w.key == v.key]))])
    error_message = "A reserved machine's key is not one of github_apps' keys, is the reports' (looper_vm_app_key) or tacplus-manager, or is a merger's that something else signs with too (a job, an account, a project, another machine)."
  }
}
