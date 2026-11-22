#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/hub-audit.sh, the audit job's report (#77), against a stub gcloud and a stub Monitoring API over JSON
# fixtures (tests/stub/hub-audit, tests/fixtures/hub-audit): the report's shape, audit.json's sections and their fields,
# and audit.md's; what each says of the fixtures: the open ingress rules (a disabled one listed, not a finding), the VMs
# with an external IP, the external addresses and their users, the load balancers, every VM, the node pools with their
# nodes now, the disks by type, the network endpoint groups (#94: name, zone, size), the quotas asked for, with usage
# (one not listed is null), C4A's CPUs and Hyperdisk Balanced's GB from a stub Cloud Quotas (#88): the region's limit or
# the default, the project's preference and its state (every page read), the inventory's usage, its API not enabled
# noted; the hour's CPU and the ci namespace's containers' use against their requests (every page read), the secrets'
# names and version states; the spot nodes (#85), each with the pods on it, their requests and owner, against its
# allocatable, and the pods not scheduled, from a stub cluster API (tests/fixtures/hub-audit/kube), no pod's spec
# written out; the cluster autoscaler's events on the cluster's objects, from that API, read whatever autoscaler_log
# says; its log of the last 6 hours through the log view hub-audit-autoscaler alone (every page read): its no-scale-ups
# by pool, zone and reason, and its scale-up errors joined to the pools they tried, or, while AUDIT_AUTOSCALER_LOG is
# false (modules/settings autoscaler_log), none read and that noted; an API not enabled is noted, not an error. It exits
# 0 on projects with no exposure, and 1, both files written, on an ingress rule open to 0.0.0.0/0 or ::/0, a VM with an
# external IP, or a read it cannot make; it only lists and describes, and never reads a secret's value. The job's
# arguments: the region and the projects modules/settings names. Needs bash, jq and date.
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
export LOGGING_API=http://logging.stub STUB_LOGGING_API=http://logging.stub STUB_LOG_START=2026-11-23T06:00:00Z STUB_CA=stub-ca
export CLOUDQUOTAS_API=http://cloudquotas.stub STUB_CLOUDQUOTAS_API=http://cloudquotas.stub
export AUDIT_AUTOSCALER_LOG=true

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
is "audit.json's sections" 'keys' '["autoscaler","commit","errors","exposure","findings","generated","inventory","job","pipeline","projects","quotas","region","scheduling","secrets","unavailable","utilization"]'
is "the exposure's" '.exposure | keys' '["external_addresses","external_ips","load_balancers","open_ingress"]'
is "the inventory's" '.inventory | keys' '["disks","negs","node_pools","vms"]'
is "the utilization's" '.utilization | keys' '["containers","nodes","vms","window"]'
is "the scheduling's" '.scheduling | keys' '["pending_pods","spot_nodes"]'
is "the autoscaler's" '.autoscaler | keys' '["events","no_scale_up","read","scale_up_errors","window"]'
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
is "every VM, the cluster's nodes too" '.inventory.vms | length' 9
# The looper pool (#95) as GKE gives it: its total maximum, and no minimum (0, which the API leaves out).
is "the node pools: machine, spot, min and max (none when fixed), the nodes now" '.inventory.node_pools' \
  '[{"project":"audit-dev","cluster":"dev","location":"us-central1-a","name":"normal","machine_type":"c4a-standard-2","spot":false,"autoscaling":false,"min":null,"max":null,"nodes":3},{"project":"audit-dev","cluster":"dev","location":"us-central1-a","name":"spot","machine_type":"c4a-standard-4","spot":true,"autoscaling":true,"min":0,"max":3,"nodes":1},{"project":"audit-dev","cluster":"dev","location":"us-central1-a","name":"looper","machine_type":"c4a-standard-2","spot":false,"autoscaling":true,"min":0,"max":2,"nodes":0}]'
is "the disks by type, counted and summed" '.inventory.disks' \
  '[{"project":"audit-ci","type":"pd-balanced","count":2,"gb":174},{"project":"audit-ci","type":"pd-standard","count":1,"gb":350},{"project":"audit-dev","type":"hyperdisk-balanced","count":3,"gb":650},{"project":"audit-dev","type":"pd-balanced","count":1,"gb":100}]'

