# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The ci project: runners, the build cache, the GitHub Apps' keys and their federation, and the Admiral's credentials
# (#84). Its folder is the folder stack's; its billing account is the bootstrap project's.

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
  source               = "../../modules/projects/ci"
  project_id           = module.settings.projects.ci.project
  name                 = module.settings.projects.ci.name
  folder               = data.google_active_folder.ci.name
  billing_account      = data.google_project.bootstrap.billing_account
  region               = module.settings.region
  zone                 = "${module.settings.region}-b"
  subnet_cidr          = "10.10.0.0/20"
  image                = module.settings.ubuntu_arm64_image.image
  pool_image           = module.settings.cos_arm64_image
  manager_machine_type = module.settings.ci_cpus.manager_machine_type
  manager_disk_gb      = module.settings.ci_disks.manager_disk_gb
  # A new manager's handoff (#51, Jody 2026-11-12): the old one drains for at most this long, less 12 minutes, then
  # the jobs still on it are cut and reported (#54), and the pipeline's handoff job, 5 minutes past it, runs them
  # again here (ci/gitlab-project.gitlab-ci.yml's start_in follows this); the fleet starts nothing new until then.
  manager_handoff_minutes = 30
  # GitLab Runner and the fleeting plugin, our builds of upstream's tags (ci/runner.sh, #40): each commit, and each
  # build's SHA-256, which the build is refused without and the manager installs by.
  # One release with tacplus-dev/cluster (cluster#21, #44): a runner bump here names the cluster issue that moves its pins
  # (v19.6.0, #99: cluster#52).
  runner = {
    version        = "v19.6.0"
    branch         = "19-6-stable"
    commit         = "9e4c6b50fd8a81ceaf2ee5c0b4d5d1c6c16067b0"
    runner_sha256  = "c48789d1b21f34c017302320aeeef22ea589ec161a553d830f3e310880bfacee"
    plugin_version = "v1.3.1"
    plugin_commit  = "31ea56d71b16c75e37999262293b273be509f13d"
    plugin_sha256  = "429bff00bccf870039e5b8efe637860aea9b518c4be973c3bd38d463e31b20bb"
    # The helper image of the runner's version, by digest: upstream's, which the pools pull at a job's start.
    helper_image  = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.6.0@sha256:8b17f12e12f28844d6b9aa0777297ddc243cc5caaa92b269f30daf2783655893"
    default_image = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
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
  # The looper VMs (#108): stock Container-Optimized OS for arm64, the pools' pin, and each project's spec.
  looper_vm_os_image = module.settings.cos_arm64_image
  looper_vms         = module.settings.looper_vms
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

output "runner_token_secrets" {
  value = module.ci.runner_token_secrets
}

output "app_keys" {
  value = module.ci.app_keys
}

# Each looper VM's group and account (#108): what the kicker resizes (tacplus-dev/looper#241).
output "looper_vms" {
  value = module.ci.looper_vms
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
