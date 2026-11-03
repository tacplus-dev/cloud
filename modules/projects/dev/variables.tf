# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

variable "project_id" {
  description = "The dev project's ID."
  type        = string
}

variable "name" {
  description = "The dev project's display name."
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

variable "cluster" {
  description = "The dev GKE cluster: its name and zone, its release channel, and its one node pool (arm64, Axion C4A)."
  type = object({
    name            = string
    zone            = string
    release_channel = string
    machine_type    = string
    disk_gb         = number
    min_nodes       = number
    max_nodes       = number
  })
  validation {
    condition     = startswith(var.cluster.machine_type, "c4a-")
    error_message = "The node pool is Axion (c4a-*): arm64."
  }
}

variable "network" {
  description = "The dev network's ranges: nodes, pods, services, the control plane."
  type = object({
    nodes         = string
    pods          = string
    services      = string
    control_plane = string
  })
}

variable "dns" {
  description = "The DNS zone for dev hostnames: its zone name and domain (with the trailing dot)."
  type = object({
    zone   = string
    domain = string
  })
}

variable "cluster_pipeline" {
  description = "The cluster pipeline's identity: its service account's ID, the GitLab project it federates (protected main only), and the pool and provider names."
  type = object({
    account_id     = string
    gitlab_project = string
    pool           = string
    provider       = string
  })
}
