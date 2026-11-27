#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/policy.sh: in the source, it refuses a module that creates a service-account key, names allUsers or
# allAuthenticatedUsers, or resolves at plan time what a commit does not fix (timestamp(), an image's :latest, an
# image family), and passes this repository's modules and stacks; in a saved plan's JSON, it refuses a key created
# and any public member, in member, members, a policy_data document or nested anywhere, and passes a plan without
# them (a key deleted is not one created); and the network rules of 2026-11-03 (#7): it refuses an instance or a
# template with an external address (an access config, or one known only after apply), or an SSH key in its metadata,
# and a looper VM that does not block the project's (#108), an allow rule open to the
# internet (0.0.0.0/0, ::/0, or no source at all), a rule allowing port 22 (a port, a range or all ports, either
# direction, with no exception: the runners' internal rule too, since #113), a cluster without private nodes, one whose
# control plane has a public endpoint, no authorized networks or a public range among them (#79), a pool
# with public nodes or not on COS, and passes a plan that keeps them; and the one public IP (#13): in the source, a
# global address without prevent_destroy, and in a plan, an external address but the one global address `gateway`, or
# an external forwarding rule but the TCP proxy's on it; we terminate TLS, not the cloud (#21): the forwarding rule on
# gateway is global, EXTERNAL_MANAGED and TCP, to a target TCP proxy (known, or a reference when known only after
# apply), and a certificate, Certificate Manager, an SSL policy, an HTTP(S) or SSL proxy or a URL map is refused, as is
# ingress from a public range but Google's proxies' and health checkers'; and roles/owner or roles/editor to any
# service account, the pipeline's own included (#78), and roles/container.admin to one but the pipeline (#18), in a
# member, a member list or a policy document, or to a member known only after apply; and in the Anthropic organization (#34), an identity adopted with a change, a
# rule of another scope than workspace:developer or workspace:inference, an account of another role than developer;
# and it passes the plan that deletes the runner manager and its SSH rule (#113: their guards went with them); and hub-audit
# (#77), the audit job's account, granted any role but its read roles (its registries role, #115, on its own project,
# and that role with any permission but listing the repositories and reading their policies); the release registry
# (#115) written by any account but release-publish, read by any member but a service account, or another role on it; and a gates job's request (#87), a
# BUILD_GATES_REQUESTS_<repo> requesting more than 3 CPU or 10Gi, or one it cannot read; and the node pools' quotas
# (#88), a plan whose C4A pools its Cloud Quotas preferences do not cover (none, another region's, or fewer CPUs or
# Hyperdisk Balanced GB than the pools need at their maximum with a node being replaced), or one without a contact.
# Needs bash and jq.
#
#   tests/policy_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
policy=$here/ci/policy.sh
fx=$here/tests/fixtures
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

refuses() { # refuses WHAT EXPECTED-MESSAGE ARGS...: policy.sh ARGS fails, saying EXPECTED-MESSAGE
  local what=$1 want=$2 out; shift 2
  if out=$("$policy" "$@" 2>&1); then fail "$what: passed"; echo "$out" | sed 's/^/     /'
  elif [[ $out != *"$want"* ]]; then fail "$what: refused without [$want]: $out"
  else ok "$what: refused"; fi
}
passes() { # passes WHAT ARGS...
  local what=$1 out; shift
  if out=$("$policy" "$@" 2>&1); then ok "$what: passes"; else fail "$what: refused: $out"; fi
}

