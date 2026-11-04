#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# What no change here may do, checked twice: in the source on every push (the validate job), and in each saved
# plan before it is applied (ci/tofu.sh plan). Refused:
#   - a service-account key (google_service_account_key): every identity is keyless;
#   - allUsers or allAuthenticatedUsers, in any binding, member list or policy document: nothing is public;
#   - in a plan only, the network rules of 2026-11-03 (tacplus-dev/roadmap decisions/network-exposure-2026-11-03.md and
#     cluster-node-pools-2026-11-03.md, #7): an instance or instance template with an external address (an
#     access_config or ipv6_access_config, or one known only after apply): only load balancers are public; a firewall
#     rule allowing ingress from the internet (0.0.0.0/0 or ::/0, or no source at all, which is 0.0.0.0/0): every load
#     balancer is proxy-based, so no exception; a firewall rule allowing port 22, in either direction (tcp or all, with
#     no ports, 22, or a range covering it): no SSH anywhere, not even IAP, the one exception being the runners' internal
#     rule, exactly as it is, until the runner VMs go (#11); a cluster without private nodes, a node pool with public
#     ones (one that does not say inherits the cluster's), or a node pool whose image is not COS_CONTAINERD;
#   - in the source only, what a commit does not fix, so that the same commit gives the same plan
#     (tacplus-dev/roadmap decisions/deterministic-deployments-2026-11-02.md): timestamp(), plantimestamp(),
#     uuid(), bcrypt(), an image at :latest, and a VM image's family (its newest image at each VM's creation).
#
#   ci/policy.sh source DIR...      # every *.tf and *.tftpl under each DIR
#   ci/policy.sh plan PLAN.json...  # `tofu show -json` of saved plans: what they create or update
set -uo pipefail
die() { echo "policy: $*" >&2; exit 2; }
refused=0
refuse() { echo "policy: refused: $*" >&2; refused=1; }

source_check() {
  local dir f n line
  local -A why=(
    ['\bgoogle_service_account_key\b']="creates a service-account key (google_service_account_key)"
    ['\ballUsers\b']="names allUsers: nothing is public"
    ['\ballAuthenticatedUsers\b']="names allAuthenticatedUsers: nothing is public"
    ['\b(timestamp|plantimestamp|uuid|bcrypt)\(']="calls a function whose value no commit fixes (timestamp(), plantimestamp(), uuid(), bcrypt())"
    [':latest\b']="names an image at :latest: pin it by digest"
    ['/images/family/']="boots an image family, whose newest image no commit fixes: pin the image by name"
  )
  for dir in "$@"; do
    [ -d "$dir" ] || die "no such directory: $dir"
    while IFS= read -r -d '' f; do
      for re in "${!why[@]}"; do
        while IFS=: read -r n line; do
          [ -n "$n" ] && refuse "$f:$n: ${why[$re]}: ${line#"${line%%[![:space:]]*}"}"
        done < <(grep -nE "$re" "$f" 2>/dev/null)
      done
    done < <(find "$dir" -type d -name .terraform -prune -o -type f \( -name '*.tf' -o -name '*.tftpl' \) -print0 | sort -z)
  done
}

plan_check() {
  local p out
  for p in "$@"; do
    jq -e '.resource_changes | type == "array"' "$p" >/dev/null 2>&1 || { refuse "$p is not a plan (tofu show -json of a saved plan)"; continue; }
    out=$(jq -r '
      # ssh: an allow block that admits tcp port 22.
      def ssh: (.protocol | ascii_downcase | IN("tcp", "6", "all"))
        and ((.ports // []) | length == 0 or any(.[]; split("-") | map(tonumber) | .[0] <= 22 and 22 <= .[-1]));
      # The runners'"'"' internal SSH rule (the manager to its workers, by network tag, nothing else), until #11 removes it.
      def runner_ssh: .name == "runner-manager-to-workers-ssh" and (.direction // "INGRESS") == "INGRESS"
        and (.source_ranges // []) == [] and .source_tags == ["runner-manager"] and .target_tags == ["runner-worker"]
        and .allow == [{protocol: "tcp", ports: ["22"]}];
      .resource_changes[]
      | select(.change.actions | any(. == "create" or . == "update"))
      | .address as $a | (.change.after // {}) as $after
      | [.change.after_unknown // {} | paths(. == true) | map(tostring) | join(".")] as $unknown
      | (select(.type == "google_service_account_key") | "\($a) creates a service-account key"),
        ($after | paths(strings) as $p | getpath($p) as $v
         | ["allUsers", "allAuthenticatedUsers"][] as $who | select($v | test("\\b" + $who + "\\b"))
         | "\($a) grants \($who) (\($p | map(tostring) | join(".")))"),
        (select(.type | IN("google_compute_instance", "google_compute_instance_template", "google_compute_region_instance_template"))
         | if any($unknown[]; test("^network_interface($|\\.[0-9]+($|\\.(ipv6_)?access_config))")) then
             "\($a): its access configs are known only after apply, so it may have an external address: only load balancers are public"
           elif any($after.network_interface[]?; (.access_config // []) + (.ipv6_access_config // []) | length > 0) then
             "\($a) has an external address (an access_config): only load balancers are public"
           else empty end),
        (select(.type == "google_compute_firewall")
         | if any($unknown[]; test("^(source_ranges|source_tags|source_service_accounts|allow)($|\\.)")) then
             "\($a): its sources or what it allows are known only after apply"
           else
             (select(($after.direction // "INGRESS") == "INGRESS" and ($after.allow // [] | length > 0))
              | select(any($after.source_ranges[]?; IN("0.0.0.0/0", "::/0"))
                  or ([$after.source_ranges, $after.source_tags, $after.source_service_accounts] | map(. // [] | length) | add == 0))
              | "\($a) allows ingress from the internet (0.0.0.0/0 or ::/0, or no source, which is 0.0.0.0/0): every load balancer is proxy-based"),
             (select(any($after.allow[]?; ssh) and ($after | runner_ssh | not))
              | "\($a) allows port 22 (SSH): no SSH anywhere, not even IAP")
           end),
        (select(.type == "google_container_cluster" and ($after.private_cluster_config[0].enable_private_nodes != true))
         | "\($a) has no private nodes (private_cluster_config.enable_private_nodes): nodes have no external address"),
        (select(.type == "google_container_node_pool")
         | (select($after.network_config[0].enable_private_nodes == false) | "\($a) has public nodes (network_config.enable_private_nodes)"),
           (select($after.node_config[0].image_type != "COS_CONTAINERD")
            | "\($a) does not run Container-Optimized OS (node_config.image_type is not COS_CONTAINERD)"))' "$p") ||
      { refuse "$p: cannot read its changes"; continue; }
    while IFS= read -r line; do [ -n "$line" ] && refuse "$p: $line"; done <<< "$out"
  done
}

mode=${1:-}
[ $# -ge 2 ] || die "usage: ci/policy.sh source DIR... | plan PLAN.json..."
shift
case $mode in
  source) source_check "$@" ;;
  plan) plan_check "$@" ;;
  *) die "usage: ci/policy.sh source DIR... | plan PLAN.json..." ;;
esac
[ "$refused" = 0 ] || exit 1
echo "policy: $mode: $# checked, nothing refused"
