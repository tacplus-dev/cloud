# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0

variable "projects" {
  description = <<-EOT
    The GitLab projects, by path. create: the module creates the project (false: it exists, and only the settings
    below are managed). protected_branches: pushed and merged by Maintainers only, never force-pushed.
    protected_environments: deployable by Maintainers only. variables: protected project variables (never group
    variables), each either a plain value (not a secret) or a Secret Manager secret version
    (projects/P/secrets/S/versions/N), whose value is never in this repository.
  EOT
  type = map(object({
    create                 = bool
    description            = optional(string, "")
    protected_branches     = list(string)
    protected_environments = list(string)
    variables = map(object({
      value  = optional(string)
      secret = optional(string)
      masked = optional(bool, false)
    }))
  }))
  validation {
    condition = alltrue(flatten([for p in values(var.projects) : [for v in values(p.variables) :
    (v.value == null) != (v.secret == null) && (v.secret == null || can(regex("^projects/[^/]+/secrets/[^/]+/versions/[0-9]+$", v.secret)))]]))
    error_message = "A variable has a value or a secret, not both; a secret is named by its version number (projects/P/secrets/S/versions/N), never latest."
  }
}

variable "runners" {
  description = "The runner registrations, by pool: a group or project runner, its tags, protected refs only or not, and the Secret Manager secret its token is written to (the ci project's runner-token-<pool>). Registered paused: a pool takes jobs only once it is unpaused (paused = false)."
  type = map(object({
    type         = string
    group        = optional(string)
    project      = optional(string)
    tags         = list(string)
    protected    = bool
    paused       = bool
    token_secret = string
  }))
  validation {
    condition     = alltrue([for r in values(var.runners) : (r.type == "group_type" && r.group != null && r.project == null) || (r.type == "project_type" && r.project != null && r.group == null)])
    error_message = "A runner is group_type with a group, or project_type with a project."
  }
}
