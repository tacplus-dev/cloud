# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The Anthropic organization (#34): for each deployment that runs llmproxy (modules/settings, deployments' llmproxy),
# the workload identity its llmproxy reaches the Anthropic API with: the federation issuer (the fleet's OIDC issuer),
# the service account and its workspace membership, and the rule that lets the issuer's tokens for llmproxy act as
# that account. Made, changed and archived by this stack only; the hand-made issuer, account and rule are adopted by
# their IDs, so that the IDs llmproxy names never change.
#
# The provider's credential is no key: the job's GitLab ID tokens are exchanged, through the one org:admin rule made
# by hand in the Console (modules/settings, anthropic), for a short-lived org:admin token (README, The Anthropic
# organization). ci/lib.sh's ci_anthropic gives the provider the rule (ANTHROPIC_ORGANIZATION_ID,
# ANTHROPIC_FEDERATION_RULE_ID, ANTHROPIC_SERVICE_ACCOUNT_ID) and this stack the same as var.admin; every exchange
# presents an ID token of its own (ci/anthropic-token.sh), as Anthropic accepts each jti once.

module "settings" {
  source = "../../modules/settings"
}

provider "anthropic" {
  federation = {
    identity_token_command = [abspath("${path.root}/../../ci/anthropic-token.sh")]
  }
}

variable "admin" {
  description = "The bootstrap org:admin rule and its service account (modules/settings, anthropic), which this stack only reads and checks; null in the tests and validate."
  type        = object({ organization_id = string, federation_rule_id = string, service_account_id = string })
  default     = null
}

variable "import_existing" {
  description = "Adopt the identities made by hand (each adopt of modules/settings). False only in the tests: a mock provider cannot import."
  type        = bool
  default     = true
}

locals {
  llmproxy = { for k, d in module.settings.deployments : k => d.llmproxy if try(d.llmproxy, null) != null }
  admin    = module.settings.anthropic.admin
  adopt    = var.import_existing ? local.llmproxy : {}
}

# Each refuses a destroy, and fails the plan if it finds itself archived (made in the Console): either would give
# llmproxy a new ID, and its config names the old one. A rule archived by hand is put back by hand, or its
# deployment's config changes with a commit here.
resource "anthropic_federation_issuer" "llmproxy" {
  for_each   = local.llmproxy
  name       = each.value.issuer.name
  issuer_url = each.value.issuer.url
  jwks       = { type = "discovery" }
  lifecycle {
    prevent_destroy = true
    postcondition {
      condition     = self.archived_at == null
      error_message = "The federation issuer ${self.name} (${self.id}) was archived: it is not made again, as that would give it a new ID (README, The Anthropic organization)."
    }
  }
}

resource "anthropic_service_account" "llmproxy" {
  for_each          = local.llmproxy
  name              = each.value.service_account.name
  organization_role = "developer"
  lifecycle {
    prevent_destroy = true
    postcondition {
      condition     = self.archived_at == null
      error_message = "The service account ${self.name} (${self.id}) was archived: it is not made again, as that would give it a new ID (README, The Anthropic organization)."
    }
  }
}

# The account's membership of its workspace is made here, never adopted: a federated token acts in a workspace other
# than the organization's default only once its account is an explicit member of it, and seatrials' hand-made
# account was none (the first live plan's import found no membership, 2026-11-12). It has no ID llmproxy names: one
# removed in the Console is gone from the next refresh, and the plan makes it again.
resource "anthropic_service_account_workspace" "llmproxy" {
  for_each           = local.llmproxy
  service_account_id = anthropic_service_account.llmproxy[each.key].id
  workspace_id       = each.value.workspace_id
  workspace_role     = each.value.service_account.workspace_role
}

