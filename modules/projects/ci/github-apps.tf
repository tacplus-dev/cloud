# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The GitHub Apps' keys (#19; tacplus-dev/looper README, Only the manager writes main): each app's private key is a
# Cloud KMS signing key, import-only, which a job uses through Workload Identity Federation from gitlab.com to have
# its app's JWT signed, and never holds. A key's signers are bound on that key alone, never on the key ring.
#
# Importing: the app's key, generated on GitHub, is imported once through the key's own import job by the members of
# the protected GitLab variable GCP_KMS_KEY_IMPORTERS, and its file shredded; a later commit clears the variable, and
# with it every importer's binding. Cloud KMS never exports a key's material: once imported, it never leaves.

locals {
  apps = var.github_apps
  # The keys imported now: each has its import job.
  app_imports = { for k, a in local.apps.keys : k => "${k}-import" if a.import }
  # An import job's resource name, as IAM's conditions see it (the provider has no import job IAM: the importer role
  # is the key ring's, conditioned on these names).
  app_import_names = { for k, j in local.app_imports : k => "projects/${google_project.ci.project_id}/locations/${var.region}/keyRings/${local.apps.key_ring}/importJobs/${j}" }
  # Each key's signers: the looper project's jobs of its ref in the key's environments (the attribute role), and with
  # namespace, every protected ref of the namespace (the attribute namespace_id).
  app_pool = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.loopers.name}"
  app_signers = { for k, a in local.apps.keys : k => concat(
    a.namespace ? ["${local.app_pool}/attribute.namespace_id/${local.apps.namespace.id}"] : [],
    [for e in a.environments : "${local.app_pool}/attribute.role/${local.apps.looper.project_id}:${local.apps.looper.ref}:true:${e}"],
  ) }
}

resource "google_kms_key_ring" "looper" {
  project    = google_project.ci.project_id
  name       = local.apps.key_ring
  location   = var.region
  depends_on = [terraform_data.iam_ready]
}

moved {
  from = google_kms_key_ring.reader
  to   = google_kms_key_ring.looper
}

# The GitHub App's key is GitHub's: it is imported, never generated here, so the key has no version until then
# (RS256, which a GitHub App's JWT is signed with).
resource "google_kms_crypto_key" "app" {
  for_each                      = local.apps.keys
  name                          = each.key
  key_ring                      = google_kms_key_ring.looper.id
  purpose                       = "ASYMMETRIC_SIGN"
  import_only                   = true
  skip_initial_version_creation = true
  version_template {
    algorithm        = "RSA_SIGN_PKCS1_2048_SHA256"
    protection_level = "SOFTWARE"
  }
  lifecycle {
    prevent_destroy = true
  }
}

# The reader's key, made before the apps were a map (it is named tacplus-reader in modules/settings).
moved {
  from = google_kms_crypto_key.reader
  to   = google_kms_crypto_key.app["tacplus-reader"]
}

# An import job lives three days, then expires (it is never deleted); a key not imported by then needs a new one, a
# commit that renames it.
resource "google_kms_key_ring_import_job" "app" {
  for_each         = local.app_imports
  key_ring         = google_kms_key_ring.looper.id
  import_job_id    = each.value
  import_method    = "RSA_OAEP_3072_SHA256_AES_256"
  protection_level = "SOFTWARE"
}

# The importers' one permission on a key: creating its version, the import. Nothing else, no read, no IAM.
resource "google_project_iam_custom_role" "key_version_importer" {
  project     = google_project.ci.project_id
  role_id     = "kmsKeyVersionImporter"
  title       = "KMS key version importer"
  description = "Imports a key's version, with roles/cloudkms.importer on its import job (tacplus-dev/cloud #19)."
  permissions = ["cloudkms.cryptoKeyVersions.create"]
  depends_on  = [terraform_data.iam_ready]
}

# With no importer, no binding: nobody imports. Authoritative: a grant added by hand is drift.
resource "google_kms_crypto_key_iam_binding" "importer" {
  for_each      = length(var.kms_key_importers) > 0 ? local.app_imports : {}
  crypto_key_id = google_kms_crypto_key.app[each.key].id
  role          = "projects/${google_project.ci.project_id}/roles/${google_project_iam_custom_role.key_version_importer.role_id}"
  members       = var.kms_key_importers
}

resource "google_kms_key_ring_iam_binding" "importer" {
  count       = length(var.kms_key_importers) > 0 && length(local.app_imports) > 0 ? 1 : 0
  key_ring_id = google_kms_key_ring.looper.id
  role        = "roles/cloudkms.importer"
  members     = var.kms_key_importers
  condition {
    title       = "import-jobs"
    description = "The apps' import jobs alone."
    expression  = join(" || ", [for k in sort(keys(local.app_import_names)) : "resource.name == \"${local.app_import_names[k]}\""])
  }
  depends_on = [google_kms_key_ring_import_job.app]
}

# Each key's own signers. Authoritative: nobody else signs with it.
resource "google_kms_crypto_key_iam_binding" "signer" {
  for_each      = { for k, s in local.app_signers : k => s if length(s) > 0 }
  crypto_key_id = google_kms_crypto_key.app[each.key].id
  role          = "roles/cloudkms.signer"
  members       = each.value
}

# The apps' federation from gitlab.com: a pool of its own, whose two providers each map only their own attribute.
resource "google_iam_workload_identity_pool" "loopers" {
  project                   = google_project.ci.project_id
  workload_identity_pool_id = local.apps.wif_pool
  display_name              = "gitlab.com loopers"
  description               = "GitLab CI jobs that sign as the GitHub Apps (tacplus-dev/cloud)"
  depends_on                = [terraform_data.iam_ready]
}

# tacplus-dev/looper's protected refs alone. role is GitLab's word for the job's project, ref, protection and
# environment, which each key's binding matches.
resource "google_iam_workload_identity_pool_provider" "looper" {
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.loopers.workload_identity_pool_id
  workload_identity_pool_provider_id = local.apps.looper.wif_provider
  display_name                       = "tacplus-dev/looper"
  attribute_mapping = {
    "google.subject" = "assertion.project_id + \":\" + assertion.job_id"
    "attribute.role" = "assertion.project_id + \":\" + assertion.ref + \":\" + assertion.ref_protected + \":\" + assertion.environment"
  }
  attribute_condition = "assertion.project_id == \"${local.apps.looper.project_id}\" && assertion.ref_protected == \"true\""
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

# The namespace's protected refs, for the reader.
resource "google_iam_workload_identity_pool_provider" "namespace" {
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.loopers.workload_identity_pool_id
  workload_identity_pool_provider_id = local.apps.namespace.wif_provider
  display_name                       = "tacplus-dev"
  attribute_mapping = {
    "google.subject"         = "assertion.project_id + \":\" + assertion.job_id"
    "attribute.namespace_id" = "assertion.namespace_id"
  }
  attribute_condition = "assertion.namespace_id == \"${local.apps.namespace.id}\" && assertion.ref_protected == \"true\""
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}
