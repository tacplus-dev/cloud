# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# hub-audit (#77, Jody 2026-11-17): the audit job's account, which reads the projects for the hub's report
# (ci/hub-audit.sh), so that no gcloud on the Mac does, and no key file exists anywhere. Only this GitLab project's
# jobs become it, through the bootstrap pool that admits its protected main (the pipeline's own provider), and it
# holds read roles only: ci/policy.sh refuses any other role to it in a plan. Its member is written out, not the
# account's computed one, so that every plan, the first too, names who each grant is to.

locals {
  hub_audit_member = "serviceAccount:${var.hub_audit.account_id}@${google_project.ci.project_id}.iam.gserviceaccount.com"
  hub_audit_grants = { for g in setproduct(var.hub_audit.projects, var.hub_audit.roles) : "${g[0]}:${g[1]}" => { project = g[0], role = g[1] } }
}

resource "google_service_account" "hub_audit" {
  project      = google_project.ci.project_id
  account_id   = var.hub_audit.account_id
  display_name = "The hub's audit: ${var.hub_audit.gitlab_project}'s audit job, read-only (tacplus-dev/cloud #77)"
  depends_on   = [terraform_data.iam_ready]
}

# Authoritative: nobody else becomes it.
resource "google_service_account_iam_binding" "hub_audit" {
  service_account_id = google_service_account.hub_audit.name
  role               = "roles/iam.workloadIdentityUser"
  members            = ["principalSet://iam.googleapis.com/${var.hub_audit.pool}/attribute.project_path/${var.hub_audit.gitlab_project}"]
}

# Its read roles, on each project it reads. Not authoritative: the role's other members are the projects' own.
resource "google_project_iam_member" "hub_audit" {
  for_each   = local.hub_audit_grants
  project    = each.value.project
  role       = each.value.role
  member     = local.hub_audit_member
  depends_on = [google_service_account.hub_audit]
}

# The cluster autoscaler's log (#85, Jody's option A): why a scale-up did not happen (a pod no node pool fits, a quota,
# a stockout) is written only there, so the audit reads it, and nothing else of the logs. On each project's _Default
# bucket a view holds that one log, and hub-audit holds roles/logging.viewAccessor conditioned on that view alone. Never
# roles/logging.viewer, nor any wider view: a job's output, in the logs, may hold a secret (#77). ci/policy.sh refuses
# the role to it unconditioned, on another view or in a binding, and the view with any other filter. A log view needs
# the host's roles/logging.configWriter on the parent folder (README, What the host organization provides): until it
# is granted, modules/settings' autoscaler_log is false and none of this is made, so that no apply fails on it.
locals {
  hub_audit_view        = "hub-audit-autoscaler"
  hub_audit_view_filter = "LOG_ID(\"container.googleapis.com/cluster-autoscaler-visibility\")"
  hub_audit_log_on      = var.hub_audit.autoscaler_log ? toset(var.hub_audit.projects) : toset([])
}

resource "google_logging_log_view" "hub_audit_autoscaler" {
  for_each    = local.hub_audit_log_on
  name        = local.hub_audit_view
  bucket      = "projects/${each.key}/locations/global/buckets/_Default"
  filter      = local.hub_audit_view_filter
  description = "The cluster autoscaler's visibility log alone, which the hub's audit reads (tacplus-dev/cloud #85)"
  depends_on  = [terraform_data.iam_ready]
}

# Its project's view alone: the condition names it, as written out, so that every plan shows what hub-audit reads.
resource "google_project_iam_member" "hub_audit_autoscaler" {
  for_each = local.hub_audit_log_on
  project  = each.key
  role     = "roles/logging.viewAccessor"
  member   = local.hub_audit_member
  condition {
    title       = "hub-audit-autoscaler only"
    description = "The view hub-audit-autoscaler alone: the cluster autoscaler's log, no job's output (tacplus-dev/cloud #85)"
    expression  = "resource.name == \"projects/${each.key}/locations/global/buckets/_Default/views/${local.hub_audit_view}\""
  }
  depends_on = [google_service_account.hub_audit, google_logging_log_view.hub_audit_autoscaler]
}