is "the network endpoint groups (#94): name, zone, size, type, the Service GKE made each for" '.inventory.negs' \
  '[{"project":"audit-dev","name":"seatrials-gateway","zone":"us-central1-a","size":1,"type":"GCE_VM_IP_PORT","service":"seatrials/gateway:8443"},{"project":"audit-dev","name":"seatrials-test-idp","zone":"us-central1-a","size":0,"type":"GCE_VM_IP_PORT","service":null}]'

# Quotas: those asked for, in order, with usage; one the region does not list is null. C4A's CPUs and Hyperdisk
# Balanced's GB (#88) from Cloud Quotas: the limit of the region's (and C4A's) dimensions, else the most specific one
# that applies (the default), with the project's preference for them (requested, granted, pending) or nulls, and the
# inventory's usage: the C4A VMs of the region's zones not stopped, their vCPUs by machine type, and the region's
# Hyperdisk Balanced disks, zonal and regional.
is "the quotas: CPUS_ALL_REGIONS and the region's CPUS, SSD, preemptible, T2A, C4A's and Hyperdisk Balanced's" \
  '[.quotas[] | select(.project == "audit-ci") | [.scope, .metric, .usage, .limit, .requested, .granted, .pending]]' \
  '[["global","CPUS_ALL_REGIONS",10,32,null,null,null],["us-central1","CPUS",10,24,null,null,null],["us-central1","SSD_TOTAL_GB",174,500,null,null,null],["us-central1","PREEMPTIBLE_CPUS",0,0,null,null,null],["us-central1","T2A_CPUS",8,24,null,null,null],["us-central1","CPUS_PER_VM_FAMILY (C4A)",0,24,null,null,null],["us-central1","HDB_TOTAL_GB",0,4000,null,null,null]]'
is "C4A's CPUs and Hyperdisk Balanced's GB: the region's limit, the inventory's usage, the preference asked for and its state" \
  '[.quotas[] | select(.project == "audit-dev" and (.metric | IN("CPUS_PER_VM_FAMILY (C4A)", "HDB_TOTAL_GB"))) | [.scope, .metric, .usage, .limit, .requested, .granted, .pending]]' \
  '[["us-central1","CPUS_PER_VM_FAMILY (C4A)",18,48,96,48,true],["us-central1","HDB_TOTAL_GB",150,2000,2000,2000,false]]'
is "every project's" '[.quotas[] | .project] | group_by(.) | map([.[0], length])' '[["audit-ci",7],["audit-dev",7]]'
grep -qx 'curl audit-dev quotaPreferences p2' "$STUB_LOG" && ok "the quota preferences' next page is read" || fail "the preferences' pages: $(grep quotaPreferences "$STUB_LOG")"

# Utilization.
is "CPU per VM, its maximum" '.utilization.vms' \
  '[{"project":"audit-ci","vm":"runner-manager-9c4d2d4d","zone":"us-central1-b","cpu_max":0.12},{"project":"audit-ci","vm":"runner-shared-abcd","zone":"us-central1-a","cpu_max":0.9731}]'
is "CPU per node" '.utilization.nodes' '[{"project":"audit-dev","cluster":"dev","node":"gke-dev-normal-1","cpu_max":0.4}]'
is "the ci namespace's containers: CPU and memory used against requested, every page read" '.utilization.containers' \
  '[{"project":"audit-dev","cluster":"dev","pod":"gitlab-runner-0","container":"runner","cpu_used_max":0.01,"cpu_requested":0.1,"memory_used_max":null,"memory_requested":null},{"project":"audit-dev","cluster":"dev","pod":"runner-job-1","container":"build","cpu_used_max":3.25,"cpu_requested":2,"memory_used_max":4294967296,"memory_requested":2147483648}]'
grep -qx 'curl audit-dev ctr-cpu ALIGN_RATE p2' "$STUB_LOG" && ok "Monitoring's next page is read" || fail "the second page was not read: $(grep curl "$STUB_LOG")"

