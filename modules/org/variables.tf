# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

variable "domain" {
  description = "The organization's domain."
  type        = string
}

variable "region" {
  description = "The only region resources may be created in."
  type        = string
}

variable "folders" {
  description = "The folders the pipeline creates under the organization (bootstrap's is the script's)."
  type        = list(string)
}

variable "pipeline_sa" {
  description = "The pipeline's service account (cloud-admin-pipeline), owner of the folders' contents."
  type        = string
}

variable "readers" {
  description = "Who reads the organization: viewer and securityReviewer, nothing that writes. Members as IAM writes them (user:, group:, serviceAccount:), of the organization's domain (the org policy iam.allowedPolicyMemberDomains)."
  type        = list(string)
  validation {
    condition     = alltrue([for m in var.readers : can(regex("^(user|group|serviceAccount):[^@]+@[^@]+$", m))])
    error_message = "A reader is user:, group: or serviceAccount: and an email."
  }
}
