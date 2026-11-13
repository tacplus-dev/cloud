#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Plans the anthropic stack with its real provider (our ippontech/anthropic build) against a stub API (tests/stubapi)
# that answers as Anthropic does for the identities made by hand in the Console (#34): tests/fixtures/anthropic/
# api.json, built from the API's documented answers (anthropic-sdk-go's types), not recorded: the looper has no
# Anthropic credential. The credential is the pipeline's, end to end: ci/lib.sh's ci_anthropic, the provider's
# federation through ci/anthropic-token.sh, each exchange presenting a token of its own. So: the plan adopts seatrials'
# issuer, account and rule by their IDs with no change, and makes the account's membership of its workspace (the
# account has only the implicit default-workspace one, as the first live plan found, 2026-11-12); it only reads; the
# bootstrap rule is read and passes the check; the apply's one write is that membership. Then, from that state: a
# Console edit of the rule plans the update that puts it back, with the same ID; a membership removed in the Console is
# made again; an identity archived in the Console fails the plan rather than making a new one; a widened bootstrap
# rule fails the check, and the drift lists it. Needs bin/ (ci/tools.sh), go, jq.
#
#   tests/anthropic_plan_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
work=$(mktemp -d)
stub=
trap '[ -n "$stub" ] && kill "$stub" 2>/dev/null; rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

go build -o "$work/stubapi" "$here/tests/stubapi/main.go" || { echo "FAIL cannot build tests/stubapi"; exit 1; }
# serve FIXTURE: the stub API, answering with FIXTURE, its log $work/requests emptied; ANTHROPIC_BASE_URL on it.
serve() {
  [ -n "$stub" ] && { kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null; }
  rm -f "$work/addr" && : > "$work/requests"
  "$work/stubapi" "$1" "$work/requests" "$work/addr" &
  stub=$!
  for _ in $(seq 50); do [ -s "$work/addr" ] && break; sleep 0.1; done
  [ -s "$work/addr" ] || { echo "FAIL the stub API does not listen"; exit 1; }
  ANTHROPIC_BASE_URL=http://$(cat "$work/addr")
  export ANTHROPIC_BASE_URL
}
fixture=$here/tests/fixtures/anthropic/api.json
# edit NAME JQ: a copy of the fixture changed by JQ, as the Console would have changed the API's answers.
edit() { jq "$2" "$fixture" > "$work/$1.json" && echo "$work/$1.json"; }

# The repository as it is (ci/ for the token command, bin/ for the providers), the stack's state local.
mkdir -p "$work/repo" && cp -r "$here/stacks" "$here/modules" "$here/ci" "$work/repo/" && ln -s "$here/bin" "$work/repo/bin"
find "$work/repo/stacks" -name .terraform -prune -exec rm -rf {} +
stack=$work/repo/stacks/anthropic
printf 'terraform {\n  backend "local" {}\n}\n' > "$stack/stub_override.tf"
# shellcheck source=ci/tofurc.sh
source "$work/repo/ci/tofurc.sh"
# The job's credential, as the anthropic jobs set it: the CI file's IDs and three ID tokens (any string to the stub).
export ANTHROPIC_ORGANIZATION_ID=deec78e0-a50d-4817-89e4-043b3d94a5a0 ANTHROPIC_FEDERATION_RULE_ID=fdrl_01CloudAdmin \
  ANTHROPIC_SERVICE_ACCOUNT_ID=svac_01CloudAdmin ANTHROPIC_ID_TOKEN_1=id-token-1 ANTHROPIC_ID_TOKEN_2=id-token-2 \
  ANTHROPIC_ID_TOKEN_3=id-token-3
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_ADMIN_API_KEY
# anthropic: ci_anthropic, in a fresh temporary directory (so all three tokens unclaimed), then tofu ARGS in the stack.
anthropic() {
  (
    ci_tmp=$(mktemp -d -p "$work") && source "$work/repo/ci/lib.sh" && ci_anthropic > /dev/null &&
      cd "$stack" && tofu "$@" -input=false -no-color && echo "claimed $(ls "$ANTHROPIC_ID_TOKENS_DIR" | wc -l)" >&2
  ) > "$work/out.txt" 2> "$work/err.txt"
}
plan() { rm -f "$stack/p.tfplan" "$work/plan.json"; anthropic plan -out=p.tfplan && (cd "$stack" && tofu show -json p.tfplan) > "$work/plan.json"; }
change() { jq -c --arg a "$1" '.resource_changes[] | select(.address == $a) | .change' "$work/plan.json"; }
others() { jq -r '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | .address] | join(" ")' "$work/plan.json"; }
exchanges() { grep -c '^POST /v1/oauth/token 200$' "$work/requests"; }
(cd "$stack" && tofu init -input=false -lockfile=readonly -no-color > "$work/init.txt" 2>&1) ||
  { echo "FAIL init: $(cat "$work/init.txt")"; exit 1; }