# The spot nodes (#85): what fills each, the pods on it with their requests and owner (a GitLab job's by its URL), against
# its allocatable; a pod's requests are its containers' (or an init container's, if more) and none is 0. Not a normal
# node's.
is "each spot node: its pool, zone, allocatable and the sum of its pods' requests" \
  '[.scheduling.spot_nodes[] | [.project, .cluster, .pool, .node, .zone, .created, .cpu_allocatable, .memory_allocatable, .cpu_requested, .memory_requested, (.pods | length)]]' \
  '[["audit-dev","dev","spot","gke-dev-spot-1","us-central1-a","2026-11-20T18:52:00Z",3.92,13779193856,2.2,6786383872,2],["audit-dev","dev","spot","gke-dev-spot-2","us-central1-b","2026-11-23T09:35:00Z",3.92,13958643712,1.5,4000000000,2]]'
is "the pods on each spot node: phase, created, owner, requests" '[.scheduling.spot_nodes[].pods[]]' \
  '[{"namespace":"ci","name":"runner-abc-project-1-concurrent-0","phase":"Running","created":"2026-11-23T11:40:00Z","owner":"GitLab job https://gitlab.com/tacplus-dev/build/-/jobs/18234995653","cpu_requested":2.1,"memory_requested":6576668672},{"namespace":"kube-system","name":"fluentbit-gke-xyz","phase":"Running","created":"2026-11-20T18:53:00Z","owner":"DaemonSet/fluentbit-gke","cpu_requested":0.1,"memory_requested":209715200},{"namespace":"ci","name":"runner-def-project-1-concurrent-1","phase":"Running","created":"2026-11-23T09:40:00Z","owner":"GitLab job https://gitlab.com/tacplus-dev/build/-/jobs/18200000000","cpu_requested":1.5,"memory_requested":4000000000},{"namespace":"kube-system","name":"pdcsi-node-abc","phase":"Running","created":"2026-11-23T09:36:00Z","owner":"DaemonSet/pdcsi-node","cpu_requested":0,"memory_requested":0}]'
is "the pods not scheduled, and why" '.scheduling.pending_pods' \
  '[{"project":"audit-dev","cluster":"dev","namespace":"ci","name":"runner-pending-1","created":"2026-11-23T11:50:00Z","owner":"GitLab job https://gitlab.com/tacplus-dev/build/-/jobs/18235434424","cpu_requested":2,"memory_requested":6442450944,"why":"0/5 nodes are available: 2 Insufficient cpu, 2 Insufficient memory, 3 node(s) didn'"'"'t match Pod'"'"'s node affinity/selector."}]'
! grep -rq stub-secret-value "$work/out" "$work/stdout" "$work/err" && ok "no pod's spec is written out (an env value is not)" || fail "a pod's env is in the report"

# The cluster autoscaler (#85): its events on the cluster's objects, from the cluster's API, by when they were last seen
# (a new event's series and eventTime too), whatever autoscaler_log says.
events='[{"project":"audit-dev","cluster":"dev","object":"ConfigMap kube-system/cluster-autoscaler-status","reason":"ScaleDownEmpty","message":"Scale-down: removing empty node gke-dev-spot-3","count":1,"first":"2026-11-23T11:20:00Z","last":"2026-11-23T11:20:00Z"},{"project":"audit-dev","cluster":"dev","object":"Pod ci/runner-abc-project-1-concurrent-0","reason":"TriggeredScaleUp","message":"pod triggered scale-up: [{https://www.googleapis.com/compute/v1/projects/audit-dev/zones/us-central1-b/instanceGroups/gke-dev-spot-b-grp 1->2 (max: 5)}]","count":2,"first":"2026-11-23T11:40:10.000000Z","last":"2026-11-23T11:41:10.000000Z"},{"project":"audit-dev","cluster":"dev","object":"Pod ci/runner-pending-1","reason":"NotTriggerScaleUp","message":"pod didn'"'"'t trigger scale-up (it wouldn'"'"'t fit if a new node is added): 1 in backoff after failed scale-up, 1 node(s) didn'"'"'t match Pod'"'"'s node affinity/selector","count":19,"first":"2026-11-23T11:50:30Z","last":"2026-11-23T11:59:30Z"}]'
is "its events on the cluster's objects: object, reason, message, count, first and last" '.autoscaler.events' "$events"

