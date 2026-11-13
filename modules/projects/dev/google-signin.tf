# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Each deployment's Google sign-in client secret (#37; Jody, 2026-11-09, fleet-seatrials#46): the OAuth web client
# its oauth signs in with, google-signin-<deployment>, read by its deploy jobs through WIF. Never a GitLab variable.
# Google has no public API that makes a web client or its secret (IAP's OAuth Admin API was shut down on 2026-03-19),
# so its versions are added by hand, in the Console: the client JSON the Console downloads, once when the client is
# made and at each rotation, by the listed adders (Jody's account today, from GCP_GOOGLE_SIGNIN_ADDERS), who add
# versions and never read them (secretVersionAdder has no versions.access); the deployment's identity alone reads them.
# No pipeline identity adds one. Nobody else holds a role on it (authoritative bindings: a grant added by hand is drift).

locals {
  google_signin = toset([for k, d in var.deployments : k if d.google_signin])
  # With no adder, no binding of the role: nobody adds versions.
  google_signin_roles = merge(
    { "roles/secretmanager.secretAccessor" = "deploy" },
    length(var.google_signin_adders) > 0 ? { "roles/secretmanager.secretVersionAdder" = "adders" } : {},
  )
}

# Made with no version: its value is only ever added in the Console, never in this repository, a plan or the state.
resource "google_secret_manager_secret" "google_signin" {
  for_each  = local.google_signin
  project   = google_project.dev.project_id
  secret_id = "google-signin-${each.key}"
  labels    = { managed-by = "tacplus-dev-cloud", deployment = each.key }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_secret_manager_secret_iam_binding" "google_signin" {
  for_each  = { for p in setproduct(local.google_signin, keys(local.google_signin_roles)) : "${p[0]}/${p[1]}" => { deployment = p[0], role = p[1] } }
  project   = google_project.dev.project_id
  secret_id = google_secret_manager_secret.google_signin[each.value.deployment].secret_id
  role      = each.value.role
  members   = local.google_signin_roles[each.value.role] == "deploy" ? [google_service_account.deploy[each.value.deployment].member] : var.google_signin_adders
}

# The adders also make (and rotate) the web client itself, in the Console's Google Auth Platform, its branding first
# (#56): roles/oauthconfig.editor on the project, which brands.create and the clients need; Jody's account holds no
# other role on it. A member binding, not authoritative: the project's other holders of the role are not this file's.
resource "google_project_iam_member" "google_signin_adders" {
  for_each   = toset(var.google_signin_adders)
  project    = google_project.dev.project_id
  role       = "roles/oauthconfig.editor"
  member     = each.key
  depends_on = [terraform_data.iam_ready]
}
