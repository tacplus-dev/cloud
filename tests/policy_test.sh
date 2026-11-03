#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/policy.sh: in the source, it refuses a module that creates a service-account key, names allUsers or
# allAuthenticatedUsers, or resolves at plan time what a commit does not fix (timestamp(), an image's :latest, an
# image family), and passes this repository's modules and stacks; in a saved plan's JSON, it refuses a key created
# and any public member, in member, members, a policy_data document or nested anywhere, and passes a plan without
# them (a key deleted is not one created). Needs bash and jq.
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
echo '{' > "${tmp:=$(mktemp)}"
refuses "a plan that is not JSON" "not a plan" plan "$tmp"
rm -f "$tmp"
refuses "no mode" "usage" nothing

exit "$failed"