refuses "a module with a service-account key" "google_service_account_key" source "$fx/policy/key"
refuses "a module granting allUsers" "allUsers" source "$fx/policy/public"
refuses "a module naming allAuthenticatedUsers" "allAuthenticatedUsers" source "$fx/policy/authenticated"
refuses "a module with timestamp()" "timestamp(" source "$fx/policy/timestamp"
refuses "a module with an image at :latest" ":latest" source "$fx/policy/latest"
refuses "a module booting an image family" "an image family" source "$fx/policy/family"
refuses "the repository and a bad module together" "google_service_account_key" source "$here/modules" "$fx/policy/key"
refuses "a global address without prevent_destroy" "google_compute_global_address.gateway has no prevent_destroy" source "$fx/policy/unprotected-address"
passes "a clean module" source "$fx/policy/clean"
passes "this repository's modules and stacks" source "$here/modules" "$here/stacks"
refuses "a missing directory" "no such directory" source "$fx/policy/none"
# No VM outside GKE (#11): no standalone VM anywhere; templates and groups but the ci module's looper_vm and reserved_vm.
refuses "a module with a standalone instance (#11)" 'google_compute_instance.bastion is a VM outside GKE' source "$fx/policy/vm-instance"
refuses "a module with an instance from a template (#11)" 'google_compute_instance_from_template.one is a VM outside GKE' source "$fx/policy/vm-instance"
refuses "a looper VM's template outside the ci module (#11)" 'google_compute_instance_template.looper_vm is a VM outside GKE' source "$fx/policy/vm-template"
refuses "a module with a regional instance group (#11)" 'google_compute_region_instance_group_manager.pool is a VM outside GKE' source "$fx/policy/vm-template"
refuses "another template in the ci module (#11)" 'google_compute_instance_template.builder is a VM outside GKE' source "$fx/policy/vm-ci-other"
passes "the ci module's looper VMs and reserved machines, a VM read and one removed (#11)" source "$fx/policy/vm-admitted"

refuses "a plan creating a key" "creates a service-account key" plan "$fx/plans/key.json"
refuses "a plan with member allUsers" "allUsers" plan "$fx/plans/public-member.json"
refuses "a plan with allAuthenticatedUsers in members" "allAuthenticatedUsers" plan "$fx/plans/public-members.json"
refuses "a plan with allUsers in a policy document" "allUsers" plan "$fx/plans/public-policy.json"
refuses "a plan with allUsers nested deep" "allUsers" plan "$fx/plans/public-nested.json"
refuses "a clean plan and a bad one" "allUsers" plan "$fx/plans/clean.json" "$fx/plans/public-member.json"
passes "a clean plan" plan "$fx/plans/clean.json"
# The Anthropic organization (#34): an adoption with no change, then a change in a commit of its own, passes; an
# adoption with a change, an org-level rule or an admin account made by the pipeline is refused.
passes "adoptions with no change, then an update and a create" plan "$fx/plans/anthropic-clean.json"
refuses "an adoption with a change" 'anthropic_federation_rule.llmproxy["seatrials"] is adopted with a change' plan "$fx/plans/anthropic-adopt-change.json"
# It says what differs, the Console's value then the config's: the plan's text is printed only once the policy passes.
# Not a list known only after apply (the rule's workspace_ids), element by element as "null here".
refuses "an adoption with a change, what differs" 'is adopted with a change (attributes.k: sensitive; description: "llmproxy for seatrials" in the Console, null here; match.audience: "https://api.anthropic.com" in the Console, null here; oauth_scope: "workspace:developer" in the Console, "workspace:inference" here): an adoption plans none' plan "$fx/plans/anthropic-adopt-change.json"
if "$policy" plan "$fx/plans/anthropic-adopt-change.json" 2>&1 | grep -q secret; then fail "an adoption with a change: prints a sensitive value"
else ok "an adoption with a change: prints no sensitive value"; fi
refuses "an org:admin rule" "grants org:admin" plan "$fx/plans/anthropic-admin-scope.json"
refuses "an admin service account" "has the organization role admin" plan "$fx/plans/anthropic-admin-account.json"
passes "a plan deleting a key" plan "$fx/plans/key-deleted.json"

