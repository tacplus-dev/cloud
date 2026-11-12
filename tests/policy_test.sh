#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/policy.sh: in the source, it refuses a module that creates a service-account key, names allUsers or
# allAuthenticatedUsers, or resolves at plan time what a commit does not fix (timestamp(), an image's :latest, an
# image family), and passes this repository's modules and stacks; in a saved plan's JSON, it refuses a key created
# and any public member, in member, members, a policy_data document or nested anywhere, and passes a plan without
# them (a key deleted is not one created); and the network rules of 2026-11-03 (#7): it refuses an instance or a
# template with an external address (an access config, or one known only after apply), an allow rule open to the
# internet (0.0.0.0/0, ::/0, or no source at all), a rule allowing port 22 (a port, a range or all ports, either
# direction; the runners' internal rule alone excepted, and only as it is), a cluster without private nodes, a pool
# with public nodes or not on COS, and passes a plan that keeps them; and the one public IP (#13): in the source, a
# global address without prevent_destroy, and in a plan, an external address but the one global address `gateway`, or
# an external forwarding rule but the TCP proxy's on it; we terminate TLS, not the cloud (#21): the forwarding rule on
# gateway is global, EXTERNAL_MANAGED and TCP, to a target TCP proxy (known, or a reference when known only after
# apply), and a certificate, Certificate Manager, an SSL policy, an HTTP(S) or SSL proxy or a URL map is refused, as is
# ingress from a public range but Google's proxies' and health checkers'; and roles/owner or roles/container.admin to a
# service account (#18), in a member, a member list or a policy document, or to a member known only after apply, the
# pipeline's own owner alone excepted; and in the Anthropic organization (#34), an identity adopted with a change, a
# rule of another scope than workspace:developer or workspace:inference, an account of another role than developer;
# and the runner manager (#46, #48): in the source, its instance without create_before_destroy or destroy = false, and
# in a plan, a VM tagged runner-manager destroyed: first, which would leave the fleet with no manager, or at all, a
# deposed one too, which would kill its running jobs (an old manager is forgotten, and retires by itself).
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
refuses "the runner manager without create_before_destroy" "google_compute_instance.manager is not create_before_destroy" source "$fx/policy/manager-destroy-first"
refuses "the runner manager without destroy = false (#48)" "google_compute_instance.manager is not destroy = false: an apply would delete the old manager, and its running jobs with it" source "$fx/policy/manager-deleted"
passes "a clean module" source "$fx/policy/clean"
passes "this repository's modules and stacks" source "$here/modules" "$here/stacks"
refuses "a missing directory" "no such directory" source "$fx/policy/none"

refuses "a plan creating a key" "creates a service-account key" plan "$fx/plans/key.json"
refuses "a plan with member allUsers" "allUsers" plan "$fx/plans/public-member.json"
refuses "a plan with allAuthenticatedUsers in members" "allAuthenticatedUsers" plan "$fx/plans/public-members.json"
refuses "a plan with allUsers in a policy document" "allUsers" plan "$fx/plans/public-policy.json"
refuses "a plan with allUsers nested deep" "allUsers" plan "$fx/plans/public-nested.json"
refuses "a plan opening the manager's binaries to allUsers (#40)" "allUsers" plan "$fx/plans/public-runner-bin.json"
refuses "a clean plan and a bad one" "allUsers" plan "$fx/plans/clean.json" "$fx/plans/public-member.json"
passes "a clean plan" plan "$fx/plans/clean.json"
# The Anthropic organization (#34): an adoption with no change, then a change in a commit of its own, passes; an
# adoption with a change, an org-level rule or an admin account made by the pipeline is refused.
passes "adoptions with no change, then an update and a create" plan "$fx/plans/anthropic-clean.json"
refuses "an adoption with a change" 'anthropic_federation_rule.llmproxy["seatrials"] is adopted with a change' plan "$fx/plans/anthropic-adopt-change.json"
refuses "an org:admin rule" "grants org:admin" plan "$fx/plans/anthropic-admin-scope.json"
refuses "an admin service account" "has the organization role admin" plan "$fx/plans/anthropic-admin-account.json"
passes "a plan deleting a key" plan "$fx/plans/key-deleted.json"

refuses "a plan with an instance's access config" "an external address" plan "$fx/plans/instance-access-config.json"
refuses "a plan with a template's IPv6 access config" "an external address" plan "$fx/plans/template-ipv6-access-config.json"
refuses "a plan with a template's access config unknown" "known only after apply" plan "$fx/plans/template-access-unknown.json"
refuses "a plan with ingress from 0.0.0.0/0" "from the internet" plan "$fx/plans/ingress-world.json"
refuses "a plan with ingress from ::/0" "from the internet" plan "$fx/plans/ingress-world6.json"
refuses "a plan with ingress from no source (0.0.0.0/0)" "from the internet" plan "$fx/plans/ingress-no-source.json"
refuses "a plan with a rule's sources unknown" "known only after apply" plan "$fx/plans/ingress-unknown.json"
refuses "a plan with SSH from IAP" "port 22" plan "$fx/plans/ssh.json"
refuses "a plan with a port range covering 22" "port 22" plan "$fx/plans/ssh-range.json"
refuses "a plan allowing all protocols" "port 22" plan "$fx/plans/ssh-all.json"
refuses "a plan with egress allowing all tcp ports" "port 22" plan "$fx/plans/ssh-egress.json"
refuses "a plan widening the runners' SSH rule" "port 22" plan "$fx/plans/ssh-exemption-widened.json"
refuses "a plan with a cluster without private nodes" "private nodes" plan "$fx/plans/cluster-public-nodes.json"
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
# The runner manager (#46): never destroyed before its replacement is up, so the fleet always has one.
refuses "a plan destroying the runner manager before creating its replacement" "module.ci.google_compute_instance.manager destroys the runner manager before its replacement exists" plan "$fx/plans/manager-destroy-first.json"
# Nor destroyed at all (#48): an old manager, deposed or replaced, is forgotten, and retires by itself once its jobs are done.
refuses "a plan replacing the runner manager create-before-destroy (#48)" "module.ci.google_compute_instance.manager destroys a runner manager: its running jobs would die with it" plan "$fx/plans/manager-create-then-delete.json"
refuses "a plan destroying a deposed runner manager (#48)" "module.ci.google_compute_instance.manager (deposed 01338cc8) destroys a runner manager" plan "$fx/plans/manager-deposed-delete.json"
passes "a plan forgetting the old managers, deposed too, creating the new one, updating one in place, and replacing another VM" plan "$fx/plans/manager-clean.json"

refuses "a plan granting a service account container.admin" "grants roles/container.admin to serviceAccount:cluster-admin-pipeline@tacplus-dev" plan "$fx/plans/admin-project-member.json"
refuses "a plan with a service account in an owner binding" "grants roles/owner to serviceAccount:gke-nodes@tacplus-dev" plan "$fx/plans/admin-owner-binding.json"
refuses "a plan with owner to a service account in a policy document" "grants roles/owner to serviceAccount:x@tacplus-dev" plan "$fx/plans/admin-policy.json"
refuses "a plan granting owner to a member known only after apply" "known only after apply" plan "$fx/plans/admin-member-unknown.json"
passes "a plan with the pipeline's own owner, a viewer, a person and a deleted grant" plan "$fx/plans/admin-clean.json"
echo '{' > "${tmp:=$(mktemp)}"
refuses "a plan that is not JSON" "not a plan" plan "$tmp"
rm -f "$tmp"
refuses "no mode" "usage" nothing

exit "$failed"