resource "anthropic_federation_rule" "llmproxy" {
  for_each     = local.llmproxy
  name         = each.value.rule.name
  issuer_id    = anthropic_federation_issuer.llmproxy[each.key].id
  match        = { subject_prefix = each.value.rule.subject }
  target       = { service_account_id = anthropic_service_account.llmproxy[each.key].id }
  oauth_scope  = each.value.rule.oauth_scope
  workspace_id = each.value.workspace_id
  depends_on   = [anthropic_service_account_workspace.llmproxy]
  lifecycle {
    prevent_destroy = true
    postcondition {
      condition     = self.archived_at == null
      error_message = "The federation rule ${self.name} (${self.id}) was archived: it is not made again, as that would give it a new ID (README, The Anthropic organization)."
    }
  }
}

import {
  for_each = { for k, l in local.adopt : k => l.issuer.adopt if l.issuer.adopt != null }
  to       = anthropic_federation_issuer.llmproxy[each.key]
  id       = each.value
}

import {
  for_each = { for k, l in local.adopt : k => l.service_account.adopt if l.service_account.adopt != null }
  to       = anthropic_service_account.llmproxy[each.key]
  id       = each.value
}

import {
  for_each = { for k, l in local.adopt : k => l.rule.adopt if l.rule.adopt != null }
  to       = anthropic_federation_rule.llmproxy[each.key]
  id       = each.value
}

# The bootstrap: read, never managed (an OAuth caller may change neither an org:admin rule nor an admin account). A
# change made to it in the Console fails a check below, which the plan shows and the drift job reports (ci/tofu.sh).
data "anthropic_federation_rule" "admin" {
  for_each = var.admin == null ? {} : { admin = var.admin.federation_rule_id }
  id       = each.value
}

data "anthropic_federation_issuer" "admin" {
  for_each = data.anthropic_federation_rule.admin
  id       = each.value.issuer_id
}

data "anthropic_service_account" "admin" {
  for_each = var.admin == null ? {} : { admin = var.admin.service_account_id }
  id       = each.value
}

check "admin" {
  assert {
    condition     = alltrue([for r in data.anthropic_federation_rule.admin : r.oauth_scope == "org:admin" && r.archived_at == null])
    error_message = "The bootstrap rule is no longer a live org:admin rule (README, The Anthropic organization)."
  }
  assert {
    condition = alltrue([for r in data.anthropic_federation_rule.admin :
      r.match.subject_prefix == local.admin.subject && r.match.claims == tomap(local.admin.claims) && r.match.audience == local.admin.audience && r.match.condition == null
    ])
    error_message = "The bootstrap rule matches other tokens than ${local.admin.subject}'s, protected, for ${local.admin.audience} (README, The Anthropic organization)."
  }
  assert {
    condition     = alltrue([for r in data.anthropic_federation_rule.admin : r.target.service_account_id == var.admin.service_account_id])
    error_message = "The bootstrap rule acts as another service account than the pipeline's (README, The Anthropic organization)."
  }
  assert {
    condition     = alltrue([for i in data.anthropic_federation_issuer.admin : i.issuer_url == local.admin.issuer_url && i.archived_at == null])
    error_message = "The bootstrap rule's issuer is not ${local.admin.issuer_url}'s, live (README, The Anthropic organization)."
  }
  assert {
    condition     = alltrue([for a in data.anthropic_service_account.admin : a.organization_role == "admin" && a.archived_at == null])
    error_message = "The pipeline's service account is no longer a live admin account (README, The Anthropic organization)."
  }
}

# What each deployment's pipeline gives its llmproxy (none of it secret): the rule it exchanges through, the account
# it acts as, the workspace, and the organization.
output "llmproxy" {
  value = {
    for k, l in local.llmproxy : k => {
      organization_id    = try(var.admin.organization_id, null)
      federation_rule_id = anthropic_federation_rule.llmproxy[k].id
      service_account_id = anthropic_service_account.llmproxy[k].id
      workspace_id       = l.workspace_id
      issuer_id          = anthropic_federation_issuer.llmproxy[k].id
    }
  }
}
