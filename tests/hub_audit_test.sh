#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/hub-audit.sh, the audit job's report (#77), against a stub gcloud and a stub Monitoring API over JSON
# fixtures (tests/stub/hub-audit, tests/fixtures/hub-audit): the report's shape, audit.json's sections and their
# fields, and audit.md's; what each says of the fixtures: the open ingress rules (a disabled one listed, not a
# finding), the VMs with an external IP, the external addresses and their users, the load balancers, every VM, the
# node pools with their nodes now, the disks by type, the quotas asked for, with usage (one not listed is null), the
# hour's CPU and the ci namespace's containers' use against their requests (every page read), the secrets' names and
# version states; an API not enabled is noted, not an error. It exits 0 on projects with no exposure, and 1, both
# files written, on an ingress rule open to 0.0.0.0/0 or ::/0, a VM with an external IP, or a read it cannot make; it
# only lists and describes, and never reads a secret's value. The job's arguments: the region and the projects
# modules/settings names. Needs bash, jq and date.
#
#   tests/hub_audit_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset CLOUD_COMMIT CI_PIPELINE_URL CI_JOB_URL
export STUB_AUDIT=$here/tests/fixtures/hub-audit STUB_LOG=$work/log PATH=$here/tests/stub/hub-audit:$PATH
export MONITORING_API=http://monitoring.stub STUB_API=http://monitoring.stub AUDIT_NOW=1795435200
export STUB_START=2026-11-23T11:00:00Z STUB_END=2026-11-23T12:00:00Z

audit() { # audit PROJECT...: the report of PROJECT... in $work/out, its exit status in $rc
  rm -rf "$work/out"
  : > "$STUB_LOG"
  CLOUD_COMMIT=0123456789abcdef0123456789abcdef01234567 "$here/ci/hub-audit.sh" "$work/out" us-central1 "$@" > "$work/stdout" 2> "$work/err"
  rc=$?
}
# j JQ: audit.json's JQ, compact, its numbers as jq computes them (jq 1.7 keeps a literal 10.0 as it is written).
j() { jq -c "$1"' | (.. | numbers) |= . + 0' "$work/out/audit.json"; }
is() { # is WHAT JQ WANT: audit.json's JQ is WANT (compact JSON)
  local got
  got=$(j "$2")
  [ "$got" = "$3" ] && ok "$1" || { fail "$1"; echo "     want $3"; echo "     got  $got"; }
}

audit audit-ci audit-dev
[ "$rc" = 0 ] && ok "projects with no exposure: the audit passes" || fail "the clean projects: exit $rc: $(cat "$work/err")"
[ -s "$work/out/audit.json" ] && [ -s "$work/out/audit.md" ] && ok "it writes audit.json and audit.md" || fail "no audit.json or audit.md"
cmp -s "$work/stdout" "$work/out/audit.md" && ok "the job's log shows audit.md" || fail "stdout is not audit.md"

# The shape: the hub reads these keys.
is "audit.json's sections" 'keys' '["commit","errors","exposure","findings","generated","inventory","job","pipeline","projects","quotas","region","secrets","unavailable","utilization"]'
is "the exposure's" '.exposure | keys' '["external_addresses","external_ips","load_balancers","open_ingress"]'
is "the inventory's" '.inventory | keys' '["disks","node_pools","vms"]'
is "the utilization's" '.utilization | keys' '["containers","nodes","vms","window"]'
is "what it reads, where and when" '[.projects, .region, .commit, .generated]' '[["audit-ci","audit-dev"],"us-central1","0123456789abcdef0123456789abcdef01234567","2026-11-23T12:00:00Z"]'
is "the hour, in 10-minute windows, their maximum" '.utilization.window' '{"start":"2026-11-23T11:00:00Z","end":"2026-11-23T12:00:00Z","alignment_seconds":600,"aggregation":"max"}'

# Exposure.
is "an open ingress rule, disabled: listed, not a finding (deny and egress rules, private and Google's ranges are not)" '.exposure.open_ingress' \
  '[{"project":"audit-dev","name":"hand-open-disabled","network":"dev","sources":["0.0.0.0/0"],"allowed":["tcp:80"],"target_tags":[],"disabled":true}]'
is "no finding, no error" '[.findings, .errors]' '[[],[]]'
is "no VM with an external IP" '.exposure.external_ips' '[]'
is "the external addresses and their users (an internal one is not)" '.exposure.external_addresses' \
  '[{"project":"audit-dev","name":"gateway","scope":"global","address":"34.1.2.3","status":"IN_USE","users":["forwardingRules/gateway"]}]'
is "the load balancers" '.exposure.load_balancers' \
  '[{"project":"audit-dev","name":"gateway","scope":"global","ip":"34.1.2.3","protocol":"TCP","ports":"443-443","scheme":"EXTERNAL_MANAGED","target":"targetTcpProxies/gateway"}]'

