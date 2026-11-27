# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: the looper VMs and the reserved machines, the build cache, the GitHub Apps' keys and their
# federation, the Admiral's credentials (#84) and the audit's account (#77); no runner pool since #113. Its folder is
# the folder stack's; its billing account is the bootstrap project's.

variable "parent_folder" {
  description = "The parent folder's numeric ID: the protected GitLab variable GCP_PARENT_FOLDER (ci/lib.sh), never written here."
  type        = string
}

variable "kms_key_importers" {
  description = "Who imports the apps' keys (#19): the protected GitLab variable GCP_KMS_KEY_IMPORTERS (ci/lib.sh), accounts of the host's directory, never written here. Jody's account for the import, then cleared."
  type        = list(string)
  default     = []
}

variable "admiral_secret_adders" {
  description = "Who adds the Admiral's secret's versions by hand (#84): the protected GitLab variable GCP_ADMIRAL_SECRET_ADDERS (ci/lib.sh), accounts of the host's directory, never written here. Jody's account today."
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
  source          = "../../modules/projects/ci"
  project_id      = module.settings.projects.ci.project
  name            = module.settings.projects.ci.name
  folder          = data.google_active_folder.ci.name
  billing_account = data.google_project.bootstrap.billing_account
  region          = module.settings.region
  zone            = "${module.settings.region}-b"
  subnet_cidr     = "10.10.0.0/20"
  build_cache     = { name = "build-cache", days = 30, gitlab_project = "tacplus-dev/build", account_id = "build-cache", wif_pool = "gitlab-com", wif_provider = "tacplus-dev-build" }
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
  # The Admiral's credentials (#84): its account, which only its SPIFFE ID becomes, through the dev project's pool
  # for its fleet kernel's issuer (the dev stack's); the key it alone signs with; the secret it alone reads.
  admiral = {
    account_id = module.settings.admiral.account_id
    pool       = "projects/${data.google_project.dev.number}/locations/global/workloadIdentityPools/${module.settings.admiral.pool}"
    subject    = module.settings.admiral.subject
    key        = module.settings.admiral.key
    secret     = module.settings.admiral.secret
  }
  admiral_secret_adders = var.admiral_secret_adders
  # The looper VMs (#108): stock Container-Optimized OS for arm64, pinned by name, and each project's spec.
  looper_vm_os_image = module.settings.cos_arm64_image
  looper_vms         = module.settings.looper_vms
  # The reserved machines (#111): the rolling check's and the merger's, on the same OS and cloud-init.
  reserved_vms = module.settings.reserved_vms
  # The release registry (#115): its readers are the deployments' identities, in the dev project, written out.
  releases = {
    repository     = module.settings.releases.repository
    location       = module.settings.releases.location
    account_id     = module.settings.releases.account_id
    gitlab_project = module.settings.releases.gitlab_project
    environment    = module.settings.releases.environment
    wif_provider   = module.settings.releases.publish_provider
    readers        = [for d in module.settings.releases.readers : "serviceAccount:${module.settings.deployments[d].account_id}@${module.settings.projects.dev.project}.iam.gserviceaccount.com"]
  }
  # The audit job's account (#77): read roles on both projects, which only this repository's protected main becomes,
  # through the pipeline's own pool (bootstrap/bootstrap.sh's provider admits nothing else of gitlab.com).
  hub_audit = {
    account_id     = "hub-audit"
    projects       = [module.settings.projects.ci.project, module.settings.projects.dev.project]
    roles          = ["roles/compute.viewer", "roles/container.viewer", "roles/monitoring.viewer", "roles/serviceusage.serviceUsageConsumer", "roles/secretmanager.viewer", "roles/cloudquotas.viewer"]
    pool           = "projects/${data.google_project.bootstrap.number}/locations/global/workloadIdentityPools/${module.settings.bootstrap.wif_pool}"
    gitlab_project = module.settings.gitlab_project
    # The cluster autoscaler's log alone (#85): its views and hub-audit's grant on them, once the host's
    # roles/logging.configWriter is in place.
    autoscaler_log = module.settings.autoscaler_log
  }
}

output "project_id" {
  value = module.ci.project_id
}

output "app_keys" {
  value = module.ci.app_keys
}

# Each looper VM's group and account (#108): what the kicker resizes (tacplus-dev/looper#241).
output "looper_vms" {
  value = module.ci.looper_vms
}

# Each reserved machine's group and account (#111): the rolling check's and the merger's (tacplus-dev/looper#249, #251).
output "reserved_vms" {
  value = module.ci.reserved_vms
}

output "app_import_jobs" {
  value = module.ci.app_import_jobs
}

# The reader's account (#30): fleet-seatrials' TACPLUS_READER_SA.
output "app_accounts" {
  value = module.ci.app_accounts
}

# The audit job's account (#77): the CI file's GCP_AUDIT_SA.
output "hub_audit" {
  value = module.ci.hub_audit
}

# The release registry (#115): tacplus-dev/build's BUILD_REGISTRY for a release, and the publish account and provider it
# federates as.
output "releases" {
  value = module.ci.releases
}

# The Admiral's Config (#84; tacplus-dev/admiral#5): what it federates through and the names it signs and reads with,
# none of them secret. The provider is the dev stack's (its output admiral), named here from the dev project's number.
output "admiral" {
  value = merge(module.ci.admiral, {
    wif_provider    = local.admiral_provider
    audience        = "//iam.googleapis.com/${local.admiral_provider}"
    subject         = module.settings.admiral.subject
    app_id          = module.settings.github_apps.apps[module.settings.admiral.key].app_id
    installation_id = module.settings.github_apps.apps[module.settings.admiral.key].installation_id
  })
}

locals {
  admiral_provider = "projects/${data.google_project.dev.number}/locations/global/workloadIdentityPools/${module.settings.admiral.pool}/providers/${module.settings.admiral.provider}"
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