refuses "a plan with an instance's access config" "an external address" plan "$fx/plans/instance-access-config.json"
refuses "a plan with a template's IPv6 access config" "an external address" plan "$fx/plans/template-ipv6-access-config.json"
refuses "a plan with a template's access config unknown" "known only after apply" plan "$fx/plans/template-access-unknown.json"
refuses "a plan with an SSH key in a VM's metadata (#108)" "has an SSH key in its metadata" plan "$fx/plans/looper-vm-ssh-key.json"
refuses "a plan with a looper VM that does not block the project's SSH keys (#108)" "does not block the project's SSH keys" plan "$fx/plans/looper-vm-project-keys.json"
passes "a plan with a looper VM with no SSH key, the project's blocked, and no external address (#108)" plan "$fx/plans/looper-vm-clean.json"
# No VM outside GKE (#11; decisions/looper-build-vms-2026-11-24.md): no standalone VM, created or updated, in any stack;
# an instance template or group but the ci module's looper_vm and reserved_vm, which boot Container-Optimized OS.
for a in module.dev.google_compute_instance.bastion module.ci.google_compute_instance_from_template.one \
  module.ci.google_compute_instance_from_machine_image.copy google_compute_instance.kept; do
  refuses "a plan with a standalone VM, $a (#11)" "$a is a VM outside GKE" plan "$fx/plans/vm-instance.json"
done
for a in module.ci.google_compute_instance_template.other 'module.ci.google_compute_region_instance_template.looper_vm["tacplus"]' \
  'module.dev.google_compute_instance_template.looper_vm["tacplus"]' module.ci.google_compute_instance_group_manager.other \
  'module.ci.google_compute_region_instance_group_manager.reserved_vm["merger"]'; do
  refuses "a plan with a VM not admitted, $a (#11)" "$a is a VM outside GKE" plan "$fx/plans/vm-template.json"
done
passes "a plan with the looper VMs and reserved machines on COS, and the runners' VMs deleted (#11)" plan "$fx/plans/vm-admitted.json"
for k in merger family unknown nodisk; do
  refuses "a plan with an admitted VM not on pinned COS, $k (#11)" "[\"$k\"] does not boot Container-Optimized OS" plan "$fx/plans/vm-not-cos.json"
done
refuses "a plan with ingress from 0.0.0.0/0" "from the internet" plan "$fx/plans/ingress-world.json"
refuses "a plan with ingress from ::/0" "from the internet" plan "$fx/plans/ingress-world6.json"
refuses "a plan with ingress from no source (0.0.0.0/0)" "from the internet" plan "$fx/plans/ingress-no-source.json"
refuses "a plan with a rule's sources unknown" "known only after apply" plan "$fx/plans/ingress-unknown.json"
refuses "a plan with SSH from IAP" "port 22" plan "$fx/plans/ssh.json"
refuses "a plan with a port range covering 22" "port 22" plan "$fx/plans/ssh-range.json"
refuses "a plan allowing all protocols" "port 22" plan "$fx/plans/ssh-all.json"
refuses "a plan with egress allowing all tcp ports" "port 22" plan "$fx/plans/ssh-egress.json"
refuses "a plan with the runners' old SSH rule, exactly as it was (#113: no exception left)" "port 22" plan "$fx/plans/ssh-runners.json"
refuses "a plan with a cluster without private nodes" "private nodes" plan "$fx/plans/cluster-public-nodes.json"
refuses "a plan with a cluster's public endpoint" "google_container_cluster.c has a public control-plane endpoint" plan "$fx/plans/cluster-public-endpoint.json"
refuses "a plan with a cluster without authorized networks" "google_container_cluster.c has no master authorized networks" plan "$fx/plans/cluster-no-authorized-networks.json"
refuses "a plan authorizing a public range to a control plane" "google_container_cluster.c authorizes 35.191.0.0/16 to its control plane, a public range" plan "$fx/plans/cluster-authorized-public.json"
refuses "a plan authorizing Google Cloud's public ranges to a control plane" "google_container_cluster.c authorizes Google Cloud's public ranges" plan "$fx/plans/cluster-authorized-google.json"
refuses "a plan with a pool with public nodes" "public nodes" plan "$fx/plans/pool-public-nodes.json"
refuses "a plan with a pool not on COS" "Container-Optimized OS" plan "$fx/plans/pool-not-cos.json"
refuses "a plan with a regional external address" "google_compute_address.lb is an external address" plan "$fx/plans/address-regional.json"
refuses "a plan with a second global address" "module.dev.google_compute_global_address.other is an external address" plan "$fx/plans/address-second.json"
refuses "a plan with an external forwarding rule" "google_compute_global_forwarding_rule.lb is an external forwarding rule" plan "$fx/plans/forwarding-rule.json"
passes "a plan with the gateway's address, internal ones and a deleted one" plan "$fx/plans/address-clean.json"