serve "$fixture"
if plan; then
  ok "the stack plans against the API's answers, federated through the bootstrap rule"
  for r in anthropic_federation_issuer anthropic_service_account anthropic_federation_rule; do
    c=$(change "$r.llmproxy[\"seatrials\"]")
    jq -e '.actions == ["no-op"] and (.importing.id | test("^(fdis|svac|fdrl)_"))' <<< "$c" > /dev/null || fail "$r: $c"
  done
  jq -e '.after.id == "fdrl_01Fvxu1oSKHN6rwtdZmRbGY8" and .after.target.service_account_id == "svac_01EoVk8wqp7sVYgBkRyyd5MT" and .after.issuer_id == "fdis_01JKxG3CyMXqfgcG8HoqorvT"' \
    <<< "$(change 'anthropic_federation_rule.llmproxy["seatrials"]')" > /dev/null &&
    ok "seatrials' issuer, account and rule: adopted by their IDs with no change" || fail "the adoption: $(others)"
  jq -e '.actions == ["create"] and .importing == null and .after.service_account_id == "svac_01EoVk8wqp7sVYgBkRyyd5MT" and
    .after.workspace_id == "wrkspc_017AfVbSBgLY399kXGDRtQ6e" and .after.workspace_role == "workspace_developer"' \
    <<< "$(change 'anthropic_service_account_workspace.llmproxy["seatrials"]')" > /dev/null &&
    ok "seatrials' account: made a member of its workspace, not adopted (it has only the implicit default one)" ||
    fail "the membership: $(change 'anthropic_service_account_workspace.llmproxy["seatrials"]')"
  [ "$(others)" = 'anthropic_service_account_workspace.llmproxy["seatrials"]' ] && ok "nothing else planned" || fail "the plan also changes: $(others)"
  jq -e '[.checks[] | select(.address.to_display == "check.admin")][0].status == "pass"' "$work/plan.json" > /dev/null &&
    ok "the bootstrap rule is read and passes the check" || fail "the bootstrap check: $(jq -c '.checks' "$work/plan.json")"
  "$here/ci/policy.sh" plan "$work/plan.json" > /dev/null 2>&1 && ok "ci/policy.sh passes the adoption and the membership" || fail "ci/policy.sh refuses the adoption"
else
  fail "the stack does not plan against the API's answers: $(grep -A6 'Error' "$work/out.txt" "$work/err.txt" | head -20)"
fi
n=$(exchanges)
[ "$n" -ge 1 ] && grep -q "^claimed $n\$" "$work/err.txt" &&
  ok "each of the plan's $n exchange(s) presented an ID token of its own" || fail "$n exchange(s), and $(grep claimed "$work/err.txt")"
! grep -v '^GET \|^POST /v1/oauth/token ' "$work/requests" > /dev/null && ok "a plan only reads" || fail "the plan wrote: $(grep -v '^GET ' "$work/requests")"

# The adoption applied: the imports write the state only; the one write to the API adds the membership.
add='POST /v1/organizations/service_accounts/svac_01EoVk8wqp7sVYgBkRyyd5MT/workspaces 200'
if anthropic apply p.tfplan && [ "$(grep -v '^GET \|^POST /v1/oauth/token ' "$work/requests")" = "$add" ]; then
  ok "the adoption applies, its one write the membership"
else
  fail "the adoption's apply: $(tail -5 "$work/out.txt" "$work/err.txt") $(grep -v '^GET ' "$work/requests")"
fi
# From here the API holds the membership too, as after that apply.
added=$(edit added '.["GET /v1/organizations/service_accounts/svac_01EoVk8wqp7sVYgBkRyyd5MT/workspaces"].data += [.["POST /v1/organizations/service_accounts/svac_01EoVk8wqp7sVYgBkRyyd5MT/workspaces"]]')
serve "$added"
plan && [ -z "$(others)" ] && ok "after the adoption, nothing to change" || fail "after the adoption: $(others) $(tail -3 "$work/err.txt")"

