# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

variable "parent_folder" {
  description = "The folder the host organization hands over, folders/<ID>: the folders are created under it, and the readers read it."
  type        = string
  validation {
    condition     = can(regex("^folders/[0-9]+$", var.parent_folder))
    error_message = "The parent folder is folders/<ID>."
  }
}

variable "folders" {
  description = "The folders the pipeline creates under the parent folder (bootstrap's is the script's)."
  type        = list(string)
}

variable "pipeline_sa" {
  description = "The pipeline's service account (cloud-admin-pipeline), owner of the folders' contents."
  type        = string
}

variable "readers" {
  description = "Who reads the parent folder: viewer and securityReviewer, nothing that writes. Members as IAM writes them (user:, group:, serviceAccount:), of a domain the host organization's iam.allowedPolicyMemberDomains admits."
  type        = list(string)
  validation {
    condition     = alltrue([for m in var.readers : can(regex("^(user|group|serviceAccount):[^@]+@[^@]+$", m))])
    error_message = "A reader is user:, group: or serviceAccount: and an email."
  }
}
