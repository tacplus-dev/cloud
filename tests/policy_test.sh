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
# an external forwarding rule (the Gateway's are GKE's, never a stack's). Needs bash and jq.
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

refuses "a plan creating a key" "creates a service-account key" plan "$fx/plans/key.json"
refuses "a plan with member allUsers" "allUsers" plan "$fx/plans/public-member.json"
refuses "a plan with allAuthenticatedUsers in members" "allAuthenticatedUsers" plan "$fx/plans/public-members.json"
refuses "a plan with allUsers in a policy document" "allUsers" plan "$fx/plans/public-policy.json"
refuses "a plan with allUsers nested deep" "allUsers" plan "$fx/plans/public-nested.json"
refuses "a clean plan and a bad one" "allUsers" plan "$fx/plans/clean.json" "$fx/plans/public-member.json"
passes "a clean plan" plan "$fx/plans/clean.json"
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
passes "a plan keeping the network rules" plan "$fx/plans/network-clean.json"
passes "a plan deleting an SSH rule" plan "$fx/plans/ssh-deleted.json"
echo '{' > "${tmp:=$(mktemp)}"
refuses "a plan that is not JSON" "not a plan" plan "$tmp"
rm -f "$tmp"
refuses "no mode" "usage" nothing

exit "$failed"
