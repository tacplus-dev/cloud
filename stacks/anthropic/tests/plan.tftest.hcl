# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The anthropic stack's plan against a mock provider (no credential, no Anthropic; #34): one identity per deployment
# that runs llmproxy, seatrials' its rule for llmproxy's own subject alone, in its workspace, as a developer account,
# with a workspace scope; nothing org-level; and the bootstrap rule only read, and checked.

mock_provider "anthropic" {
  mock_resource "anthropic_federation_issuer" {
    defaults = { id = "fdis_new", archived_at = null }
  }
  mock_resource "anthropic_service_account" {
    defaults = { id = "svac_new", archived_at = null }
  }
  mock_resource "anthropic_federation_rule" {
    defaults = { id = "fdrl_new", archived_at = null }
  }
}

run "stack" {
  command = plan
  variables {
    import_existing = false
  }
  assert {
    condition     = keys(anthropic_federation_rule.llmproxy) == ["seatrials"]
    error_message = "The stack makes llmproxy identities for other deployments than seatrials."
  }
  assert {
    condition     = anthropic_federation_issuer.llmproxy["seatrials"].issuer_url == "https://seatrials.tacplus.dev" && anthropic_federation_issuer.llmproxy["seatrials"].name == "seatrials" && anthropic_federation_issuer.llmproxy["seatrials"].jwks.type == "discovery"
    error_message = "seatrials' issuer is not its fleet's (https://seatrials.tacplus.dev, by OIDC discovery)."
  }
  assert {
    condition     = anthropic_federation_rule.llmproxy["seatrials"].match.subject_prefix == "spiffe://local.dev/system/services/llmproxy" && anthropic_federation_rule.llmproxy["seatrials"].match.claims == null && anthropic_federation_rule.llmproxy["seatrials"].match.condition == null
    error_message = "seatrials' rule matches other tokens than llmproxy's own (an exact subject, no prefix)."
  }
  assert {
    condition     = contains(["workspace:developer", "workspace:inference"], anthropic_federation_rule.llmproxy["seatrials"].oauth_scope) && anthropic_federation_rule.llmproxy["seatrials"].workspace_id == "wrkspc_017AfVbSBgLY399kXGDRtQ6e" && anthropic_federation_rule.llmproxy["seatrials"].applies_to_all_workspaces != true
    error_message = "seatrials' rule is not a workspace scope in its one workspace."
  }
  assert {
    condition     = anthropic_service_account.llmproxy["seatrials"].name == "llmproxy-seatrials" && anthropic_service_account.llmproxy["seatrials"].organization_role == "developer"
    error_message = "seatrials' llmproxy account is not llmproxy-seatrials, a developer."
  }
  assert {
    condition     = anthropic_service_account_workspace.llmproxy["seatrials"].workspace_id == "wrkspc_017AfVbSBgLY399kXGDRtQ6e" && anthropic_service_account_workspace.llmproxy["seatrials"].workspace_role == "workspace_developer"
    error_message = "seatrials' llmproxy account is not a developer of its workspace."
  }
  assert {
    condition     = length(data.anthropic_federation_rule.admin) == 0 && length(data.anthropic_service_account.admin) == 0
    error_message = "Without the bootstrap rule (var.admin), the stack reads it."
  }
}

# With the bootstrap rule set, as the pipeline gives it (ci/lib.sh's ci_anthropic): it is read, never managed, and a
# rule that is still the bootstrap passes the check.
run "admin" {
  command = plan
  variables {
    import_existing = false
    admin           = { organization_id = "deec78e0-a50d-4817-89e4-043b3d94a5a0", federation_rule_id = "fdrl_admin", service_account_id = "svac_admin" }
  }
  override_data {
    target = data.anthropic_federation_rule.admin["admin"]
    values = {
      oauth_scope = "org:admin", archived_at = null, issuer_id = "fdis_gitlab"
      match       = { subject_prefix = "project_path:tacplus-dev/cloud:ref_type:branch:ref:main", claims = { ref_protected = "true" }, audience = "https://api.anthropic.com", condition = null }
      target      = { service_account_id = "svac_admin", service_account_name = "cloud-admin-pipeline" }
    }
  }
  override_data {
    target = data.anthropic_federation_issuer.admin["admin"]
    values = { issuer_url = "https://gitlab.com", archived_at = null }
  }
  override_data {
    target = data.anthropic_service_account.admin["admin"]
    values = { organization_role = "admin", archived_at = null }
  }
  assert {
    condition     = data.anthropic_federation_rule.admin["admin"].id == "fdrl_admin" && data.anthropic_service_account.admin["admin"].id == "svac_admin"
    error_message = "The stack does not read the bootstrap rule and account it is given."
  }
  assert {
    condition     = output.llmproxy["seatrials"].organization_id == "deec78e0-a50d-4817-89e4-043b3d94a5a0" && output.llmproxy["seatrials"].workspace_id == "wrkspc_017AfVbSBgLY399kXGDRtQ6e"
    error_message = "The output does not give seatrials' pipeline its organization and workspace."
  }
}

# A bootstrap rule widened in the Console (a prefix subject) fails the check, which the plan and the drift report.
run "admin_changed" {
  command = plan
  variables {
    import_existing = false
    admin           = { organization_id = "deec78e0-a50d-4817-89e4-043b3d94a5a0", federation_rule_id = "fdrl_admin", service_account_id = "svac_admin" }
  }
  override_data {
    target = data.anthropic_federation_rule.admin["admin"]
    values = {
      oauth_scope = "org:admin", archived_at = null, issuer_id = "fdis_gitlab"
      match       = { subject_prefix = "project_path:tacplus-dev/*", claims = { ref_protected = "true" }, audience = "https://api.anthropic.com", condition = null }
      target      = { service_account_id = "svac_admin", service_account_name = "cloud-admin-pipeline" }
    }
  }
  override_data {
    target = data.anthropic_federation_issuer.admin["admin"]
    values = { issuer_url = "https://gitlab.com", archived_at = null }
  }
  override_data {
    target = data.anthropic_service_account.admin["admin"]
    values = { organization_role = "admin", archived_at = null }
  }
  expect_failures = [check.admin]
}
