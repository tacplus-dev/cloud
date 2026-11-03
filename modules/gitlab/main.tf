# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# GitLab settings: projects, their protected branches and environments, their protected project variables (values
# from Secret Manager, never in this repository), and the runner registrations, whose tokens go to Secret Manager
# for the runner manager.

locals {
  existing = { for path, p in var.projects : path => p if !p.create }
  created  = { for path, p in var.projects : path => p if p.create }
  project_id = merge(
    { for path, p in data.gitlab_project.existing : path => p.id },
    { for path, p in gitlab_project.created : path => p.id },
  )
  # The projects a project runner is registered to, managed here or not.
  runner_projects = toset([for r in values(var.runners) : r.project if r.project != null && !contains(keys(var.projects), coalesce(r.project, "-"))])
  runner_project_id = merge(
    { for path, p in data.gitlab_project.runner : path => p.id },
    local.project_id,
  )
  branches     = merge([for path, p in var.projects : { for b in p.protected_branches : "${path}:${b}" => { project = path, branch = b } }]...)
  environments = merge([for path, p in var.projects : { for e in p.protected_environments : "${path}:${e}" => { project = path, environment = e } }]...)
  variables    = merge([for path, p in var.projects : { for k, v in p.variables : "${path}:${k}" => merge(v, { project = path, key = k }) }]...)
  secrets      = { for id, v in local.variables : id => v.secret if v.secret != null }
}

data "gitlab_project" "existing" {
  for_each            = local.existing
  path_with_namespace = each.key
}

data "gitlab_project" "runner" {
  for_each            = local.runner_projects
  path_with_namespace = each.key
}

resource "gitlab_project" "created" {
  for_each               = local.created
  name                   = basename(each.key)
  path                   = basename(each.key)
  namespace_id           = data.gitlab_group.namespace[dirname(each.key)].group_id
  description            = each.value.description
  visibility_level       = "public"
  shared_runners_enabled = false
  lifecycle {
    prevent_destroy = true
  }
}

data "gitlab_group" "namespace" {
  for_each  = toset(concat([for path in keys(local.created) : dirname(path)], [for r in values(var.runners) : r.group if r.group != null]))
  full_path = each.key
}

resource "gitlab_branch_protection" "branch" {
  for_each           = local.branches
  project            = local.project_id[each.value.project]
  branch             = each.value.branch
  push_access_level  = "maintainer"
  merge_access_level = "maintainer"
  allow_force_push   = false
}

resource "gitlab_project_protected_environment" "environment" {
  for_each                       = local.environments
  project                        = local.project_id[each.value.project]
  environment                    = each.value.environment
  deploy_access_levels_attribute = [{ access_level = "maintainer" }]
}

data "google_secret_manager_secret_version" "variable" {
  for_each = local.secrets
  secret   = regex("^(projects/[^/]+/secrets/[^/]+)/versions/", each.value)[0]
  version  = regex("/versions/([0-9]+)$", each.value)[0]
}

resource "gitlab_project_variable" "variable" {
  for_each          = local.variables
  project           = local.project_id[each.value.project]
  key               = each.value.key
  value             = each.value.secret != null ? data.google_secret_manager_secret_version.variable[each.key].secret_data : each.value.value
  protected         = true
  masked            = each.value.masked
  raw               = true
  environment_scope = "*"
}

resource "gitlab_user_runner" "runner" {
  for_each     = var.runners
  runner_type  = each.value.type
  group_id     = each.value.type == "group_type" ? data.gitlab_group.namespace[each.value.group].group_id : null
  project_id   = each.value.type == "project_type" ? local.runner_project_id[each.value.project] : null
  description  = "tacplus-ci ${each.key} (tacplus-dev/cloud: runner-manager in the ci project)"
  tag_list     = each.value.tags
  untagged     = false
  paused       = each.value.paused
  access_level = each.value.protected ? "ref_protected" : "not_protected"
  locked       = each.value.type == "project_type"
}

# The runner's token, for the manager (modules/projects/ci). A re-registered runner replaces the version, so the
# secret's only enabled version is the live token.
resource "google_secret_manager_secret_version" "runner_token" {
  for_each    = var.runners
  secret      = each.value.token_secret
  secret_data = gitlab_user_runner.runner[each.key].token
}
