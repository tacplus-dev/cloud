# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Each deployment's fleet CA and crypto file (#28, Jody's option D, 2026-11-08; fleet-seatrials#44): made once by its
# project's init-secrets job, which adds them as the first versions of fleet-ca-<deployment> and
# fleet-crypto-<deployment>, and read by its deploy jobs. No GitLab variable and no GitLab token holds them (gitlab.com
# Free has no project access token; decisions/secrets-by-pipeline-2026-11-05.md). The job's account is its own: only its
# project's jobs in its GitLab environment, on protected main, may become it (the provider's condition, certificates.tf,
# and the binding naming the project and the environment together, as deploy.tf's environment accounts). It adds
# versions (secretVersionAdder) and sees their metadata (viewer: whether a version exists, so that a second run skips,
# never a value); the deployment's identity reads them (secretAccessor). Nobody else holds a role on either
# (authoritative bindings), and the account holds none on the project.

locals {
  init_secrets = { for k, d in var.deployments : k => d.init_secrets if d.init_secrets != null }
  # Every fleet secret, by its ID: the deployment it belongs to.
  fleet_secrets = merge(
    { for k in keys(local.init_secrets) : "fleet-ca-${k}" => k },
    { for k in keys(local.init_secrets) : "fleet-crypto-${k}" => k },
  )
  # Who holds each role on them: the init-secrets job's account, or the deployment's identity.
  fleet_secret_roles = {
    "roles/secretmanager.secretVersionAdder" = "init"
    "roles/secretmanager.viewer"             = "init"
    "roles/secretmanager.secretAccessor"     = "deploy"
  }
}

resource "google_service_account" "init_secrets" {
  for_each     = local.init_secrets
  project      = google_project.dev.project_id
  account_id   = each.value.account_id
  display_name = "${var.deployments[each.key].gitlab_project} pipeline, protected main, environment ${each.value.environment}: deployment ${each.key}'s fleet secrets (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

resource "google_service_account_iam_member" "init_secrets_wif" {
  for_each           = local.init_secrets
  service_account_id = google_service_account.init_secrets[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_environment/${var.deployments[each.key].gitlab_project}:${each.value.environment}"
}

# fleet-ca-<deployment>: the fleet's CA. fleet-crypto-<deployment>: its crypto file. Made with no version: the job adds
# them. Their values are only ever the pipeline's: none is in this repository, a plan or the state.
resource "google_secret_manager_secret" "fleet" {
  for_each  = local.fleet_secrets
  project   = google_project.dev.project_id
  secret_id = each.key
  labels    = { managed-by = "tacplus-dev-cloud", deployment = each.value }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_secret_manager_secret_iam_binding" "fleet" {
  for_each  = { for p in setproduct(keys(local.fleet_secrets), keys(local.fleet_secret_roles)) : "${p[0]}/${p[1]}" => { secret = p[0], role = p[1] } }
  project   = google_project.dev.project_id
  secret_id = google_secret_manager_secret.fleet[each.value.secret].secret_id
  role      = each.value.role
  members = [local.fleet_secret_roles[each.value.role] == "init" ? google_service_account.init_secrets[local.fleet_secrets[each.value.secret]].member :
  google_service_account.deploy[local.fleet_secrets[each.value.secret]].member]
}
