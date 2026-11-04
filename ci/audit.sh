#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The drift job's live audit (#7): what each project holds, made by a stack or by hand, against the network rules of
# 2026-11-03 that ci/policy.sh refuses in a plan. A drift plan sees only what a stack has in its state; a firewall
# rule, a VM or a node pool made by hand is in none, so this lists them all (firewall rules, instances, instance
# templates, clusters and their node pools), gives them the shape of a plan's changes, and runs the same checks
# (ci/policy.sh plan) on them. One line per finding, "live <project>: ...", on stdout; a list it cannot read is a
# finding too. It only lists, and exits 0 when it finds something: ci/drift.sh files what it prints.
#
# GKE's own firewall rules (gke-*, from the network's private ranges only: its nodes, its pods, its control plane)
# open every port, 22 among them, inside the network; they are GKE's, not a stack's, so their port 22 is not
# reported. Anything else they allow is, as is a gke-* rule from outside those ranges.
#
#   ci/audit.sh PROJECT...    # needs gcloud (signed in: ci/lib.sh ci_gcp) and jq
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: ci/audit.sh PROJECT..." >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for project in "$@"; do
  for what in "compute firewall-rules" "compute instances" "compute instance-templates" "container clusters"; do
    read -ra cmd <<< "$what"
    if ! gcloud "${cmd[@]}" list --project="$project" --format=json > "$tmp/${cmd[1]}.json" 2> "$tmp/err"; then
      echo "live $project: cannot list ${cmd[1]}: $(grep -m1 '^ERROR' "$tmp/err" || head -c 300 "$tmp/err" | tr '\n' ' ')"
      echo '[]' > "$tmp/${cmd[1]}.json"
    fi
  done
  args=(--arg p "$project" --slurpfile fw "$tmp/firewall-rules.json" --slurpfile vm "$tmp/instances.json"
        --slurpfile tpl "$tmp/instance-templates.json" --slurpfile gke "$tmp/clusters.json")
  jq -n "${args[@]}" '
    def rc($type; $what; $after): {address: "live \($p): \($what)", type: $type, change: {actions: ["create"], after: $after}};
    def nics: [.[]? | {access_config: (.accessConfigs // []), ipv6_access_config: (.ipv6AccessConfigs // [])}];
    {format_version: "1.2", resource_changes: [
      (($fw[0] // [])[] | rc("google_compute_firewall"; "firewall rule \(.name)"; {name, direction,
        source_ranges: .sourceRanges, source_tags: .sourceTags, source_service_accounts: .sourceServiceAccounts,
        target_tags: .targetTags, allow: [.allowed[]? | {protocol: .IPProtocol} + (if .ports then {ports} else {} end)]})),
      (($vm[0] // [])[] | rc("google_compute_instance"; "instance \(.name)"; {network_interface: (.networkInterfaces | nics)})),
      (($tpl[0] // [])[] | rc(if .region then "google_compute_region_instance_template" else "google_compute_instance_template" end;
        "instance template \(.name)"; {network_interface: (.properties.networkInterfaces | nics)})),
      (($gke[0] // [])[] | .name as $c
       | rc("google_container_cluster"; "cluster \($c)"; {private_cluster_config: [{enable_private_nodes:
           (.privateClusterConfig.enablePrivateNodes // .networkConfig.defaultEnablePrivateNodes // false)}]}),
         (.nodePools[]? | rc("google_container_node_pool"; "node pool \($c)/\(.name)";
           {network_config: [{enable_private_nodes: .networkConfig.enablePrivateNodes}], node_config: [{image_type: .config.imageType}]})))
    ]}' > "$tmp/live.json" 2> "$tmp/err" &&
  jq -nr "${args[@]}" '($fw[0] // [])[]
    | select((.name | test("^gke-")) and (.sourceRanges | length > 0)
        and all(.sourceRanges[]; test("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)")))
    | "live \($p): firewall rule \(.name) allows port 22"' > "$tmp/exempt" 2>> "$tmp/err" ||
    { echo "live $project: cannot read its lists: $(head -c 300 "$tmp/err" | tr '\n' ' ')"; continue; }
  "$here/policy.sh" plan "$tmp/live.json" > /dev/null 2> "$tmp/refused"
  sed -n "s|^policy: refused: $tmp/live.json: ||p" "$tmp/refused" | grep -vF -f "$tmp/exempt"
done
exit 0
