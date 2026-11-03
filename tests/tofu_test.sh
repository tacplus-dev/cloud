#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/tofu.sh against a stub tofu (tests/stub/tofu): plan inits with the lock file read-only, saves the plan
# and its JSON, text and SHA-256, and is refused, with no SHA-256 to apply, when ci/policy.sh refuses the plan;
# apply applies exactly the saved plan (no other argument that could change it), and refuses a missing plan or one
# changed since the plan job; drift never saves, locks or applies, and lists what differs; an unknown stack is
# refused. Needs bash, jq, sha256sum.
#
#   tests/tofu_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export PATH=$here/tests/stub:$PATH STUB_LOG=$work/log PLANS=$work/plans
# ci/tofu.sh puts its repository's bin/ first in PATH: it runs from a copy of ci/ and stacks/ whose bin/ holds
# only the stub.
mkdir -p "$work/bin" "$work/repo" && ln -s "$here/tests/stub/tofu" "$work/bin/tofu"
cp -r "$here/ci" "$here/stacks" "$work/repo/" && ln -s "$work/bin" "$work/repo/bin"
find "$work/repo/stacks" -name .terraform -prune -exec rm -rf {} +
tofu_sh=$work/repo/ci/tofu.sh
run() { : > "$STUB_LOG"; "$tofu_sh" "$@" > "$work/out" 2>&1; }

clean='{"resource_changes":[{"address":"module.org.google_folder.folder[\"ci\"]","type":"google_folder","change":{"actions":["create"],"after":{"display_name":"ci"}}},{"address":"data.x","type":"x","change":{"actions":["read"],"after":{}}}]}'
key='{"resource_changes":[{"address":"google_service_account_key.k","type":"google_service_account_key","change":{"actions":["create"],"after":{}}}]}'
echo "$clean" > "$work/clean.json"; echo "$key" > "$work/key.json"

export STUB_PLAN_JSON=$work/clean.json
if run plan org; then ok "plan org"; else fail "plan org: $(cat "$work/out")"; fi
for f in org.tfplan org.json org.txt org.tfplan.sha256; do [ -s "$PLANS/$f" ] || fail "plan saved no plans/$f"; done
grep -q '^org init .*-lockfile=readonly' "$STUB_LOG" && ok "init reads the lock file only" || fail "init: $(grep init "$STUB_LOG")"
grep -q "^org plan .*-out=$PLANS/org.tfplan" "$STUB_LOG" && ok "the plan is saved" || fail "plan: $(grep plan "$STUB_LOG")"
grep -q '1 change(s)' "$work/out" && ok "the plan's changes are counted (reads are not changes)" || fail "the count: $(tail -1 "$work/out")"

if run apply org; then ok "apply org"; else fail "apply org: $(cat "$work/out")"; fi
[ "$(grep ' apply ' "$STUB_LOG")" = "org apply -input=false -lock-timeout=10m -no-color $PLANS/org.tfplan" ] &&
  ok "apply applies the saved plan, and only it" || fail "apply ran: $(grep apply "$STUB_LOG")"

echo "changed" >> "$PLANS/org.tfplan"
if run apply org; then fail "apply of a changed plan ran"; else
  grep -q 'not the plan the plan job saved' "$work/out" && ok "a plan changed since the plan job is refused" || fail "refused why: $(cat "$work/out")"; fi
grep -q ' apply ' "$STUB_LOG" && fail "tofu apply ran on a changed plan"
if run apply ci; then fail "apply without a plan ran"; else
  grep -q 'no saved plan' "$work/out" && ok "apply without a saved plan is refused" || fail "refused why: $(cat "$work/out")"; fi

export STUB_PLAN_JSON=$work/key.json
rm -f "$PLANS"/dev.*
if run plan dev; then fail "a plan creating a key passed"; else
  grep -q 'is refused (ci/policy.sh)' "$work/out" && ok "a plan ci/policy.sh refuses fails" || fail "refused why: $(cat "$work/out")"; fi
[ -e "$PLANS/dev.tfplan.sha256" ] && fail "a refused plan has a SHA-256: apply would run it" || ok "a refused plan cannot be applied"

export STUB_PLAN_JSON=$work/clean.json PLAN_SUMMARY=$work/summary
: > "$PLAN_SUMMARY"
STUB_PLAN_RC=0 run drift org && [ ! -s "$PLAN_SUMMARY" ] && ok "drift: none" || fail "drift with no change: $(cat "$work/out" "$PLAN_SUMMARY")"
STUB_PLAN_RC=2 run drift org && [ "$(cat "$PLAN_SUMMARY")" = 'org: create module.org.google_folder.folder["ci"]' ] &&
  ok "drift lists what differs" || fail "drift summary: $(cat "$PLAN_SUMMARY")"
grep -q ' plan .*-lock=false .*-detailed-exitcode' "$STUB_LOG" && ! grep -q ' apply ' "$STUB_LOG" && ! grep -q "out=$PLANS" "$STUB_LOG" &&
  ok "drift neither locks, saves nor applies" || fail "drift ran: $(cat "$STUB_LOG")"
: > "$PLAN_SUMMARY"
STUB_PLAN_RC=1 run drift ci && grep -q '^ci: the plan failed' "$PLAN_SUMMARY" && ok "a failed drift plan is reported" || fail "drift failure: $(cat "$PLAN_SUMMARY")"

run plan ../org && fail "a stack outside stacks/ ran" || ok "an unknown stack is refused"
run destroy org && fail "destroy ran" || ok "no other command (destroy) exists"
exit "$failed"
