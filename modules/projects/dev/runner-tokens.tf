# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The in-cluster runners' tokens (#18; tacplus-dev/cluster#7, its tacplus.token): one secret each, created empty. For
# build and control, the hub registers the runner through GitLab's API and pipes its token into a new version, as one
# of the listed adders, who add versions and never read them (secretVersionAdder has no versions.access). For infra
# (#64; tacplus-dev/cluster#25), the gitlab stack registers the runner and writes its token as version 1, as this
# pipeline (its secretmanager.admin from the parent folder: no binding here), so the token never leaves the pipeline;
# the adders hold the same role on it as on the other two, and use it on none of the three once every runner is the
# stack's (PROPOSALS.md). kick (#81; tacplus-dev/cluster#36), the runner of the looper's kicker and plan alone, is
# infra's way: the gitlab stack registers it and writes its version 1; so is build-report (#93; tacplus-dev/cluster#42),
# the runner of the report builds alone, whose pods a land's build preempts; and so is build-light (#100;
# tacplus-dev/cluster#51), the normal pool's runner of tacplus-dev/build's light jobs (pending, plan, report-pass and
# report-fail) alone; and so is manager (#106; tacplus-dev/cluster#60), the normal pool's runner of the looper's managers
# alone.
# cluster-admin-pipeline reads them all. A new token is a new version, and a pull request in tacplus-dev/cluster.
# Nobody else holds a role on any (authoritative bindings: a grant added by hand is drift).

locals {
  runner_tokens = { build = "gitlab-runner-build", control = "gitlab-runner-control", infra = "gitlab-runner-infra", kick = "gitlab-runner-kick", build-report = "gitlab-runner-build-report", build-light = "gitlab-runner-build-light", manager = "gitlab-runner-manager" }
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