refuses "a plan with an external forwarding rule on its own IP" "lb[\"test-idp\"] is an external forwarding rule but a TCP proxy's" plan "$fx/plans/lb-other-ip.json"
refuses "a plan with a forwarding rule on another address" "lb[\"gateway\"] is an external forwarding rule but a TCP proxy's" plan "$fx/plans/lb-other-address.json"
refuses "a plan with the classic TCP proxy (EXTERNAL)" "lb[\"test-idp\"] is an external forwarding rule but a TCP proxy's" plan "$fx/plans/lb-classic.json"
refuses "a plan with a forwarding rule to an HTTPS proxy" "lb[\"test-idp\"] is an external forwarding rule but a TCP proxy's" plan "$fx/plans/lb-https-target.json"
refuses "a plan with a forwarding rule to an SSL proxy, known after apply" "lb[\"gateway\"] is an external forwarding rule but a TCP proxy's" plan "$fx/plans/lb-ssl-target.json"
for t in google_compute_ssl_certificate google_compute_managed_ssl_certificate google_certificate_manager_certificate \
  google_certificate_manager_certificate_map google_compute_target_https_proxy google_compute_region_target_https_proxy \
  google_compute_target_ssl_proxy google_compute_target_http_proxy google_compute_url_map google_compute_ssl_policy; do
  refuses "a plan with a $t" "$t.gateway is a $t: we terminate TLS, not the cloud" plan "$fx/plans/lb-tls.json"
done
for r in 34.9.9.9/32 35.190.0.0/15 35.235.240.0/20 2600:1900::/28; do
  refuses "a plan admitting ingress from $r" "allows ingress from $r, a public range" plan "$fx/plans/ingress-public.json"
done
passes "a plan with the TCP proxy on gateway, Google's ranges and private ones" plan "$fx/plans/lb-clean.json"
passes "a plan building the TCP proxy and the address together" plan "$fx/plans/lb-first-build.json"
passes "a plan keeping the network rules" plan "$fx/plans/network-clean.json"
passes "a plan deleting an SSH rule" plan "$fx/plans/ssh-deleted.json"
# The runner manager and its SSH rule deleted (#113): the guards that kept it (#46, #48) went with it.
passes "a plan deleting the runner manager and its SSH rule" plan "$fx/plans/manager-delete.json"

