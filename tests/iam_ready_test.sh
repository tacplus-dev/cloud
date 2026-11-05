#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the IAM readiness gate of a new project (#16): IAM reaches a project created seconds before only after a
# minute or two, so each project module's terraform_data.iam_ready, after the project and its APIs, waits until the
# pipeline holds the permissions its resources need there (ci/iam-ready.sh), and every other resource of the module
# comes after it: it depends on the gate, or on a resource that does (the project and its APIs alone come before).
# ci/iam-ready.sh, against a stub gcloud and curl (tests/stub/iam): it asks testIamPermissions of the project for
# exactly the permissions it is given, as the pipeline; it is ready only once every permission has been granted on
# IAM_READY_STREAK checks in a row, a missing one or a project not visible yet starting the count again; it gives up
# after IAM_READY_ATTEMPTS checks, naming what is missing, and at once on an answer that is no propagation (a
# malformed permission). Needs bash and jq.
#
#   tests/iam_ready_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/ci/iam-ready.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The wiring: in each project module, the gate after the APIs, and every other resource after the gate.
for m in "$here"/modules/projects/*/; do
  name=modules/projects/$(basename "$m")
  out=$(awk '
    /^resource "/ { type = $2; gsub(/"/, "", type); rname = $3; gsub(/"/, "", rname); key = type "." rname; body = ""; inside = 1; next }
    inside && /^}/ {
      inside = 0
      if (key == "terraform_data.iam_ready") { gate = 1; if (body !~ /depends_on *= *\[[^]]*google_project_service\.service/) print "the gate does not come after the APIs"; next }
      if (type == "google_project" || type == "google_project_service") next
      # Gated: it depends on the gate, or refers to another resource of the module (the project and its APIs aside),
      # which this same rule holds to.
      rest = body; gated = 0
      while (match(rest, /(google_[a-z0-9_]+|terraform_data)\.[a-z0-9_]+/)) {
        ref = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (ref ~ /^google_project\./ || ref ~ /^google_project_service\./) continue
        gated = 1
      }
      if (body ~ /depends_on *= *\[[^]]*google_project_service\.service/) print key " depends on the APIs, not on the gate"
      else if (!gated) print key " does not come after the gate"
      next
    }
    inside { body = body "\n" $0 }
    END { if (!gate) print "no terraform_data.iam_ready" }
  ' "$m"*.tf)
  [ -z "$out" ] && ok "$name: every resource comes after the IAM gate, the gate after the APIs" ||
    while IFS= read -r l; do fail "$name: $l"; done <<< "$out"
  grep -q '\${path.module}/../../../ci/iam-ready.sh' "$m/main.tf" && ok "$name: the gate runs ci/iam-ready.sh" ||
    fail "$name: the gate does not run ci/iam-ready.sh"
done

# The script, against the stubs.
export PATH=$here/tests/stub/iam:$PATH STUB_LOG=$work/log IAM_READY_INTERVAL=0
granted='200
{"permissions": ["iam.workloadIdentityPools.create", "container.clusters.create"]}'
partly='200
{"permissions": ["container.clusters.create"]}'
hidden='403
{"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "The caller does not have permission"}}'
malformed='400
{"error": {"code": 400, "status": "INVALID_ARGUMENT", "message": "Permission iam.nope is not valid."}}'
gate() { # gate ANSWER...: run the script, the stub answering each in turn (the last again once past it)
  export STUB_IAM=$work/answers-$RANDOM$RANDOM
  mkdir -p "$STUB_IAM" && : > "$STUB_LOG"
  local n=0 a
  for a in "$@"; do n=$((n + 1)); printf '%s\n' "$a" > "$STUB_IAM/$n"; done
  rc=0
  "$script" tacplus-dev iam.workloadIdentityPools.create container.clusters.create > "$work/out" 2>&1 || rc=$?
  checks=$(grep -c '^curl ' "$STUB_LOG")
}

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=10 gate "$granted"
[ "$rc" = 0 ] && [ "$checks" = 3 ] && ok "granted at once: ready after 3 checks in a row" || fail "granted at once: rc $rc, $checks checks: $(cat "$work/out")"
grep -qx 'curl https://cloudresourcemanager.googleapis.com/v3/projects/tacplus-dev:testIamPermissions' "$STUB_LOG" &&
  grep -qxF '{"permissions":["iam.workloadIdentityPools.create","container.clusters.create"]}' "$STUB_LOG" &&
  ok "it asks testIamPermissions of the project for exactly its permissions" || fail "the request: $(cat "$STUB_LOG")"

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=10 gate "$hidden" "$partly" "$partly" "$granted"
[ "$rc" = 0 ] && [ "$checks" = 6 ] && ok "not visible, then partly granted, then granted: ready after 6 checks" ||
  fail "propagating: rc $rc, $checks checks: $(cat "$work/out")"
grep -q 'iam.workloadIdentityPools.create' "$work/out" && grep -q '403' "$work/out" &&
  ok "while it waits it says what is missing" || fail "the waiting: $(cat "$work/out")"

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=10 gate "$granted" "$granted" "$partly" "$granted"
[ "$rc" = 0 ] && [ "$checks" = 6 ] && ok "a permission missing again starts the count again" || fail "a flap: rc $rc, $checks checks: $(cat "$work/out")"

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=4 gate "$partly"
[ "$rc" = 1 ] && [ "$checks" = 4 ] && grep -q 'iam.workloadIdentityPools.create' "$work/out" &&
  ok "never granted: it gives up after IAM_READY_ATTEMPTS checks, naming what is missing" || fail "never granted: rc $rc, $checks checks: $(cat "$work/out")"

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=4 gate "$granted" "$granted" "$partly"
[ "$rc" = 1 ] && [ "$checks" = 4 ] && ok "not granted 3 times in a row within its checks: it gives up" || fail "streak cut by the bound: rc $rc, $checks checks"

IAM_READY_STREAK=3 IAM_READY_ATTEMPTS=10 gate "$malformed"
[ "$rc" = 1 ] && [ "$checks" = 1 ] && grep -q 'INVALID_ARGUMENT' "$work/out" && ok "a malformed permission: it fails at once" ||
  fail "malformed: rc $rc, $checks checks: $(cat "$work/out")"

rc=0
"$script" tacplus-dev > "$work/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && ok "no permission: refused" || fail "no permission: rc $rc"

[ "$failed" = 0 ] && echo "iam-ready: all passed" || { echo "iam-ready: FAILED"; exit 1; }
