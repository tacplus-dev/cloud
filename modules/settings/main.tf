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
    gitlab_token_secret = "projects/tacplus-bootstrap/secrets/gitlab-token/versions/1"
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

output "deployments" {
  description = <<-EOT
    The deployments whose pipelines own their TLS certificates (decisions/certificates-by-pipeline-2026-11-03.md,
    #6), each with an identity of its own in the dev project, federated from its GitLab project's protected main:
    gitlab_project, account_id and wif_provider. It alone adds and reads the versions of the secrets
    tls-<deployment> (the certificate and its key) and acme-account-<environment> (its ACME account key; environment
    is the deployment's GitLab environment), and it alone administers the zone for _acme-challenge.<domain> (the
    certificate is <domain> and *.<domain>, so DNS-01 writes there only), delegated from <domain>'s zone.
  EOT
  value = {
    # Its pipeline still runs as seatrials-deploy@jody1-328023 against the interim secrets and zone there (README,
    # Certificates); it becomes this identity when seatrials moves off jody1-328023.
    seatrials = { gitlab_project = "tacplus-dev/fleet-seatrials", environment = "seatrials", domain = "tacplus.dev", account_id = "seatrials-deploy", wif_provider = "tacplus-dev-fleet-seatrials" }
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
  # How many jobs a machine type runs at once at a job's limits below; what is left is the OS's, Docker's and the
  # runner's helper containers' (8 vCPU and 32 GB: two jobs of 4 CPUs and 14g, 4 GB left).
  shared_capacity = { "t2a-standard-8" = 2, "t2a-standard-16" = 4 }

  # The job containers' settings, the agents' and the builds' kept apart (#5): the shared pool runs both under one
  # registration, so with one setting, today the builds' (the same as the agents'). If the build jobs need settings
  # the agents must not get (rootless BuildKit's seccomp and apparmor, tacplus-dev/tacplus#315), the split is a
  # build pool of its own with job = local.jobs.build, and the shared pool's job = local.jobs.agent. disk_gb is a
  # job's share of its VM's disk: the disk is bounded per VM, not per job (Container-Optimized OS has no per-container
  # disk limit, #5), so a job that fills it fails the jobs beside it.
  jobs = {
    agent = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }
    build = { cpus = "4", memory = "14g", memory_swap = "14g", disk_gb = 100, security_opt = [] }
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
    # Always on: agent jobs (the loopers' tags), build jobs (tacplus-dev/build's) and the control jobs (the
    # kicker, the planner, the recap, the drift) on one VM. The build identity is not on the VM: build jobs become it
    # through Workload Identity Federation (the ci module's build cache).
    shared = {
      machine_type    = local.shared_machine_type, disk_type = "pd-balanced", os_disk_gb = 50
      capacity        = local.shared_capacity[local.shared_machine_type], max_instances = 1, idle_count = 1, idle_time = "30m"
      job             = local.jobs.build
      service_account = false
      runner          = { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale", "autoscale-16", "build"], protected = false }
    }
    # On demand, protected: their credentials never share a VM with agents. A VM stays for 30 minutes idle.
    deploy = {
      machine_type    = "t2a-standard-4", disk_type = "pd-balanced", os_disk_gb = 30
      capacity        = 2, max_instances = 1, idle_count = 0, idle_time = "30m"
      job             = { cpus = "2", memory = "6g", memory_swap = "6g", disk_gb = 25, security_opt = [] }
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/fleet-seatrials", tags = ["deploy"], protected = true }
    }
    cluster = {
      machine_type    = "t2a-standard-2", disk_type = "pd-balanced", os_disk_gb = 30
      capacity        = 2, max_instances = 1, idle_count = 0, idle_time = "30m"
      job             = { cpus = "1", memory = "3g", memory_swap = "3g", disk_gb = 10, security_opt = [] }
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/cluster", tags = ["cluster"], protected = true }
    }
  }
}
