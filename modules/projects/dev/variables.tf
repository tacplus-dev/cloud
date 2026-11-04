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
  description = "The dev GKE cluster: its name and zone, its release channel, its nodes' disk, and its two node pools (arm64, Axion C4A): normal, a fixed number of on-demand nodes, and spot, the build pool, from 0 to max_nodes."
  type = object({
    name            = string
    zone            = string
    release_channel = string
    disk_gb         = number
    normal = object({
      machine_type = string
      nodes        = number
    })
    spot = object({
      machine_type = string
      max_nodes    = number
    })
  })
  validation {
    condition     = startswith(var.cluster.normal.machine_type, "c4a-") && startswith(var.cluster.spot.machine_type, "c4a-")
    error_message = "The node pools are Axion (c4a-*): arm64."
  }
  validation {
    condition     = var.cluster.normal.nodes >= 1 && var.cluster.spot.max_nodes >= 1
    error_message = "The normal pool has a node, and the spot pool can grow to one."
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

variable "deployments" {
  description = "The deployments whose pipelines own their certificates: each one's GitLab project (protected main only), GitLab environment, certificate domain, and its identity's service account ID and provider name."
  type = map(object({
    gitlab_project = string
    environment    = string
    domain         = string
    account_id     = string
    wif_provider   = string
  }))
  default = {}
  validation {
    condition     = length(distinct([for d in values(var.deployments) : d.environment])) == length(var.deployments) && length(distinct([for d in values(var.deployments) : d.domain])) == length(var.deployments)
    error_message = "Each deployment has an environment and a domain of its own: its ACME account and its challenge zone are its pipeline's alone."
  }
}
