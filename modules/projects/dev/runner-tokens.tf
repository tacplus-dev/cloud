# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The in-cluster runners' tokens (#18; tacplus-dev/cluster#7, its tacplus.token): one secret each, created empty. The
# hub registers each runner through GitLab's API and pipes its token into a new version, as one of the listed adders,
# who add versions and never read them (secretVersionAdder has no versions.access); cluster-admin-pipeline reads them.
# A new token is a new version, and a pull request in tacplus-dev/cluster. Nobody else holds a role on either
# (authoritative bindings: a grant added by hand is drift).

locals {
  runner_tokens = { build = "gitlab-runner-build", control = "gitlab-runner-control" }
  # With no adder, no binding of the role: nobody adds versions.
  runner_token_members = merge(
    { "roles/secretmanager.secretAccessor" = [google_service_account.cluster_pipeline.member] },
    length(var.runner_token_adders) > 0 ? { "roles/secretmanager.secretVersionAdder" = var.runner_token_adders } : {},
  )
}

resource "google_secret_manager_secret" "runner_token" {
  for_each  = toset(values(local.runner_tokens))
  project   = google_project.dev.project_id
  secret_id = each.key
  labels    = { managed-by = "tacplus-dev-cloud" }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_secret_manager_secret_iam_binding" "runner_token" {
  for_each  = { for p in setproduct(values(local.runner_tokens), keys(local.runner_token_members)) : "${p[0]}/${p[1]}" => { secret = p[0], role = p[1] } }
  project   = google_project.dev.project_id
  secret_id = google_secret_manager_secret.runner_token[each.value.secret].secret_id
  role      = each.value.role
  members   = local.runner_token_members[each.value.role]
}
