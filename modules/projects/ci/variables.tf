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
  description = "GitLab Runner on the manager: its version, the SHA-256 of its two arm64 packages, and the googlecloud fleeting plugin's version and SHA-256."
  type = object({
    version           = string
    deb_sha256        = string
    helper_deb_sha256 = string
    plugin_version    = string
    plugin_sha256     = string
    default_image     = string
  })
  validation {
    condition     = alltrue([for h in [var.runner.deb_sha256, var.runner.helper_deb_sha256, var.runner.plugin_sha256] : can(regex("^[0-9a-f]{64}$", h))]) && can(regex("@sha256:[0-9a-f]{64}$", var.runner.default_image))
    error_message = "Every download is pinned by its SHA-256, and the default image by digest."
  }
}

variable "pools" {
  description = "The runner pools (modules/settings runner_pools): one instance template and managed instance group each, a runner-token secret, and with service_account, an account of its own with no role."
  type = map(object({
    machine_type    = string
    disk_gb         = number
    disk_type       = string
    max_instances   = number
    service_account = bool
  }))
}

variable "build_buckets" {
  description = "The build buckets, by name suffix (<project>-<suffix>): how many days an object is kept."
  type        = map(number)
}

variable "reader_app_key" {
  description = "The tacplus-reader GitHub App's key in Cloud KMS: key ring and key name. Created empty, import-only: the app's key is imported into it when the reader moves off jody1-328023."
  type = object({
    key_ring = string
    key      = string
  })
}