# A membership removed in the Console is made again: the API lists the implicit default one only.
serve "$fixture"
if plan; then
  jq -e '.actions == ["create"] and .after.workspace_id == "wrkspc_017AfVbSBgLY399kXGDRtQ6e"' <<< "$(change 'anthropic_service_account_workspace.llmproxy["seatrials"]')" > /dev/null &&
    [ "$(others)" = 'anthropic_service_account_workspace.llmproxy["seatrials"]' ] &&
    ok "a membership removed in the Console: made again, nothing else" || fail "a removed membership: $(others)"
else
  fail "a removed membership: no plan: $(grep -A4 Error "$work/err.txt" | head)"
fi
fixture=$added

# A Console edit of the rule (its subject widened to a prefix) is planned back, in place, with the same ID.
serve "$(edit console-edit '.["GET /v1/organizations/federation_rules/fdrl_01Fvxu1oSKHN6rwtdZmRbGY8"].match.subject_prefix = "spiffe://local.dev/*"')"
if plan; then
  c=$(change 'anthropic_federation_rule.llmproxy["seatrials"]')
  jq -e '.actions == ["update"] and .importing == null and .before.match.subject_prefix == "spiffe://local.dev/*" and
    .after.match.subject_prefix == "spiffe://local.dev/system/services/llmproxy" and .after.id == "fdrl_01Fvxu1oSKHN6rwtdZmRbGY8"' <<< "$c" > /dev/null &&
    [ "$(others)" = 'anthropic_federation_rule.llmproxy["seatrials"]' ] &&
    ok "a Console edit of the rule: planned back in place, the same ID" || fail "the Console edit: $(others) $c"
else
  fail "a Console edit: no plan: $(grep -A4 Error "$work/err.txt" | head)"
fi

# An identity archived in the Console fails the plan: it is not made again under a new ID.
for r in "federation_issuers/fdis_01JKxG3CyMXqfgcG8HoqorvT:federation issuer" "service_accounts/svac_01EoVk8wqp7sVYgBkRyyd5MT:service account" \
         "federation_rules/fdrl_01Fvxu1oSKHN6rwtdZmRbGY8:federation rule"; do
  serve "$(edit archived ".[\"GET /v1/organizations/${r%%:*}\"] |= (.archived_at = \"2026-11-12T08:00:00Z\" | .archived_by_actor_id = \"user_01Jody\")")"
  if plan; then fail "an archived ${r#*:}: planned: $(others)"
  else tr -s " \n" "  " < "$work/err.txt" | grep -q "The ${r#*:} [^ ]* ([a-z]*_[A-Za-z0-9]*) was archived" && ok "an archived ${r#*:}: the plan fails, nothing made again" ||
    fail "an archived ${r#*:}: failed otherwise: $(grep -A4 Error "$work/err.txt" | head)"; fi
done

# A bootstrap rule widened in the Console fails the check: the plan says so, and the drift lists it.
serve "$(edit widened '.["GET /v1/organizations/federation_rules/fdrl_01CloudAdmin"].match.subject_prefix = "project_path:tacplus-dev/*"')"
plan && jq -e '[.checks[] | select(.address.to_display == "check.admin")][0].status == "fail"' "$work/plan.json" > /dev/null &&
  [ -z "$(others)" ] && ok "a widened bootstrap rule fails the check, and changes nothing" || fail "a widened bootstrap rule: $(jq -c '.checks' "$work/plan.json" 2>&1)"
: > "$work/summary"
# shellcheck disable=SC2034 # ci/lib.sh reads ci_tmp
(ci_tmp=$(mktemp -d -p "$work") && source "$work/repo/ci/lib.sh" && ci_anthropic > /dev/null &&
  PLAN_SUMMARY=$work/summary "$work/repo/ci/tofu.sh" drift anthropic) > "$work/drift.txt" 2>&1
grep -q '^anthropic: check check.admin failed: The bootstrap rule matches other tokens' "$work/summary" &&
  ok "the drift lists the widened bootstrap rule" || fail "the drift: $(cat "$work/summary" "$work/drift.txt")"

[ "$failed" = 0 ] && echo "anthropic_plan_test: all passed" || { echo "anthropic_plan_test: failed"; exit 1; }
