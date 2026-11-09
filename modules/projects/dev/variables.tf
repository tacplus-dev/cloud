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

variable "zone" {
  description = "The domain's own zone (tacplus.dev), written only by this pipeline (#13): its zone name, its domain (with the trailing dot) and the records copied from the zone it replaces (names with the trailing dot, rrdatas as Cloud DNS writes them). The deployments' hostnames, to the gateway's address, and the delegations of the dev zone and the challenge zones are added to them."
  type = object({
    zone   = string
    domain = string
    records = list(object({
      name    = string
      type    = string
      ttl     = number
      rrdatas = list(string)
    }))
  })
  validation {
    condition     = alltrue([for r in var.zone.records : (r.name == var.zone.domain || endswith(r.name, ".${var.zone.domain}")) && r.type != "SOA" && !(r.type == "NS" && r.name == var.zone.domain)])
    error_message = "A copied record is outside the zone's domain, or is its SOA or its own NS: Cloud DNS writes those."
  }
  validation {
    condition     = length(distinct([for r in var.zone.records : "${r.name} ${r.type}"])) == length(var.zone.records)
    error_message = "Two copied records have the same name and type: one record set each."
  }
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
  description = "The deployments whose pipelines own their certificates: each one's GitLab project (protected main only), GitLab environment, certificate domain, its hostnames (in the zone, behind the gateway's address), and its identity's service account ID and provider name; optionally its images (deploy.tf): its deploy registry's name, its build bucket's name (after the project ID), the service account ID its Cloud Build builds run as and the days the bucket keeps an object; and its environment accounts (deploy.tf): by GitLab environment, the service account ID only its project's jobs in that environment, on protected main, may become; and its init_secrets (fleet-secrets.tf): the GitLab environment of its init-secrets job and the service account ID only its project's jobs in that environment, on protected main, may become, which adds the versions of its fleet secrets."
  type = map(object({
    gitlab_project = string
    environment    = string
    domain         = string
    hostnames      = list(string)
    account_id     = string
    wif_provider   = string
    images = optional(object({
      registry   = string
      bucket     = string
      account_id = string
      days       = number
    }))
    environment_accounts = optional(map(string), {})
    init_secrets = optional(object({
      environment = string
      account_id  = string
    }))
  }))
  default = {}
  validation {
    condition     = length(distinct([for d in values(var.deployments) : d.environment])) == length(var.deployments) && length(distinct([for d in values(var.deployments) : d.domain])) == length(var.deployments)
    error_message = "Each deployment has an environment and a domain of its own: its ACME account and its challenge zone are its pipeline's alone."
  }
  validation {
    condition     = length(flatten([for d in values(var.deployments) : concat([d.account_id], d.images == null ? [] : [d.images.account_id], values(d.environment_accounts), d.init_secrets == null ? [] : [d.init_secrets.account_id])])) == length(distinct(flatten([for d in values(var.deployments) : concat([d.account_id], d.images == null ? [] : [d.images.account_id], values(d.environment_accounts), d.init_secrets == null ? [] : [d.init_secrets.account_id])])))
    error_message = "A deployment's identity, its builds' account, its environment accounts and its init-secrets account are each an account of its own."
  }
  validation {
    condition     = alltrue([for d in values(var.deployments) : d.init_secrets == null || !contains(concat([d.environment], keys(d.environment_accounts)), try(d.init_secrets.environment, ""))])
    error_message = "A deployment's init-secrets job has a GitLab environment of its own: no other of its jobs becomes its account."
  }
}

variable "runner_token_adders" {
  description = "Who adds the runners' token versions (runner-tokens.tf): secretVersionAdder on gitlab-runner-build and gitlab-runner-control, which adds versions and reads none. Members as IAM writes them (user:, group:, serviceAccount:), of a domain the host organization's iam.allowedPolicyMemberDomains admits. Empty: nobody."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for m in var.runner_token_adders : can(regex("^(user|group|serviceAccount):[^@]+@[^@]+$", m))])
    error_message = "An adder is user:, group: or serviceAccount: and an email."
  }
}

variable "load_balancer" {
  description = "The global external proxy Network Load Balancer (TCP proxy) on the address gateway (load-balancer.tf, #21): by listener name, its port on the address, the name of the standalone zonal NEG its connections go to (in the cluster's zone), the port of that NEG's endpoints (the pods'), and whether the NEG exists yet (false: no backend)."
  type = map(object({
    port          = number
    neg           = string
    endpoint_port = number
    ready         = bool
  }))
  default = {}
  validation {
    condition     = alltrue([for k, l in var.load_balancer : can(regex("^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$", k)) && can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", l.neg)) && l.port >= 1 && l.port <= 65535 && l.endpoint_port >= 1 && l.endpoint_port <= 65535])
    error_message = "A listener's name or its NEG's is not a GCE name, or a port is not 1 to 65535."
  }
  validation {
    condition     = length(distinct([for l in values(var.load_balancer) : l.port])) == length(var.load_balancer) && length(distinct([for l in values(var.load_balancer) : l.neg])) == length(var.load_balancer)
    error_message = "Two listeners share a port of the address or a NEG: a TCP proxy does not route by SNI, so each port goes to one NEG."
  }
}
