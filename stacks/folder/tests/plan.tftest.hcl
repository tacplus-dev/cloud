# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The folder stack's plan under a stub parent folder (mock providers: no credentials, no cloud): the stack plans,
# and its module, with the stack's inputs, gives the folders ci and dev under the parent folder, the pipeline's
# rights on them, and read-only access on the parent folder. No org policy: those are the host organization's job
# (README). (A test sees a module's resources only when it runs that module itself.)

mock_provider "google" {}

variables {
  parent_folder = "111111111111"
}

run "stack" {
  command = plan
  assert {
    condition     = output.parent_folder == "folders/111111111111"
    error_message = "The stack does not build under the parent folder it is given."
  }
}

# The settings take the folder's numeric ID, as bootstrap/bootstrap.sh --folder does: anything else is refused.
run "settings_take_an_id" {
  command = plan
  module {
    source = "../../modules/settings"
  }
  variables {
    parent_folder = "folders/111111111111"
  }
  expect_failures = [var.parent_folder]
}

run "folder" {
  command = plan
  module {
    source = "../../modules/folder"
  }
  variables {
    parent_folder = "folders/111111111111"
    folders       = ["ci", "dev"]
    pipeline_sa   = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    readers       = []
  }

  assert {
    condition     = toset(keys(google_folder.folder)) == toset(["ci", "dev"]) && alltrue([for f in google_folder.folder : f.deletion_protection])
    error_message = "The folders are not ci and dev, deletion-protected (prod is not built; bootstrap is the script's)."
  }
  assert {
    condition     = alltrue([for f in google_folder.folder : f.parent == "folders/111111111111"])
    error_message = "A folder is not under the parent folder."
  }
  assert {
    condition     = alltrue([for m in google_folder_iam_member.pipeline_owner : m.member == "serviceAccount:cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com" && m.role == "roles/owner"])
    error_message = "The folders' owner is not cloud-admin-pipeline alone."
  }
  assert {
    condition     = length(google_folder_iam_member.reader) == 0
    error_message = "Someone reads the parent folder who is not a reader."
  }
}

run "readers_read_only" {
  command = plan
  module {
    source = "../../modules/folder"
  }
  variables {
    parent_folder = "folders/111111111111"
    folders       = ["ci"]
    pipeline_sa   = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    readers       = ["user:someone@tacplus.dev"]
  }
  assert {
    condition     = toset([for m in google_folder_iam_member.reader : m.role]) == toset(["roles/viewer", "roles/iam.securityReviewer"])
    error_message = "A reader gets more than viewer and securityReviewer."
  }
  assert {
    condition     = alltrue([for m in google_folder_iam_member.reader : m.folder == "folders/111111111111" && m.member == "user:someone@tacplus.dev"])
    error_message = "A reader reads something other than the parent folder."
  }
}

run "parent_is_a_folder" {
  command = plan
  module {
    source = "../../modules/folder"
  }
  variables {
    parent_folder = "111111111111"
    folders       = ["ci"]
    pipeline_sa   = "cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com"
    readers       = []
  }
  expect_failures = [var.parent_folder]
}
