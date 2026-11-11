# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: runners, the build cache, the GitHub Apps' keys and their federation. Its folder is the folder
# stack's; its billing account is the bootstrap project's.

variable "parent_folder" {
  description = "The parent folder's numeric ID: the protected GitLab variable GCP_PARENT_FOLDER (ci/lib.sh), never written here."
  type        = string
}

variable "kms_key_importers" {
  description = "Who imports the apps' keys (#19): the protected GitLab variable GCP_KMS_KEY_IMPORTERS (ci/lib.sh), accounts of the host's directory, never written here. Jody's account for the import, then cleared."
  type        = list(string)
  default     = []
}

module "settings" {
  source        = "../../modules/settings"
  parent_folder = var.parent_folder
}

provider "google" {
  region = module.settings.region
}

data "google_active_folder" "ci" {
  display_name = module.settings.projects.ci.folder
  parent       = module.settings.parent_folder
}

data "google_project" "bootstrap" {
  project_id = module.settings.bootstrap.project
}

# The dev project, made by the dev stack (plan:ci comes after apply:dev): its pool federates the deployments' jobs, of
# which fleet-seatrials' become the reader's account (#30).
data "google_project" "dev" {
  project_id = module.settings.projects.dev.project
}

module "ci" {
  source               = "../../modules/projects/ci"
  project_id           = module.settings.projects.ci.project
  name                 = module.settings.projects.ci.name
  folder               = data.google_active_folder.ci.name
  billing_account      = data.google_project.bootstrap.billing_account
  region               = module.settings.region
  zone                 = "${module.settings.region}-b"
  subnet_cidr          = "10.10.0.0/20"
  image                = module.settings.ubuntu_arm64_image.image
  apt_snapshot         = module.settings.ubuntu_arm64_image.snapshot
  pool_image           = module.settings.cos_arm64_image
  manager_machine_type = "t2a-standard-1"
  # GitLab Runner and the fleeting plugin, our builds of upstream's tags (ci/runner.sh, #40): each commit, and each
  # build's SHA-256, which the build is refused without and the manager installs by.
  runner = {
    version                = "v19.5.2"
    branch                 = "19-5-stable"
    commit                 = "66ad5002d9249fc178e8f9edf3dd7d58223213ce"
    runner_sha256          = "90d179f55e8eb8e4a601e37c5124f9362f27e27323f287520958da8e5fddd1af"
    plugin_version         = "v1.3.1"
    plugin_commit          = "31ea56d71b16c75e37999262293b273be509f13d"
    plugin_sha256          = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
    deb_sha256             = "0d6764ed6e0fecd558a2aef222e04ba7ffdc304e0ac7f710ead64c790a848c8b"
    helper_deb_sha256      = "45cdd76518db487ddd942300ba651688ce8b6f075a893670a1a1da20d593e0ff"
    upstream_plugin_sha256 = "12d4ffcd154763b193889118bd44c264446d66b55078b1aa4c471d1f0e2fc9b5"
    default_image          = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
  }
  # The tools job's artifact (ci/tools.sh), which plan:ci and apply:ci get: relative, so a plan applies in another job.
  runner_bin  = "${path.root}/../../bin/manager"
  pools       = { for k, p in module.settings.runner_pools : k => { for a, v in p : a => v if a != "runner" } }
  build_cache = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
  github_apps = {
    key_ring  = module.settings.github_apps.key_ring
    wif_pool  = module.settings.github_apps.pool
    namespace = { id = module.settings.github_apps.namespace.id, wif_provider = module.settings.github_apps.namespace.wif_provider }
    looper    = { for a, v in module.settings.github_apps.looper : a => v if a != "project" }
    # The pools gitlab-com of tacplus-bootstrap (this pipeline's, bootstrap/bootstrap.sh) and of the dev project
    # (the dev stack's cluster_pipeline.pool).
    pools = {
      bootstrap = "projects/${data.google_project.bootstrap.number}/locations/global/workloadIdentityPools/${module.settings.bootstrap.wif_pool}"
      dev       = "projects/${data.google_project.dev.number}/locations/global/workloadIdentityPools/gitlab-com"
    }
    keys = { for k, a in module.settings.github_apps.apps : k => { import = a.import, namespace = a.namespace, environments = a.environments, accounts = a.accounts, projects = a.projects } }
  }
  kms_key_importers = var.kms_key_importers
}

output "project_id" {
  value = module.ci.project_id
}

output "runner_token_secrets" {
  value = module.ci.runner_token_secrets
}

output "app_keys" {
  value = module.ci.app_keys
}

output "app_import_jobs" {
  value = module.ci.app_import_jobs
}

# The reader's account (#30): fleet-seatrials' TACPLUS_READER_SA.
output "app_accounts" {
  value = module.ci.app_accounts
}

# The looper project's variables (tacplus-dev/looper README, Only the manager writes main, Setting it up), which the
# hub sets: none is secret.
output "looper_variables" {
  value = {
    GCP_WIF_PROVIDER               = module.ci.looper_wif_provider
    LOOPER_KMS_KEYRING             = module.ci.app_key_ring
    LOOPER_MANAGER_APP_ID          = module.settings.github_apps.apps["tacplus-manager"].app_id
    LOOPER_MANAGER_INSTALLATION_ID = module.settings.github_apps.apps["tacplus-manager"].installation_id
    LOOPER_REPORT_APP_ID           = module.settings.github_apps.apps["tacplus-looper"].app_id
    LOOPER_REPORT_INSTALLATION_ID  = module.settings.github_apps.apps["tacplus-looper"].installation_id
  }
}