refuses "a plan granting a service account container.admin" "grants roles/container.admin to serviceAccount:cluster-admin-pipeline@tacplus-dev" plan "$fx/plans/admin-project-member.json"
refuses "a plan with a service account in an owner binding" "grants roles/owner to serviceAccount:gke-nodes@tacplus-dev" plan "$fx/plans/admin-owner-binding.json"
refuses "a plan with owner to a service account in a policy document" "grants roles/owner to serviceAccount:x@tacplus-dev" plan "$fx/plans/admin-policy.json"
refuses "a plan granting owner to a member known only after apply" "known only after apply" plan "$fx/plans/admin-member-unknown.json"
# No pipeline account holds owner or editor (#78), cloud-admin-pipeline neither: its rights are the host's narrower grants.
refuses "a plan granting the pipeline owner of a folder (#78)" "grants roles/owner to serviceAccount:cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com: no service account holds it, the pipeline neither" plan "$fx/plans/admin-pipeline-owner.json"
refuses "a plan granting a service account editor (#78)" "grants roles/editor to serviceAccount:seatrials-deploy@tacplus-dev.iam.gserviceaccount.com" plan "$fx/plans/admin-editor.json"
refuses "a plan with the pipeline's editor in a policy document (#78)" "grants roles/editor to serviceAccount:cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com" plan "$fx/plans/admin-pipeline-editor-policy.json"
refuses "a plan granting editor to members known only after apply (#78)" "grants roles/editor to a member known only after apply" plan "$fx/plans/admin-editor-unknown.json"
passes "a plan with the pipeline's own container.admin, a viewer, a person's owner and a deleted grant" plan "$fx/plans/admin-clean.json"
# hub-audit, the audit job's account (#77), reads only: a write role to it is refused, in a member, a member list or a
# policy document; its five read roles on both projects, and its federation, pass.
refuses "a plan granting hub-audit a write role" "grants roles/compute.admin to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com: the audit's account reads only" plan "$fx/plans/hub-audit-write.json"
refuses "a plan with hub-audit in an editor binding" "grants roles/editor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com" plan "$fx/plans/hub-audit-binding.json"
refuses "a plan with a secret's accessor to hub-audit in a policy document" "grants roles/secretmanager.secretAccessor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com" plan "$fx/plans/hub-audit-policy.json"
passes "a plan with hub-audit's read roles on both projects, its federation and a write role deleted" plan "$fx/plans/hub-audit-clean.json"
# The cluster autoscaler's log (#85, Jody's option A): hub-audit reads the view hub-audit-autoscaler alone, by
# roles/logging.viewAccessor in a member conditioned on that view of the member's own project, and the view holds that
# log alone; never logging.viewer, nor any other log, as a job's output may hold a secret.
passes "a plan with the views hub-audit-autoscaler and hub-audit's viewAccessor on them alone (#85)" plan "$fx/plans/hub-audit-autoscaler-clean.json"
refuses "a plan granting hub-audit viewAccessor with no condition (#85)" "grants roles/logging.viewAccessor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com but on the view hub-audit-autoscaler of its project alone" plan "$fx/plans/hub-audit-accessor-unconditioned.json"
refuses "a plan granting hub-audit viewAccessor on another view (#85)" "grants roles/logging.viewAccessor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com but on the view hub-audit-autoscaler of its project alone" plan "$fx/plans/hub-audit-accessor-other-view.json"
refuses "a plan granting hub-audit viewAccessor on another project's view (#85)" "grants roles/logging.viewAccessor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com but on the view hub-audit-autoscaler of its project alone" plan "$fx/plans/hub-audit-accessor-other-project.json"
refuses "a plan with hub-audit in a viewAccessor binding, conditioned or not (#85)" "google_project_iam_binding.view_accessors grants roles/logging.viewAccessor to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com" plan "$fx/plans/hub-audit-accessor-binding.json"
refuses "a plan granting hub-audit logging.viewer (#85)" "grants roles/logging.viewer to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com: the audit's account reads only" plan "$fx/plans/hub-audit-logging-viewer.json"
refuses "a plan widening the view hub-audit-autoscaler's filter (#85)" "the view hub-audit-autoscaler filters" plan "$fx/plans/hub-audit-autoscaler-wide.json"
# The registries' IAM (#115): hub-audit's own role on each project lists the repositories and reads their policies,
# never an image; granted on its own project alone. The release registry: release-publish alone writes, service
# accounts alone read, no other role.
passes "a plan with hub-audit's registries role on both projects and the release registry's writer and reader (#115)" plan "$fx/plans/registries-clean.json"
refuses "a plan giving hub-audit's registries role a download (#115)" "the role hubAuditRegistries holds artifactregistry.repositories.downloadArtifacts" plan "$fx/plans/registries-role-download.json"
refuses "a plan granting hub-audit another project's registries role (#115)" "grants projects/tacplus-dev/roles/hubAuditRegistries to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com: the audit's account reads only" plan "$fx/plans/registries-grant-other-project.json"
refuses "a plan granting hub-audit another custom role (#115)" "grants projects/tacplus-ci/roles/kmsKeyVersionImporter to serviceAccount:hub-audit@tacplus-ci.iam.gserviceaccount.com: the audit's account reads only" plan "$fx/plans/registries-grant-other-role.json"
refuses "a plan with another writer of the release registry (#115)" "grants roles/artifactregistry.writer on the release registry to serviceAccount:build-cache@tacplus-ci.iam.gserviceaccount.com: release-publish alone writes it" plan "$fx/plans/releases-writer-other.json"
refuses "a plan with a user reading the release registry (#115)" "grants roles/artifactregistry.reader on the release registry to user:someone@example.com: only a deployment's service account reads it" plan "$fx/plans/releases-reader-user.json"
refuses "a plan with another role on the release registry (#115)" "grants roles/artifactregistry.repoAdmin on the release registry: its roles are writer (release-publish) and reader alone" plan "$fx/plans/releases-other-role.json"
# A gates job's requests (#87): BUILD_GATES_REQUESTS_<repo>'s request fits a c4a-standard-4 spot node after its
# DaemonSets, at most 3 CPU and 10Gi; only its limits may be the runner's ceilings (3500m 12Gi).
refuses "a plan requesting 3500m for a gates job (#87)" "BUILD_GATES_REQUESTS_tacplus requests 3500m CPU, more than 3 CPU" plan "$fx/plans/gates-requests-cpu.json"
refuses "a plan requesting 12Gi for a gates job (#87)" "BUILD_GATES_REQUESTS_tacplus requests 12Gi of memory, more than 10Gi" plan "$fx/plans/gates-requests-memory.json"
refuses "a plan with a gates job's request it cannot read (#87)" "BUILD_GATES_REQUESTS_tacplus: its request (\"three 10Gi\") cannot be read" plan "$fx/plans/gates-requests-unreadable.json"
passes "a plan with gates jobs requesting 3 CPU 10Gi and 2500m 10240Mi, limits 3500m 12Gi, and a larger one deleted (#87)" plan "$fx/plans/gates-requests-clean.json"
# The node pools' quotas (#88): 3 normal c4a-standard-2 and spot c4a-standard-4 to 5, 100 GB of Hyperdisk Balanced each,
# need 6 + 20 + 4 (a node being replaced) = 30 C4A CPUs and (3 + 5 + 1) x 100 = 900 GB in us-central1.
passes "a plan whose quota preferences ask 32 C4A CPUs and 1000 GB of Hyperdisk Balanced for its pools (#88)" plan "$fx/plans/quotas-clean.json"
passes "a plan whose quota preferences ask exactly what its pools need (#88)" plan "$fx/plans/quotas-exact.json"
refuses "a plan whose C4A CPU preference is short of its pools (#88)" "asks 24 C4A CPUs, fewer than the 30 the node pools of tacplus-dev in us-central1 need" plan "$fx/plans/quotas-cpus-short.json"
refuses "a plan whose Hyperdisk Balanced preference is short of its pools (#88)" "asks 500 GB of Hyperdisk Balanced, fewer than the 900" plan "$fx/plans/quotas-hdb-short.json"
refuses "a plan with C4A pools and no C4A CPU preference (#88)" "need 30 C4A CPUs at their maximum, with one node being replaced, and no quota preference asks for them" plan "$fx/plans/quotas-missing.json"
refuses "a plan whose C4A CPU preference is of another region (#88)" "need 30 C4A CPUs at their maximum, with one node being replaced, and no quota preference asks for them" plan "$fx/plans/quotas-other-region.json"
refuses "a plan with a quota preference without a contact (#88)" "has no contact_email: Google refuses an increase without one" plan "$fx/plans/quotas-no-contact.json"
# And the looper pool from 0 to 2 c4a-standard-2 (#95): 34 C4A CPUs and (3 + 5 + 2 + 1) x 100 = 1100 GB; the pools'
# checks are the same for all three.
passes "a plan with the looper pool whose quota preferences ask 40 C4A CPUs and 1500 GB of Hyperdisk Balanced (#95)" plan "$fx/plans/quotas-looper.json"
refuses "a plan adding the looper pool without its C4A CPUs (#95)" "asks 32 C4A CPUs, fewer than the 34 the node pools of tacplus-dev in us-central1 need" plan "$fx/plans/quotas-looper-short.json"
refuses "a plan adding the looper pool without its Hyperdisk Balanced (#95)" "asks 1000 GB of Hyperdisk Balanced, fewer than the 1100" plan "$fx/plans/quotas-looper-short.json"
refuses "a plan with the looper pool on public nodes (#95)" "module.dev.google_container_node_pool.pool[\"looper\"] has public nodes" plan "$fx/plans/quotas-looper-public.json"
echo '{' > "${tmp:=$(mktemp)}"
refuses "a plan that is not JSON" "not a plan" plan "$tmp"
rm -f "$tmp"
refuses "no mode" "usage" nothing

exit "$failed"
