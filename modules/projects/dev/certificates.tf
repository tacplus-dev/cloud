# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Each deployment's certificate, owned by its pipeline (decisions/certificates-by-pipeline-2026-11-03.md, #6): the
# pipeline checks its certificate on every run and, when it is missing or due, obtains one by ACME DNS-01 and adds it
# as a new secret version, which the uni-config references. Its identity, keyless and federated from its GitLab
# project's protected main alone, adds and reads the versions of its two secrets, and administers its _acme-challenge
# zone, delegated from the domain's zone, so it never writes the domain's own records. Nobody else holds a role on
# either (authoritative bindings). Its other roles, get-credentials and its images' builds, are deploy.tf's (#20).
#
# An environment account (deploy.tf) may have a certificate of its own, for a domain of its own (#32: the test IdP's
# idp.test.tacplus.dev, which *.tacplus.dev does not cover): the same two secrets, named after its environment, and
# challenge zone, the environment account's alone, the deployment's identity holding no role on them.

locals {
  # Every certificate, by the key of its owner: a deployment's (its key) or an environment account's
  # (<deployment>/<environment>), with its domain, its secrets' IDs and the member that alone owns it.
  certificates = merge(
    { for k, d in var.deployments : k => { deployment = k, tls = "tls-${k}", acme_account = "acme-account-${d.environment}", domain = d.domain, member = google_service_account.deploy[k].member, owner = "${d.gitlab_project}'s pipeline" } },
    merge([for k, d in var.deployments : {
      for e, domain in d.environment_certificates : "${k}/${e}" => { deployment = k, tls = "tls-${e}", acme_account = "acme-account-${e}", domain = domain, member = google_service_account.environment["${k}/${e}"].member, owner = "${d.gitlab_project}'s jobs in the environment ${e}" }
    }]...),
  )
  # Every certificate secret, by its ID: the certificate it belongs to.
  certificate_secrets = merge(
    { for k, c in local.certificates : c.tls => k },
    { for k, c in local.certificates : c.acme_account => k },
  )
  certificate_roles = ["roles/secretmanager.secretVersionAdder", "roles/secretmanager.secretAccessor"]
}

resource "google_iam_workload_identity_pool_provider" "deploy" {
  for_each                           = var.deployments
  project                            = google_project.dev.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.wif_provider
  display_name                       = each.value.gitlab_project
  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.project_path"  = "assertion.project_path"
    "attribute.ref"           = "assertion.ref"
    "attribute.ref_type"      = "assertion.ref_type"
    "attribute.ref_protected" = "assertion.ref_protected"
    # The project and the job's environment together (deploy.tf's environment accounts, #20): the pool is shared by
    # tacplus-dev's projects. A job without an environment maps to none.
    "attribute.project_environment" = "assertion.project_path + ':' + (has(assertion.environment) ? assertion.environment : '')"
  }
  attribute_condition = "assertion.project_path == '${each.value.gitlab_project}' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'"
  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

resource "google_service_account" "deploy" {
  for_each     = var.deployments
  project      = google_project.dev.project_id
  account_id   = each.value.account_id
  display_name = "${each.value.gitlab_project} pipeline, protected main: deployment ${each.key} (tacplus-dev/cloud)"
  depends_on   = [terraform_data.iam_ready]
}

resource "google_service_account_iam_member" "deploy_wif" {
  for_each           = var.deployments
  service_account_id = google_service_account.deploy[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}/attribute.project_path/${each.value.gitlab_project}"
}

# tls-<deployment>: the certificate chain and its key, one version per certificate. acme-account-<environment>: the
# ACME account's key. Their values are only ever the pipeline's: none is in this repository, a plan or the state.
resource "google_secret_manager_secret" "certificate" {
  for_each  = local.certificate_secrets
  project   = google_project.dev.project_id
  secret_id = each.key
  labels    = { managed-by = "tacplus-dev-cloud", deployment = local.certificates[each.value].deployment }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_secret_manager_secret_iam_binding" "certificate" {
  for_each  = { for p in setproduct(keys(local.certificate_secrets), local.certificate_roles) : "${p[0]}/${p[1]}" => { secret = p[0], role = p[1] } }
  project   = google_project.dev.project_id
  secret_id = google_secret_manager_secret.certificate[each.value.secret].secret_id
  role      = each.value.role
  members   = [local.certificates[local.certificate_secrets[each.value.secret]].member]
}

# The zone for _acme-challenge.<domain> alone: DNS-01 for <domain> and *.<domain> writes its TXT records here. Its
# delegation is an NS record of the domain's zone (dns.tf), when this pipeline writes that zone.
resource "google_dns_managed_zone" "acme_challenge" {
  for_each    = local.certificates
  project     = google_project.dev.project_id
  name        = "acme-challenge-${replace(each.value.domain, ".", "-")}"
  dns_name    = "_acme-challenge.${each.value.domain}."
  description = "ACME DNS-01 challenges for ${each.value.domain}: ${each.value.owner} only (tacplus-dev/cloud)"
  labels      = { managed-by = "tacplus-dev-cloud", deployment = each.value.deployment }
  dnssec_config {
    state = "on"
  }
  depends_on = [terraform_data.iam_ready]
}

resource "google_dns_managed_zone_iam_binding" "acme_challenge" {
  for_each     = local.certificates
  project      = google_project.dev.project_id
  managed_zone = google_dns_managed_zone.acme_challenge[each.key].name
  role         = "roles/dns.admin"
  members      = [each.value.member]
}
