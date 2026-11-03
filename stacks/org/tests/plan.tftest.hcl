# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The org stack's plan against a stub organization (mock providers: no credentials, no cloud): the stack plans,
# and its module, with the stack's inputs, gives the org policies, the folders and the pipeline's rights on them.
# (A test sees a module's resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_organization" {
    defaults = {
      org_id                = "123456789012"
      name                  = "organizations/123456789012"
      directory_customer_id = "C0stub000"
    }
  }
}

run "stack" {
  command = plan
  assert {
    condition     = output.org_id == "123456789012"
    error_message = "The organization is not the one of tacplus.dev."
  }
}

run "org" {
  command = plan
  module {
    source = "../../modules/org"
  }
  variables {
    domain      = "tacplus.dev"
    region      = "us-central1"
    folders     = ["ci", "dev"]
    pipeline_sa = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    readers     = []
  }

  assert {
    condition = toset(keys(google_org_policy_policy.enforced)) == toset([
      "iam.disableServiceAccountKeyCreation",
      "iam.disableServiceAccountKeyUpload",
      "storage.uniformBucketLevelAccess",
      "storage.publicAccessPrevention",
      "compute.skipDefaultNetworkCreation",
    ])
    error_message = "The enforced org policies are not the designed set."
  }
  assert {
    condition     = alltrue([for p in google_org_policy_policy.enforced : p.spec[0].rules[0].enforce == "TRUE" && p.parent == "organizations/123456789012"])
    error_message = "An enforced org policy is not enforced on the organization."
  }
  assert {
    condition     = google_org_policy_policy.allowed["iam.workloadIdentityPoolProviders"].spec[0].rules[0].values[0].allowed_values == tolist(["https://gitlab.com"])
    error_message = "Workload Identity Federation is not limited to gitlab.com."
  }
  assert {
    condition     = google_org_policy_policy.allowed["gcp.resourceLocations"].spec[0].rules[0].values[0].allowed_values == tolist(["in:us-central1-locations"])
    error_message = "Resources are not limited to us-central1."
  }
  assert {
    condition     = google_org_policy_policy.allowed["iam.allowedPolicyMemberDomains"].spec[0].rules[0].values[0].allowed_values == tolist(["C0stub000"])
    error_message = "Sharing is not restricted to the organization's own directory."
  }
  assert {
    condition     = toset(keys(google_folder.folder)) == toset(["ci", "dev"]) && alltrue([for f in google_folder.folder : f.deletion_protection])
    error_message = "The folders are not ci and dev, deletion-protected (prod is not built; bootstrap is the script's)."
  }
  assert {
    condition     = alltrue([for m in google_folder_iam_member.pipeline_owner : m.member == "serviceAccount:cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com" && m.role == "roles/owner"])
    error_message = "The folders' owner is not cloud-admin-pipeline alone."
  }
}

run "readers_read_only" {
  command = plan
  module {
    source = "../../modules/org"
  }
  variables {
    domain      = "tacplus.dev"
    region      = "us-central1"
    folders     = ["ci"]
    pipeline_sa = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    readers     = ["user:someone@tacplus.dev"]
  }
  assert {
    condition     = toset([for m in google_organization_iam_member.reader : m.role]) == toset(["roles/viewer", "roles/iam.securityReviewer"])
    error_message = "A reader gets more than viewer and securityReviewer."
  }
}
