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
#   - the one public IP (decisions/network-exposure-2026-11-03.md, #13): in a plan, an external address but the one
#     global address `gateway` (the dev stack's), a regional external address, or an external forwarding rule but the
#     TCP proxy's on it; in the source, a global address without prevent_destroy, so that no apply destroys it and its
#     IP with it;
#   - we terminate TLS, not the cloud (the decision's addendum, #21): in a plan, the one external forwarding rule is
#     global, EXTERNAL_MANAGED and TCP, on the address gateway, to a target TCP proxy (the global external proxy Network
#     Load Balancer, passing TLS through unopened); a certificate (Compute's or Certificate Manager's), an SSL policy,
#     an HTTP, HTTPS or SSL proxy or a URL map, global or regional, is refused; and an ingress allow rule from a public
#     range is refused unless it is within Google's proxies' and health checkers' (35.191.0.0/16, 130.211.0.0/22): the
#     nodes admit nothing else from outside the private ranges;
#   - in a plan, roles/owner or roles/container.admin to a service account (#18), in a member, a member list or a
#     policy document, or to a member known only after apply, but the pipeline's own owner of its folders: either could
#     delete the cluster, and cluster-admin inside it is a ClusterRoleBinding, not IAM;
#   - in a plan, the Anthropic organization (#34): an identity adopted (imported) with a change, as a live deployment
#     names it and its config was written from what the Console holds (a change is a commit of its own, after); a
#     federation rule whose scope is not workspace:developer or workspace:inference, or a service account whose
#     organization role is not developer: the one org:admin rule and admin account are the bootstrap, made by hand;
#   - the runner manager (#46, #48): in the source, its instance without create_before_destroy or destroy = false;
#     in a plan, a VM tagged runner-manager destroyed, first or after its replacement: destroyed first, the fleet would
#     have no manager and every runner would go offline; destroyed at all, its running jobs would die with it (an
#     old manager retires by itself, its jobs finished: modules/projects/ci/files/manager-startup.sh);
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
# The pipeline's own identity (modules/settings, bootstrap.pipeline_sa): owner of the folders it creates, the one
# service account that holds roles/owner.
pipeline_sa=cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com

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
      # A global address's block, to its closing brace at the start of a line, says prevent_destroy = true.
      while IFS= read -r line; do
        [ -n "$line" ] && refuse "$f:$line has no prevent_destroy: a public address outlives every apply"
      done < <(awk '/^resource "google_compute_global_address" "/ { n = FNR; a = $3; gsub(/"/, "", a); p = 0 }
        n && /^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true/ { p = 1 }
        n && /^}/ { if (!p) print n ": google_compute_global_address." a; n = 0 }' "$f")
      # The runner manager's instance says create_before_destroy = true (#46): a replacement never leaves the fleet
      # without a manager; and destroy = false (#48): no apply deletes one, and its jobs with it.
      while IFS= read -r line; do
        [ -n "$line" ] && refuse "$f:$line"
      done < <(awk '/^resource "google_compute_instance" "manager"/ { n = FNR; p = 0; d = 0 }
        n && /^[[:space:]]*create_before_destroy[[:space:]]*=[[:space:]]*true/ { p = 1 }
        n && /^[[:space:]]*destroy[[:space:]]*=[[:space:]]*false/ { d = 1 }
        n && /^}/ {
          if (!p) print n ": google_compute_instance.manager is not create_before_destroy: its replacement would leave the fleet with no runner manager"
          if (!d) print n ": google_compute_instance.manager is not destroy = false: an apply would delete the old manager, and its running jobs with it"
          n = 0 }' "$f")
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
      # A public range: not within the private ranges, nor within Google'"'"'s proxies'"'"' and health checkers'"'"', the only
      # sources outside the network a node admits (#21). Any IPv6 range is public here.
      def ip4: capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)\\.(?<d>[0-9]+)(/(?<n>[0-9]+))?$")
        | {ip: ((.a | tonumber) * 16777216 + (.b | tonumber) * 65536 + (.c | tonumber) * 256 + (.d | tonumber)), n: ((.n // "32") | tonumber)};
      def within($net): (ip4 // null) as $r | ($net | ip4) as $m
        | $r != null and $r.n >= $m.n and (($r.ip / pow(2; 32 - $m.n)) | floor) == (($m.ip / pow(2; 32 - $m.n)) | floor);
      def public: . as $s | all("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "35.191.0.0/16", "130.211.0.0/22"; . as $net | $s | within($net) | not);
      . as $plan
      # What an attribute known only after apply refers to, in the configuration of the resource'"'"'s module.
      | def refs($rc; $attr): [$rc.module_address // "" | scan("module\\.([^.\\[]+)") | .[0]] as $mods
          | (reduce $mods[] as $m ($plan.configuration.root_module // {}; .module_calls[$m].module // {}))
          | [.resources[]? | select(.type == $rc.type and .name == $rc.name) | .expressions[$attr].references[]?];
      # The IP of the address gateway, where the plan knows it (a forwarding rule in the state holds the IP, not the name).
      [.resource_changes[] | select(.type == "google_compute_global_address" and .change.after.name? == "gateway")
       | .change.after.address // empty] as $gateway_ips
      # The one external forwarding rule: the global external proxy Network Load Balancer'"'"'s, a TCP proxy on gateway.
      | def tcp_proxy_on_gateway($rc; $after; $unknown):
          $rc.type == "google_compute_global_forwarding_rule" and $after.load_balancing_scheme == "EXTERNAL_MANAGED"
          and $after.ip_protocol == "TCP"
          and (if any($unknown[]; . == "target") then any(refs($rc; "target")[]; startswith("google_compute_target_tcp_proxy."))
               else ($after.target // "" | test("/targetTcpProxies/[^/]+$")) end)
          and (if any($unknown[]; . == "ip_address") then any(refs($rc; "ip_address")[]; startswith("google_compute_global_address.gateway"))
               else ($after.ip_address // "") as $ip | ($ip | test("(^|/)global/addresses/gateway$")) or any($gateway_ips[]; . == $ip) end);
      .resource_changes[]
      # The runner manager (a VM tagged runner-manager) replaced destroy-first: the fleet would have none (#46); or
      # destroyed at all, a deposed one too: its running jobs would die with it (#48: destroy = false, it retires).
      | (select(.type == "google_compute_instance" and any(.change.before.tags[]?; . == "runner-manager"))
         | select(.change.actions | any(. == "delete"))
         | if .change.actions == ["delete", "create"] then
             "\(.address) destroys the runner manager before its replacement exists: every runner would go offline (create_before_destroy)"
           else
             "\(.address)\(if .deposed then " (deposed \(.deposed))" else "" end) destroys a runner manager: its running jobs would die with it (destroy = false: it retires by itself, its jobs done)"
           end),
      (select(.change.actions | any(. == "create" or . == "update"))
      | . as $rc | .address as $a | (.change.after // {}) as $after
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
             (select(($after.direction // "INGRESS") == "INGRESS" and ($after.allow // [] | length > 0))
              | $after.source_ranges[]? | select(IN("0.0.0.0/0", "::/0") | not) | select(public)
              | "\($a) allows ingress from \(.), a public range: the nodes admit only Google'"'"'s proxies and health checkers (35.191.0.0/16, 130.211.0.0/22) from outside the network"),
             (select(any($after.allow[]?; ssh) and ($after | runner_ssh | not))
              | "\($a) allows port 22 (SSH): no SSH anywhere, not even IAP")
           end),
        (select(.type == "google_compute_address" and ($after.address_type // "EXTERNAL") == "EXTERNAL")
         | "\($a) is an external address (a regional one): the only public IP is the global address gateway"),
        (select(.type == "google_compute_global_address" and ($after.address_type // "EXTERNAL") == "EXTERNAL" and $after.name != "gateway")
         | "\($a) is an external address: the only public IP is the global address gateway"),
        (select(.type | IN("google_compute_forwarding_rule", "google_compute_global_forwarding_rule"))
         | select(($after.load_balancing_scheme // "EXTERNAL") | IN("EXTERNAL", "EXTERNAL_MANAGED"))
         | select(tcp_proxy_on_gateway($rc; $after; $unknown) | not)
         | "\($a) is an external forwarding rule but a TCP proxy'"'"'s (global, EXTERNAL_MANAGED, TCP) on the global address gateway: the one way in"),
        (select(.type | test("^google_certificate_manager_|^google_compute_(region_)?(ssl_certificate|managed_ssl_certificate|ssl_policy|target_https?_proxy|target_ssl_proxy|url_map)$"))
         | "\($a) is a \(.type): we terminate TLS, not the cloud (no certificate, SSL policy, HTTP(S) or SSL proxy or URL map on Google'"'"'s side)"),
        (select(.type | test("^google_[a-z0-9_]+_iam_(member|binding|policy)$"))
         | (if .type | endswith("_iam_policy") then
              ($after.policy_data // "{}" | fromjson? // {} | .bindings[]? | {role, members: (.members // [])})
            else {role: $after.role, members: ([$after.member // empty] + ($after.members // []))} end)
         | select(.role | IN("roles/owner", "roles/container.admin")) as $b
         | if any($unknown[]; test("^(member|members|policy_data)($|\\.)")) then
             "\($a) grants \($b.role) to a member known only after apply: no service account holds it but the pipeline itself"
           else
             ($b.members[] | select(startswith("serviceAccount:") and . != $pipeline)
              | "\($a) grants \($b.role) to \(.): no service account holds it but the pipeline itself (it could delete the cluster)")
           end),
        (select(.type == "google_container_cluster" and ($after.private_cluster_config[0].enable_private_nodes != true))
         | "\($a) has no private nodes (private_cluster_config.enable_private_nodes): nodes have no external address"),
        (select(.type | startswith("anthropic_")) | select(.change.importing != null)
         # What differs, the value in the Console (before) then in the config (after), as the text of the plan is printed
         # only once the policy passes: not what is known only after apply (its timestamps, or a list the provider
         # computes, as the workspace_ids of a rule: nor its elements), nor a sensitive value.
         | (.change.before // {}) as $b | (.change.before_sensitive // {}) as $bs | (.change.after_sensitive // {}) as $as
         | ([[($b, $after) | paths(type != "object" and type != "array")] | unique[] as $q
             | ($q | map(tostring) | join(".")) as $k
             | select(any(range(1; ($q | length) + 1) as $n | $q[:$n] | map(tostring) | join("."); IN($unknown[])) | not)
             | select(($b | getpath($q)) != ($after | getpath($q)))
             | if any(range(1; ($q | length) + 1) as $n | ($bs, $as) | try getpath($q[:$n]) catch null; . == true) then "\($k): sensitive"
               else "\($k): \($b | getpath($q) | tojson) in the Console, \($after | getpath($q) | tojson) here" end]
            | if length > 0 then " (\(join("; ")))" else "" end) as $what
         | "\($a) is adopted with a change\($what): an adoption plans none, as its deployment names the identity live; write the config as the Console holds it, and change it in a commit of its own after"),
        (select(.type == "anthropic_federation_rule" and ($after.oauth_scope | IN("workspace:developer", "workspace:inference") | not))
         | "\($a) grants \($after.oauth_scope // "an unknown scope"): the pipeline makes workspace:developer and workspace:inference rules only (the org:admin rule is the bootstrap, made by hand)"),
        (select(.type == "anthropic_service_account" and $after.organization_role != "developer")
         | "\($a) has the organization role \($after.organization_role // "unknown"): the pipeline makes developer accounts only (the admin account is the bootstrap, made by hand)"),
        (select(.type == "google_container_node_pool")
         | (select($after.network_config[0].enable_private_nodes == false) | "\($a) has public nodes (network_config.enable_private_nodes)"),
           (select($after.node_config[0].image_type != "COS_CONTAINERD")
            | "\($a) does not run Container-Optimized OS (node_config.image_type is not COS_CONTAINERD)")))' --arg pipeline "serviceAccount:$pipeline_sa" "$p") ||
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
