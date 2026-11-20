# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The Admiral's credentials (#84; tacplus-dev/admiral#5, Jody's option A): its own service account, which only its
# kernel-signed identity becomes, through the dev project's provider for its fleet kernel's issuer
# (modules/projects/dev/admiral.tf); its GitHub App's key, one of github-apps.tf's, which the account alone signs with;
# and the triage project's GitLab token, a secret the account alone reads. The Admiral holds no long-lived secret: KMS
# signs its App's JWT, and the token is read when it is used. Its member is written out, not the account's computed
# one, so that every plan, the first too, names who each grant is to.

locals {
  admiral        = var.admiral == null ? {} : { admiral = var.admiral }
  admiral_member = var.admiral == null ? null : "serviceAccount:${var.admiral.account_id}@${google_project.ci.project_id}.iam.gserviceaccount.com"
  # Its secret's roles: the account reads it; the adders add its versions, by hand, and read none (secretVersionAdder
  # has no versions.access). With no adder, no binding of that role: nobody adds one.
  admiral_secret_roles = merge(
    { "roles/secretmanager.secretAccessor" = [local.admiral_member] },
    length(var.admiral_secret_adders) > 0 ? { "roles/secretmanager.secretVersionAdder" = var.admiral_secret_adders } : {},
  )
}

resource "google_service_account" "admiral" {
  for_each     = local.admiral
  project      = google_project.ci.project_id
  account_id   = each.value.account_id
  display_name = "The Admiral: ${each.value.subject} (tacplus-dev/cloud #84)"
  depends_on   = [terraform_data.iam_ready]
}

# Authoritative: only the Admiral's subject, through its pool, becomes it.
resource "google_service_account_iam_binding" "admiral" {
  for_each           = local.admiral
  service_account_id = google_service_account.admiral[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  members            = ["principal://iam.googleapis.com/${each.value.pool}/subject/${each.value.subject}"]
}

# Its App's key's one signer (signerVerifier, as #84 asks: it signs the App's JWT and may read the public key),
# authoritative; no GitLab job signs with that key (its github_apps entry lists none).
resource "google_kms_crypto_key_iam_binding" "admiral" {
  for_each      = local.admiral
  crypto_key_id = google_kms_crypto_key.app[each.value.key].id
  role          = "roles/cloudkms.signerVerifier"
  members       = [local.admiral_member]
  depends_on    = [google_service_account.admiral]
  lifecycle {
    precondition {
      condition     = length(local.app_signers[each.value.key]) == 0
      error_message = "The Admiral's key ${each.value.key} has signers in github_apps: the Admiral alone signs with it."
    }
  }
}

# Made with no version: its value, the triage project's access token, is only ever added by hand, never in this
# repository, a plan or the state.
resource "google_secret_manager_secret" "admiral" {
  for_each  = local.admiral
  project   = google_project.ci.project_id
  secret_id = each.value.secret
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

# Authoritative: nobody else holds a role on it, a grant added by hand is drift.
resource "google_secret_manager_secret_iam_binding" "admiral" {
  for_each   = var.admiral == null ? {} : local.admiral_secret_roles
  project    = google_project.ci.project_id
  secret_id  = google_secret_manager_secret.admiral["admiral"].secret_id
  role       = each.key
  members    = each.value
  depends_on = [google_service_account.admiral]
}
