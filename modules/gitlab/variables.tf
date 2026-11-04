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

variable "members" {
  description = <<-EOT
    Memberships of users in projects, by PROJECT:USER (the project's path, the user's username): access_level
    guest or reporter, never higher (the readers of a project this module does not otherwise manage, #12), and
    expires_at, a date YYYY-MM-DD, always: renewing it is a commit of a later date (the drift job reports one within
    30 days, ci/expiry.sh).
  EOT
  type = map(object({
    access_level = string
    expires_at   = string
  }))
  default = {}
  validation {
    condition = alltrue([for k, m in var.members :
    can(regex("^[^:]+/[^:]+:[^:/]+$", k)) && contains(["guest", "reporter"], m.access_level) && can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", coalesce(m.expires_at, "-")))])
    error_message = "A member is PROJECT:USER, guest or reporter (nothing higher), with expires_at a date YYYY-MM-DD."
  }
}
