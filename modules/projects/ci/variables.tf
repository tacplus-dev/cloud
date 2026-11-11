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

variable "apt_snapshot" {
  description = "The Ubuntu archive snapshot the runner manager installs its packages from (apt --snapshot)."
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

variable "runner" {
  description = "GitLab Runner on the manager: our builds of its and the googlecloud fleeting plugin's tags (ci/runner.sh: version, branch and commit; plugin_version and plugin_commit), each by its SHA-256 (runner_sha256, plugin_sha256), and until the manager installs them (#40), upstream's: the SHA-256 of its two arm64 packages and of the plugin's download."
  type = object({
    version                = string
    branch                 = string
    commit                 = string
    runner_sha256          = string
    plugin_version         = string
    plugin_commit          = string
    plugin_sha256          = string
    deb_sha256             = string
    helper_deb_sha256      = string
    upstream_plugin_sha256 = string
    default_image          = string
  })
  validation {
    condition     = alltrue([for h in [var.runner.runner_sha256, var.runner.plugin_sha256, var.runner.deb_sha256, var.runner.helper_deb_sha256, var.runner.upstream_plugin_sha256] : can(regex("^[0-9a-f]{64}$", h))]) && alltrue([for c in [var.runner.commit, var.runner.plugin_commit] : can(regex("^[0-9a-f]{40}$", c))]) && can(regex("@sha256:[0-9a-f]{64}$", var.runner.default_image))
    error_message = "Every build and download is pinned by its SHA-256, each source by its commit, and the default image by digest."
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
  }))
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
