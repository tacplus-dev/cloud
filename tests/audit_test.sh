#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/audit.sh, the drift job's live audit (#7), against a stub gcloud over JSON fixtures (tests/stub/live,
# tests/fixtures/live): in what the projects hold, made by a stack or by hand, it reports an instance or template with
# an external address, an allow rule open to the internet, a rule allowing port 22 (the runners' internal rule and
# GKE's own internal rules excepted), a cluster without private nodes and a pool with public nodes or not on COS,
# each once, saying the project; an external address but the global address gateway (#13); ingress from a public range
# but Google's proxies' and health checkers' (#21); it reports a list it cannot read; it reports nothing in projects that keep the rules;
# it only lists. The drift job audits the projects modules/settings names. Needs bash and jq.
#
#   tests/audit_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_LIVE=$here/tests/fixtures/live STUB_LOG=$work/log PATH=$here/tests/stub/live:$PATH

audit() { : > "$STUB_LOG"; "$here/ci/audit.sh" "$@" > "$work/out" 2> "$work/err"; }
reports() { # reports WHAT EXPECTED-LINE-PART...: each part is in exactly one line of the report
  local what=$1 part n; shift
  for part in "$@"; do
    n=$(grep -cF -- "$part" "$work/out")
    [ "$n" = 1 ] || { fail "$what: [$part] in $n lines of: $(cat "$work/out" "$work/err")"; return; }
  done
  ok "$what"
}

audit dirty-ci dirty-dev && ok "the audit exits 0 when it finds something (drift reports, it does not fail)" ||
  fail "the audit failed: $(cat "$work/err")"
reports "an instance with an external address" "live dirty-ci: instance runner-manager has an external address"
reports "a template with an external address" "live dirty-ci: instance template hand-template has an external address"
reports "SSH from IAP" "live dirty-ci: firewall rule hand-iap-ssh allows port 22"
reports "ingress from the internet" "live dirty-ci: firewall rule hand-https allows ingress from the internet"
reports "a passthrough load balancer's rule" "live dirty-dev: firewall rule k8s-fw-a1b2c3 allows ingress from the internet"
reports "GKE's SSH rule from outside the network" "live dirty-dev: firewall rule gke-dev-1a2b3c4d-ssh allows port 22"
reports "a pool with public nodes" "live dirty-dev: node pool dev/hand has public nodes"
reports "a pool not on COS" "live dirty-dev: node pool dev/hand does not run Container-Optimized OS"
reports "a cluster without private nodes" "live dirty-dev: cluster hand-public has no private nodes"
reports "a second global external address" "live dirty-dev: global address hand-global is an external address"
reports "a regional external address" "live dirty-dev: address hand-lb is an external address (a regional one)"
reports "ingress from IAP's range" "live dirty-ci: firewall rule hand-iap-ssh allows ingress from 35.235.240.0/20, a public range"
reports "ingress from a public address" "live dirty-dev: firewall rule gke-dev-1a2b3c4d-ssh allows ingress from 34.9.9.9/32, a public range"
[ "$(wc -l < "$work/out")" = 13 ] && ok "nothing else is reported (the runners' rule, GKE's internal rules, a deny rule, a proxy LB's rule from Google's ranges, clean VMs and pools, the gateway's address)" ||
  fail "the report is not those 13 lines: $(cat "$work/out")"
grep -vE '^gcloud (compute (firewall-rules|instances|instance-templates|addresses)|container clusters) list --project=[a-z-]+ --format=json$' "$STUB_LOG" &&
  fail "the audit runs more than the lists" || ok "the audit only lists"

audit clean && [ ! -s "$work/out" ] && ok "projects that keep the rules: nothing reported" || fail "clean: $(cat "$work/out" "$work/err")"
audit missing && reports "a list it cannot read is reported" "live missing: cannot list firewall-rules: " "live missing: cannot list clusters: " "live missing: cannot list addresses: "
"$here/ci/audit.sh" > /dev/null 2>&1 && fail "no project: passed" || ok "no project: usage"

# The drift job audits what modules/settings names, after its plans.
# shellcheck source=ci/lib.sh
projects=$(ci_tmp=$work && source "$here/ci/lib.sh" && ci_projects | tr '\n' ' ')
[ "$projects" = "tacplus-ci tacplus-dev " ] && ok "ci_projects: the projects modules/settings names" || fail "ci_projects: [$projects]"
grep -qF '"$here/audit.sh" $(ci_projects)' "$here/ci/drift.sh" && ok "drift runs the audit on them" || fail "ci/drift.sh does not run ci/audit.sh on ci_projects"
exit "$failed"