# Its log: the last 6 hours, through the view hub-audit-autoscaler, every page.
is "the autoscaler's hours" '[.autoscaler.read, .autoscaler.window]' '[true,{"start":"2026-11-23T06:00:00Z","end":"2026-11-23T12:00:00Z"}]'
is "its no-scale-ups by pool, zone and reason (rejected, skipped, or none), counted, first and last, the pods it left" '.autoscaler.no_scale_up' \
  '[{"project":"audit-dev","pool":null,"zone":null,"reason":"no.scale.up.in.backoff","count":1,"first":"2026-11-23T10:00:00Z","last":"2026-11-23T10:00:00Z","pods":[]},{"project":"audit-dev","pool":"normal","zone":"us-central1-a","reason":"no.scale.up.mig.failing.predicate: NodeAffinity, node(s) didn'"'"'t match Pod'"'"'s node affinity/selector","count":1,"first":"2026-11-23T07:00:00.123Z","last":"2026-11-23T07:00:00.123Z","pods":["ci/runner-pending-1"]},{"project":"audit-dev","pool":"spot","zone":"us-central1-a","reason":"no.scale.up.mig.failing.predicate: NodeResourcesFit, Insufficient cpu","count":2,"first":"2026-11-23T07:00:00.123Z","last":"2026-11-23T10:00:00Z","pods":["ci/runner-pending-1","ci/runner-pending-2"]},{"project":"audit-dev","pool":"spot","zone":"us-central1-b","reason":"no.scale.up.mig.skipped: max node group size reached","count":1,"first":"2026-11-23T07:00:00.123Z","last":"2026-11-23T07:00:00.123Z","pods":[]}]'
is "its scale-up errors, each joined to the pools its decision tried (a scale-up that succeeded is not one)" '.autoscaler.scale_up_errors' \
  '[{"project":"audit-dev","time":"2026-11-23T09:31:00Z","event_id":"ev-1","error":"scale.up.error.out.of.resources: https://www.googleapis.com/compute/v1/projects/audit-dev/zones/us-central1-a/instanceGroups/gke-dev-spot-a-grp","pools":[{"pool":"spot","zone":"us-central1-a","requested":1}]}]'
grep -qx 'curl audit-dev autoscaler p2' "$STUB_LOG" && grep -qx 'curl audit-ci autoscaler first' "$STUB_LOG" &&
  ok "the log's next page is read, in each project" || fail "the autoscaler's pages: $(grep autoscaler "$STUB_LOG")"

# Secrets: names and version states, never a value.
is "the secrets: names and version states" '.secrets' \
  '[{"project":"audit-ci","name":"runner-token-shared","versions":[{"version":"2","state":"ENABLED"},{"version":"1","state":"DESTROYED"}]},{"project":"audit-ci","name":"gitlab-runner-control","versions":[]},{"project":"audit-dev","name":"gitlab-runner-infra","versions":[{"version":"1","state":"ENABLED"}]}]'
is "an API not enabled: noted, not an error" '.unavailable' '[{"project":"audit-ci","what":"clusters","why":"its API is not enabled"}]'

# The one read-only path: lists and describes, the token for Monitoring, and its timeSeries.list.
grep -vE '^curl [a-z-]+ autoscaler [a-z0-9]+$|^curl kube [0-9.]+ (nodes|pods|events)$|^gcloud (auth print-access-token|compute (firewall-rules|instances|addresses|forwarding-rules|network-endpoint-groups|disks) list --project=[a-z-]+ --format=json|container clusters list --project=[a-z-]+ --format=json|compute (project-info describe|regions describe us-central1) --project=[a-z-]+ --format=json|secrets list --project=[a-z-]+ --format=json|secrets versions list [a-z-]+ --project=[a-z-]+ --format=json)$|^curl [a-z-]+ [a-z-]+ ALIGN_(MAX|RATE) [a-z0-9]+$|^curl [a-z-]+ quotaInfos (CPUS-PER-VM-FAMILY|HDB-TOTAL-GB)-per-project-region$|^curl [a-z-]+ quotaPreferences [a-z0-9]+$' "$STUB_LOG" &&
  fail "the audit runs more than its reads" || ok "the audit only lists, describes and reads Monitoring, the autoscaler's view, Cloud Quotas and the cluster's nodes and pods: no secret's value"
