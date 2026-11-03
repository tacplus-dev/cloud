# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci stack's plan against a stub organization and an empty project (mock providers: no credentials, no cloud):
# the stack plans, and its module, with the stack's inputs, gives the runners, the buckets and the reader's key as
# designed. (A test sees a module's resources only when it runs that module itself.)

mock_provider "google" {
  mock_data "google_organization" {
    defaults = { org_id = "123456789012", name = "organizations/123456789012", directory_customer_id = "C0stub000" }
  }
  mock_data "google_active_folder" {
    defaults = { name = "folders/222" }
  }
  mock_data "google_project" {
    defaults = { billing_account = "000000-111111-222222", number = "333" }
  }
  # Computed at apply; the stub gives values of the right form.
  mock_resource "google_service_account" {
    defaults = { email = "stub-account@tacplus-ci.iam.gserviceaccount.com", member = "serviceAccount:stub-account@tacplus-ci.iam.gserviceaccount.com", name = "projects/tacplus-ci/serviceAccounts/stub-account@tacplus-ci.iam.gserviceaccount.com" }
  }
}

run "stack" {
  command = plan
  assert {
    condition     = output.project_id == "tacplus-ci"
    error_message = "The ci project is not tacplus-ci."
  }
  assert {
    condition     = toset(keys(output.runner_token_secrets)) == toset(["loopers", "loopers-big", "build", "deploy", "cluster"])
    error_message = "Not every runner pool has its token secret."
  }
}

run "ci" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    apt_snapshot         = "20261024T000000Z"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f"
    }
    pools = {
      with-account = { machine_type = "t2a-standard-8", disk_gb = 100, disk_type = "pd-balanced", max_instances = 5, service_account = true }
      no-account   = { machine_type = "t2a-standard-4", disk_gb = 50, disk_type = "pd-balanced", max_instances = 2, service_account = false }
    }
    build_buckets  = { build-cache = 30 }
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
  }

  assert {
    condition     = google_project.ci.folder_id == "folders/222" && google_project.ci.billing_account == "000000-111111-222222" && !google_project.ci.auto_create_network && google_project.ci.deletion_policy == "PREVENT"
    error_message = "The project is not in its folder, billed, without a default network and protected from deletion."
  }
  assert {
    condition     = length(google_compute_instance_template.pool["no-account"].service_account) == 0
    error_message = "A pool without an account has one on its VMs."
  }
  assert {
    condition     = length(google_compute_instance_template.pool["with-account"].service_account) == 1 && keys(google_service_account.worker) == ["with-account"]
    error_message = "A pool with an account does not run as its own."
  }
  assert {
    condition     = alltrue([for t in google_compute_instance_template.pool : t.disk[0].source_image == "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024" && startswith(t.machine_type, "t2a-") && length(t.network_interface[0].access_config) == 0])
    error_message = "A pool's VMs are not arm64, on the pinned image, with no external address."
  }
  assert {
    condition     = alltrue([for g in google_compute_instance_group_manager.pool : g.target_size == 0])
    error_message = "A pool's instance group is not empty at rest."
  }
  # The workers' accounts hold no role: the manager is the only account with a project role.
  assert {
    condition     = alltrue([for m in google_project_iam_member.manager : m.member == google_service_account.manager.member])
    error_message = "A project role is granted to an account other than the manager."
  }
  assert {
    condition     = !strcontains(google_compute_instance.manager.metadata["runner-config"], "glrt-") && strcontains(google_compute_instance.manager.metadata["runner-config"], "@TOKEN:no-account@") && strcontains(google_compute_instance.manager.metadata["runner-config"], "max_use_count = 1")
    error_message = "The manager's config holds a token, lacks a pool's placeholder, or reuses a VM."
  }
  assert {
    condition     = google_compute_instance.manager.metadata["runner-pools"] == "no-account with-account"
    error_message = "The manager does not run every pool."
  }
  assert {
    condition     = alltrue([for b in google_storage_bucket.build : b.uniform_bucket_level_access && b.public_access_prevention == "enforced" && b.location == "US-CENTRAL1"])
    error_message = "A build bucket is not uniform, private and in us-central1."
  }
  assert {
    condition     = google_kms_crypto_key.reader.import_only && google_kms_crypto_key.reader.skip_initial_version_creation && google_kms_crypto_key.reader.version_template[0].algorithm == "RSA_SIGN_PKCS1_2048_SHA256" && google_kms_key_ring.reader.location == "us-central1"
    error_message = "The reader app's key is not an import-only RS256 key in us-central1."
  }
  assert {
    condition     = alltrue([for s in google_secret_manager_secret.runner_token : s.replication[0].user_managed[0].replicas[0].location == "us-central1"])
    error_message = "A runner-token secret is replicated outside us-central1."
  }
}

run "unpinned_runner_refused" {
  command = plan
  module {
    source = "../../modules/projects/ci"
  }
  variables {
    project_id           = "tacplus-ci"
    name                 = "tacplus ci"
    folder               = "folders/222"
    billing_account      = "000000-111111-222222"
    region               = "us-central1"
    zone                 = "us-central1-b"
    subnet_cidr          = "10.10.0.0/20"
    image                = "projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-arm64-v20261024"
    apt_snapshot         = "20261024T000000Z"
    manager_machine_type = "t2a-standard-1"
    runner = {
      version           = "v19.5.2"
      deb_sha256        = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
      helper_deb_sha256 = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
      plugin_version    = "v1.3.1"
      plugin_sha256     = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
      default_image     = "alpine:3.22"
    }
    pools          = {}
    build_buckets  = {}
    reader_app_key = { key_ring = "looper", key = "tacplus-reader" }
  }
  expect_failures = [var.runner]
}