# Inventory.
is "every VM: name, type, provisioning, created" '[.inventory.vms[] | [.project, .name, .zone, .machine_type, .provisioning, .status, .created]] | .[0:2]' \
  '[["audit-ci","runner-manager-9c4d2d4d","us-central1-b","e2-small","STANDARD","RUNNING","2026-11-15T10:00:00.000-08:00"],["audit-ci","runner-shared-abcd","us-central1-a","t2a-standard-8","SPOT","RUNNING","2026-11-16T01:00:00.000-08:00"]]'
is "every VM, the cluster's nodes too" '.inventory.vms | length' 6
is "the node pools: machine, spot, min and max (none when fixed), the nodes now" '.inventory.node_pools' \
  '[{"project":"audit-dev","cluster":"dev","location":"us-central1-a","name":"normal","machine_type":"c4a-standard-2","spot":false,"autoscaling":false,"min":null,"max":null,"nodes":3},{"project":"audit-dev","cluster":"dev","location":"us-central1-a","name":"spot","machine_type":"c4a-standard-4","spot":true,"autoscaling":true,"min":0,"max":3,"nodes":1}]'
is "the disks by type, counted and summed" '.inventory.disks' \
  '[{"project":"audit-ci","type":"pd-balanced","count":2,"gb":174},{"project":"audit-ci","type":"pd-standard","count":1,"gb":350},{"project":"audit-dev","type":"hyperdisk-balanced","count":1,"gb":100},{"project":"audit-dev","type":"pd-balanced","count":1,"gb":100}]'

# Quotas: those asked for, in order, with usage; one the region does not list is null.
is "the quotas: CPUS_ALL_REGIONS and the region's CPUS, SSD, preemptible, T2A and C4A" '[.quotas[] | select(.project == "audit-ci") | [.scope, .metric, .usage, .limit]]' \
  '[["global","CPUS_ALL_REGIONS",10,32],["us-central1","CPUS",10,24],["us-central1","SSD_TOTAL_GB",174,500],["us-central1","PREEMPTIBLE_CPUS",0,0],["us-central1","T2A_CPUS",8,24],["us-central1","C4A_CPUS",null,null]]'
is "every project's" '[.quotas[] | .project] | group_by(.) | map([.[0], length])' '[["audit-ci",6],["audit-dev",6]]'

# Utilization.
is "CPU per VM, its maximum" '.utilization.vms' \
  '[{"project":"audit-ci","vm":"runner-manager-9c4d2d4d","zone":"us-central1-b","cpu_max":0.12},{"project":"audit-ci","vm":"runner-shared-abcd","zone":"us-central1-a","cpu_max":0.9731}]'
is "CPU per node" '.utilization.nodes' '[{"project":"audit-dev","cluster":"dev","node":"gke-dev-normal-1","cpu_max":0.4}]'
is "the ci namespace's containers: CPU and memory used against requested, every page read" '.utilization.containers' \
  '[{"project":"audit-dev","cluster":"dev","pod":"gitlab-runner-0","container":"runner","cpu_used_max":0.01,"cpu_requested":0.1,"memory_used_max":null,"memory_requested":null},{"project":"audit-dev","cluster":"dev","pod":"runner-job-1","container":"build","cpu_used_max":3.25,"cpu_requested":2,"memory_used_max":4294967296,"memory_requested":2147483648}]'
grep -qx 'curl audit-dev ctr-cpu ALIGN_RATE p2' "$STUB_LOG" && ok "Monitoring's next page is read" || fail "the second page was not read: $(grep curl "$STUB_LOG")"

# Secrets: names and version states, never a value.
is "the secrets: names and version states" '.secrets' \
  '[{"project":"audit-ci","name":"runner-token-shared","versions":[{"version":"2","state":"ENABLED"},{"version":"1","state":"DESTROYED"}]},{"project":"audit-ci","name":"gitlab-runner-control","versions":[]},{"project":"audit-dev","name":"gitlab-runner-infra","versions":[{"version":"1","state":"ENABLED"}]}]'
is "an API not enabled: noted, not an error" '.unavailable' '[{"project":"audit-ci","what":"clusters","why":"its API is not enabled"}]'

# The one read-only path: lists and describes, the token for Monitoring, and its timeSeries.list.
grep -vE '^gcloud (auth print-access-token|compute (firewall-rules|instances|addresses|forwarding-rules|disks) list --project=[a-z-]+ --format=json|container clusters list --project=[a-z-]+ --format=json|compute (project-info describe|regions describe us-central1) --project=[a-z-]+ --format=json|secrets list --project=[a-z-]+ --format=json|secrets versions list [a-z-]+ --project=[a-z-]+ --format=json)$|^curl [a-z-]+ [a-z-]+ ALIGN_(MAX|RATE) [a-z0-9]+$' "$STUB_LOG" &&
  fail "the audit runs more than its reads" || ok "the audit only lists, describes and reads Monitoring: no secret's value"