[ "$(grep -c '^gcloud auth print-access-token$' "$STUB_LOG")" = 1 ] && ! grep -rq stub-token "$work/out" "$work/stdout" "$work/err" &&
  ok "one Monitoring token, never written out" || fail "the token: $(grep -c print-access-token "$STUB_LOG") reads, or in the report"

# audit.md: a section each, the findings first.
for h in "# Cloud audit, 2026-11-23T12:00:00Z" "No exposure finding." "## Exposure" "### Ingress open to 0.0.0.0/0" "### VMs with an external IP" \
  "### External addresses" "### Load balancers (forwarding rules)" "## Inventory" "### VMs" "### Node pools" "### Disks by type" "### Network endpoint groups" "## Quotas" \
  "## Utilization, 2026-11-23T11:00:00Z to 2026-11-23T12:00:00Z (the maximum of 10-minute windows)" "### CPU per VM" \
  "### CPU per node (of its allocatable)" "### Containers in namespace ci: used against requested" "## Scheduling" \
  "### Spot nodes: requested against allocatable" "### Pods on the spot nodes" "### Pods not scheduled" \
  "## Cluster autoscaler, 2026-11-23T06:00:00Z to 2026-11-23T12:00:00Z" \
  "### Its events on the cluster's objects (as Kubernetes keeps them, about an hour)" "### No scale-up, by pool, zone and reason" "### Scale-up errors" \
  "## Secrets (names and version states only)"; do
  grep -qxF -- "$h" "$work/out/audit.md" || fail "audit.md has no [$h]"
done
grep -qxF '| audit-dev | dev | spot | c4a-standard-4 | true | 0 | 3 | 1 |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | dev | normal | c4a-standard-2 | false | fixed | fixed | 3 |' "$work/out/audit.md" &&
  grep -qxF '| audit-ci | runner-shared-abcd | us-central1-a | 97.3% |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | dev | runner-job-1 | build | 3.25 | 2 | 4096 MiB | 2048 MiB |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | seatrials-gateway | us-central1-a | 1 | GCE_VM_IP_PORT | seatrials/gateway:8443 |' "$work/out/audit.md" &&
  grep -qxF '| audit-ci | runner-token-shared | 2 ENABLED, 1 DESTROYED |' "$work/out/audit.md" &&
  grep -qxF '| audit-ci | us-central1 | CPUS | 10.0 | 24.0 | - | - | - |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | us-central1 | CPUS_PER_VM_FAMILY (C4A) | 18 | 48 | 96 | 48 | true |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | dev | spot | gke-dev-spot-1 | us-central1-a | 2026-11-20T18:52:00Z | 2.2 of 3.92 | 6472 of 13141 MiB | 2 |' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | gke-dev-spot-1 | ci/runner-abc-project-1-concurrent-0 | Running | 2026-11-23T11:40:00Z | GitLab job https://gitlab.com/tacplus-dev/build/-/jobs/18234995653 | 2.1 | 6272 MiB |' "$work/out/audit.md" &&
  grep -qF '| audit-dev | dev | ci/runner-pending-1 | 2026-11-23T11:50:00Z | GitLab job https://gitlab.com/tacplus-dev/build/-/jobs/18235434424 | 2 | 6144 MiB | 0/5 nodes are available' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | spot | us-central1-a | no.scale.up.mig.failing.predicate: NodeResourcesFit, Insufficient cpu | 2 | 2026-11-23T07:00:00.123Z | 2026-11-23T10:00:00Z | ci/runner-pending-1, ci/runner-pending-2 |' "$work/out/audit.md" &&
  grep -qF '| audit-dev | dev | Pod ci/runner-pending-1 | NotTriggerScaleUp | 19 | 2026-11-23T11:50:30Z | 2026-11-23T11:59:30Z | pod didn'"'"'t trigger scale-up' "$work/out/audit.md" &&
  grep -qxF '| audit-dev | - | - | no.scale.up.in.backoff | 1 | 2026-11-23T10:00:00Z | 2026-11-23T10:00:00Z | - |' "$work/out/audit.md" &&
  grep -qF '| audit-dev | 2026-11-23T09:31:00Z | ev-1 | scale.up.error.out.of.resources: ' "$work/out/audit.md" && grep -qF '| spot us-central1-a +1 |' "$work/out/audit.md" &&
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
is "Cloud Quotas not enabled: noted, not an error, its limits unknown" '[.unavailable, [.quotas[] | select(.metric | IN("CPUS_PER_VM_FAMILY (C4A)", "HDB_TOTAL_GB")) | .limit], .errors]' \
  '[[{"project":"exposed","what":"the C4A CPU quota","why":"its API is not enabled"}],[null,null],[]]'

