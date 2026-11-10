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
    # More projects a project runner serves (gitlab_project_runner_enablement), e.g. the cluster pool's runner also
    # running tacplus-dev/cloud's own pipeline (2026-11-10, off jody1-328023).
    also_projects = optional(list(string), [])
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

variable "build" {
  description = <<-EOT
    tacplus-dev/build, the build pipeline (#26; tacplus-dev/looper#71, #84), or null. project: its path. ci_file: its
    .gitlab-ci.yml (tacplus-dev/looper's ci/build.gitlab-ci.yml, copied as is) and the commit message naming its
    source, or null to leave the file alone. trigger: its pipeline trigger, rotated whenever rotate_by (a date
    YYYY-MM-DD in the commit, never computed) changes, its token the protected, masked variable key of the project
    variable_project (a path or ID). schedules: by name, a schedule on main, its cron (UTC) and its inputs.
  EOT
  type = object({
    project = string
    ci_file = optional(object({
      content        = string
      commit_message = string
    }))
    trigger = object({
      description      = string
      rotate_by        = string
      variable_project = string
      variable_key     = string
    })
    schedules = map(object({
      cron   = string
      inputs = map(string)
    }))
  })
  default = null
  validation {
    condition     = var.build == null || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.build.trigger.rotate_by))
    error_message = "The build trigger's rotate_by is a date YYYY-MM-DD."
  }
  validation {
    condition = var.build == null || alltrue([for s in values(var.build.schedules) :
    length(split(" ", s.cron)) == 5 && length(s.inputs) > 0 && length(s.inputs) <= 20])
    error_message = "A build schedule has a cron of five fields and between 1 and 20 inputs."
  }
}
