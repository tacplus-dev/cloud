# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The organization: its org policies, its folders (but bootstrap's, which bootstrap/bootstrap.sh made), the
# pipeline's rights on those folders, and the people's read-only access. The organization itself was created by
# Cloud Identity Free (bootstrap/bootstrap.sh); it is looked up by its domain.

data "google_organization" "org" {
  domain = var.domain
}

locals {
  org = "organizations/${data.google_organization.org.org_id}"

  # Enforced boolean constraints.
  enforced = {
    "iam.disableServiceAccountKeyCreation" = "No service-account keys: every identity is keyless (Workload Identity Federation, attached accounts)."
    "storage.uniformBucketLevelAccess"     = "Uniform bucket-level access: no object ACLs."
    "compute.skipDefaultNetworkCreation"   = "No default network: every network is declared here."
    "iam.disableServiceAccountKeyUpload"   = "No uploaded service-account keys either."
    "storage.publicAccessPrevention"       = "No public bucket or object."
  }

  # List constraints: the values allowed.
  allowed = {
    "iam.workloadIdentityPoolProviders" = ["https://gitlab.com"]
    "gcp.resourceLocations"             = ["in:${var.region}-locations"]
    "iam.allowedPolicyMemberDomains"    = [data.google_organization.org.directory_customer_id]
  }
}

resource "google_org_policy_policy" "enforced" {
  for_each = local.enforced
  name     = "${local.org}/policies/${each.key}"
  parent   = local.org
  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "allowed" {
  for_each = local.allowed
  name     = "${local.org}/policies/${each.key}"
  parent   = local.org
  spec {
    rules {
      values {
        allowed_values = each.value
      }
    }
  }
}

resource "google_folder" "folder" {
  for_each            = toset(var.folders)
  display_name        = each.key
  parent              = local.org
  deletion_protection = true
}

# The pipeline owns what is under its folders (the projects it creates there, and their IAM).
resource "google_folder_iam_member" "pipeline_owner" {
  for_each = google_folder.folder
  folder   = each.value.name
  role     = "roles/owner"
  member   = "serviceAccount:${var.pipeline_sa}"
}

# People, the hub included, read only (tacplus-dev/roadmap decisions/cloud-pipeline-2026-11-02.md).
resource "google_organization_iam_member" "reader" {
  for_each = { for p in setproduct(var.readers, ["roles/viewer", "roles/iam.securityReviewer"]) : "${p[0]} ${p[1]}" => p }
  org_id   = data.google_organization.org.org_id
  member   = each.value[0]
  role     = each.value[1]
}