# A read it cannot make fails it too.
audit audit-ci missing
[ "$rc" = 1 ] && ok "a read it cannot make fails the audit" || fail "missing: exit $rc"
is "each read that failed is an error" '[.errors[] | select(.project == "missing") | .what]' \
  '["firewall rules","VMs","addresses","forwarding rules","network endpoint groups","disks","clusters","the project'"'"'s quotas","the quotas of us-central1","the C4A CPU quota","secrets","the VMs'"'"' CPU","the nodes'"'"' CPU","the containers'"'"' CPU","the containers'"'"' CPU requests","the containers'"'"' memory","the containers'"'"' memory requests","the cluster autoscaler'"'"'s log"]'
is "the other project is still reported" '[.inventory.vms[] | .project] | unique' '["audit-ci"]'

# Until the host grants the log views (modules/settings autoscaler_log false), the autoscaler is not read, and that is noted.
AUDIT_AUTOSCALER_LOG=false audit audit-ci audit-dev
[ "$rc" = 0 ] && ! grep -q autoscaler "$STUB_LOG" && ok "autoscaler_log false: its log is not read, and the audit passes" || fail "autoscaler_log false: exit $rc: $(grep autoscaler "$STUB_LOG")"
is "and the report says so; its events on the cluster are still read" '[.autoscaler.read, .autoscaler.no_scale_up, .autoscaler.scale_up_errors, [.unavailable[] | select(.what == "the cluster autoscaler'"'"'s log") | .project]]' \
  '[false,[],[],["audit-ci","audit-dev"]]'
is "its events on the cluster, read all the same" '.autoscaler.events' "$events"
grep -qF 'Its log not read: its log view waits on the host' "$work/out/audit.md" && ok "audit.md says why it is not read" || fail "audit.md: $(grep -A3 'Cluster autoscaler' "$work/out/audit.md")"
AUDIT_AUTOSCALER_LOG=yes "$here/ci/hub-audit.sh" "$work/x" us-central1 audit-ci > /dev/null 2> "$work/err"
[ "$?" = 2 ] && ok "AUDIT_AUTOSCALER_LOG neither true nor false: usage" || fail "AUDIT_AUTOSCALER_LOG=yes: $(cat "$work/err")"

"$here/ci/hub-audit.sh" "$work/x" us-central1 > /dev/null 2>&1 && fail "no project: passed" || ok "no project: usage"

# The job reports on the projects and the region modules/settings names.
# shellcheck source=ci/lib.sh
args=$(ci_tmp=$work && source "$here/ci/lib.sh" && echo "$(ci_region) $(ci_projects | tr '\n' ' ')")
[ "$args" = "us-central1 tacplus-ci tacplus-dev " ] && ok "ci_region and ci_projects: what modules/settings names" || fail "ci_region, ci_projects: [$args]"
exit "$failed"
