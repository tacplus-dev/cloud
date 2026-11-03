# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The constants every stack shares, in one place: the organization's domain, the region, the projects' IDs, the
# pipeline's identity and the runner pools. No resource, no provider: each stack reads them with
# `module "settings" { source = "../../modules/settings" }`. bootstrap/bootstrap.sh holds the same names for what
# it creates (tests/settings_test.sh checks they agree).

terraform {
  required_version = ">= 1.13.2"
}

output "domain" {
  description = "The Cloud Identity Free domain whose organization this repository manages."
  value       = "tacplus.dev"
}

output "region" {
  description = "The only region resources may be in (the org policy gcp.resourceLocations)."
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

output "ubuntu_arm64_image" {
  description = "The boot image of every VM: one Ubuntu 24.04 arm64 image by name (never a family), and the Ubuntu archive snapshot its packages come from."
  value = {
    image    = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    snapshot = "20261024T000000Z"
  }
}

output "runner_image" {
  description = <<-EOT
    The runner pools' image (#4, looper#43): baked by looper's `runner-image build` (tacplus-dev/build's job
    runner-image) in the ci project, Docker and the fleeting user already in place, and pinned here by name, never
    by its family: a new bake reaches the workers only through a commit of this pin (ci/runner-image.sh), its plan
    and its apply. image is that name (runner-arm64-docker-<date>-<time>), or null until the first bake: the pools
    then boot ubuntu_arm64_image and install Docker from its snapshot at boot (worker-startup.sh). looper_commit is
    the looper commit the image was baked from, whose runner/startup.sh is the pools' startup-script
    (modules/projects/ci/files/runner-startup.sh, startup_sha256 its SHA-256). bake: the bake's identity.
  EOT
  value = {
    image          = null
    looper_commit  = "03efbe66cdc1ce42dc56276031437712769a8088"
    startup_sha256 = "1a372ed5fb1c1b333a041638d7fbd82fa4fa7ccffc250a95a4ff9e1cbb8ca4f1"
    bake = {
      family         = "runner-arm64-docker"
      account_id     = "runner-image"
      pool           = "gitlab-com"
      provider       = "tacplus-dev-build"
      gitlab_project = "tacplus-dev/build"
      environment    = "runner-image"
    }
  }
}

output "runner_pools" {
  description = <<-EOT
    The runner pools of the ci project: each a managed instance group (size 0 at rest; the manager's autoscaler
    sizes it) of arm64 VMs, used once per job, and its runner registration in GitLab. A pool with
    service_account = true runs as an account of its own with no role (the looper-runner pattern); false, with no
    account and no scopes at all. Registered paused: moving the runners off jody1-328023 is a later issue, which
    unpauses them.
  EOT
  value = {
    loopers = {
      machine_type    = "t2a-standard-8", disk_gb = 100, disk_type = "pd-balanced", max_instances = 5
      service_account = true
      runner          = { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale"], protected = false }
    }
    loopers-big = {
      machine_type    = "t2a-standard-16", disk_gb = 400, disk_type = "pd-standard", max_instances = 2
      service_account = true
      runner          = { type = "group_type", group = "tacplus-dev", project = null, tags = ["arm64", "autoscale-16"], protected = true }
    }
    build = {
      machine_type    = "t2a-standard-8", disk_gb = 100, disk_type = "pd-balanced", max_instances = 5
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/build", tags = ["arm64", "build"], protected = false }
    }
    deploy = {
      machine_type    = "t2a-standard-4", disk_gb = 50, disk_type = "pd-balanced", max_instances = 2
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/fleet-seatrials", tags = ["deploy"], protected = true }
    }
    cluster = {
      machine_type    = "t2a-standard-2", disk_gb = 50, disk_type = "pd-balanced", max_instances = 1
      service_account = false
      runner          = { type = "project_type", group = null, project = "tacplus-dev/cluster", tags = ["cluster"], protected = true }
    }
  }
}