[ "$(grep -c '^gcloud auth print-access-token$' "$STUB_LOG")" = 1 ] && ! grep -rq stub-token "$work/out" "$work/stdout" "$work/err" &&
  ok "one Monitoring token, never written out" || fail "the token: $(grep -c print-access-token "$STUB_LOG") reads, or in the report"

# audit.md: a section each, the findings first.
for h in "# Cloud audit, 2026-11-23T12:00:00Z" "No exposure finding." "## Exposure" "### Ingress open to 0.0.0.0/0" "### VMs with an external IP" \
  "### External addresses" "### Load balancers (forwarding rules)" "## Inventory" "### VMs" "### Node pools" "### Disks by type" "## Quotas" \
  "## Utilization, 2026-11-23T11:00:00Z to 2026-11-23T12:00:00Z (the maximum of 10-minute windows)" "### CPU per VM" \
  "### CPU per node (of its allocatable)" "### Containers in namespace ci: used against requested" "## Secrets (names and version states only)"; do
  grep -qxF -- "$h" "$work/out/audit.md" || fail "audit.md has no [$h]"
done
grep -qxF '| audit-dev | dev | spot | c4a-standard-4 | true | 0 | 3 | 1 |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | dev | normal | c4a-standard-2 | false | fixed | fixed | 3 |' "$work/out/audit.md" &&
  grep -qxF '| audit-ci | runner-shared-abcd | us-central1-a | 97.3% |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | dev | runner-job-1 | build | 3.25 | 2 | 4096 MiB | 2048 MiB |' "$work/out/audit.md" &&
  grep -qxF '| audit-ci | runner-token-shared | 2 ENABLED, 1 DESTROYED |' "$work/out/audit.md" &&
  ok "audit.md: its sections and tables" || fail "audit.md: $(cat "$work/out/audit.md")"

# Exposure fails the job, the report written.
audit exposed
[ "$rc" = 1 ] && [ -s "$work/out/audit.json" ] && [ -s "$work/out/audit.md" ] && ok "an exposure finding fails the audit, its report written" || fail "exposed: exit $rc, $(ls "$work/out" 2>&1)"
is "the findings: ingress open to 0.0.0.0/0 and ::/0, a VM's external IP" '.findings' \
  '["exposed: firewall rule hand-https allows ingress from 0.0.0.0/0 (tcp:443)","exposed: firewall rule hand-v6 allows ingress from ::/0 (all)","exposed: VM hand-vm has an external IP (35.9.9.9)"]'
is "the VM's external IP, and its address's user" '[.exposure.external_ips, .exposure.external_addresses[0].users, .inventory.vms[0].provisioning]' \
  '[[{"project":"exposed","vm":"hand-vm","zone":"us-central1-c","ips":["35.9.9.9"]}],["instances/hand-vm"],"PREEMPTIBLE"]'
grep -qF -- '- exposed: VM hand-vm has an external IP (35.9.9.9)' "$work/out/audit.md" && grep -q 'exposure finding' "$work/err" &&
  ok "audit.md lists the findings, and the log says why it fails" || fail "exposed: $(cat "$work/err")"

# A read it cannot make fails it too.
audit audit-ci missing
[ "$rc" = 1 ] && ok "a read it cannot make fails the audit" || fail "missing: exit $rc"
is "each read that failed is an error" '[.errors[] | select(.project == "missing") | .what]' \
  '["firewall rules","VMs","addresses","forwarding rules","disks","clusters","the project'"'"'s quotas","the quotas of us-central1","secrets","the VMs'"'"' CPU","the nodes'"'"' CPU","the containers'"'"' CPU","the containers'"'"' CPU requests","the containers'"'"' memory","the containers'"'"' memory requests"]'
is "the other project is still reported" '[.inventory.vms[] | .project] | unique' '["audit-ci"]'

"$here/ci/hub-audit.sh" "$work/x" us-central1 > /dev/null 2>&1 && fail "no project: passed" || ok "no project: usage"

# The job reports on the projects and the region modules/settings names.
# shellcheck source=ci/lib.sh
args=$(ci_tmp=$work && source "$here/ci/lib.sh" && echo "$(ci_region) $(ci_projects | tr '\n' ' ')")
[ "$args" = "us-central1 tacplus-ci tacplus-dev " ] && ok "ci_region and ci_projects: what modules/settings names" || fail "ci_region, ci_projects: [$args]"
exit "$failed"
