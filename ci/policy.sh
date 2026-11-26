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
#     rule, exactly as it is, until the runner VMs go (#11); an instance or instance template whose metadata holds an
#     SSH key (ssh-keys or sshKeys), and a looper VM's (tagged looper-vm, #108) that does not block the project's
#     (block-project-ssh-keys "true"): no SSH in any form; a cluster without private nodes, one whose control plane
#     has a public endpoint, no master authorized networks, or a public range among them (#79), a node pool with public
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
#   - in a plan, roles/owner or roles/editor to any service account, the pipeline's own included (#78: its rights are
#     the host's narrower grants on the parent folder, README, What the host organization provides), and
#     roles/container.admin to a service account but the pipeline (#18), in a member, a member list or a policy
#     document, or to a member known only after apply: any of them could delete the cluster, and cluster-admin inside
#     it is a ClusterRoleBinding, not IAM;
#   - in a plan, any role to the audit job's account hub-audit (#77) but its read roles (compute, container, monitoring,
#     secretmanager and cloudquotas viewer, serviceusage.serviceUsageConsumer), in a member, a member list or a policy
#     document: it never writes, and never reads a secret's value; the one exception the cluster autoscaler's log (#85,
#     Jody's option A): roles/logging.viewAccessor in a google_project_iam_member whose condition is exactly that the
#     resource is the view hub-audit-autoscaler of the member's own project's _Default bucket (in a member list or a
#     policy document, or unconditioned, or on another view, it is refused), and that view, wherever it is planned,
#     filters exactly the autoscaler's visibility log: never logging.viewer nor any other log, as a job's output may
#     hold a secret; and its registries role (#115), projects/<P>/roles/hubAuditRegistries, granted on P alone, a role
#     that lists the repositories and reads their IAM policies and nothing else (no image): wherever it is planned, a
#     permission but those is refused;
#   - in a plan, the release registry (#115, modules/projects/ci/releases.tf: the ci project's repository releases):
#     roles/artifactregistry.writer to any member but release-publish, roles/artifactregistry.reader to any member but
#     a service account (a deployment's, which copies the releases), or any other role on it, in a member or a member
#     list, or to a member known only after apply;
#   - in a plan, the Anthropic organization (#34): an identity adopted (imported) with a change, as a live deployment
#     names it and its config was written from what the Console holds (a change is a commit of its own, after); a
#     federation rule whose scope is not workspace:developer or workspace:inference, or a service account whose
#     organization role is not developer: the one org:admin rule and admin account are the bootstrap, made by hand;
#   - the runner manager (#46, #48): in the source, its instance without create_before_destroy or destroy = false;
#     in a plan, a VM tagged runner-manager destroyed, first or after its replacement: destroyed first, the fleet would
#     have no manager and every runner would go offline; destroyed at all, its running jobs would die with it (an
#     old manager retires by itself, its jobs finished: modules/projects/ci/files/manager-startup.sh);
#   - in a plan, a gates job's request (#87): a BUILD_GATES_REQUESTS_<repo> variable ("<cpu> <memory> <cpu limit>
#     <memory limit>", tacplus-dev/looper#202) requesting more than 3 CPU or 10Gi, or whose request cannot be read: the
#     build pool's c4a-standard-4 spot node allocates ~3920m and ~13.3Gi, before its DaemonSets take theirs, so a larger
#     request schedules on no node, and no new node either; only the limits may be the runner's ceilings (3500m 12Gi);
#   - in a plan, a pool the quotas do not cover (#88): its C4A node pools need, in their project and region, their nodes'
#     vCPUs at their maximum plus one node of the largest (being replaced), and their Hyperdisk Balanced disks those
#     nodes' disks plus one, and the plan's Cloud Quotas preferences (CPUS-PER-VM-FAMILY-per-project-region with
#     vm_family C4A, HDB-TOTAL-GB-per-project-region) must ask that or more; and a preference without a contact_email,
#     which Google refuses for an increase;
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
# The pipeline's own identity (modules/settings, bootstrap.pipeline_sa): the one service account that may hold
# roles/container.admin (the host's grant on the parent folder, which GKE's RBAC of the cluster-admin binding needs);
# owner and editor it never holds (#78).
pipeline_sa=cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com
# The audit job's account (#77, modules/projects/ci/hub-audit.tf), and the only roles it may hold: it reads, never
# writes, and reads no secret's value (secretmanager.viewer: names and versions' metadata, never accessor);
# cloudquotas.viewer reads the quotas' limits and preferences (#88).
audit_sa=hub-audit@tacplus-ci.iam.gserviceaccount.com
audit_roles=(roles/compute.viewer roles/container.viewer roles/monitoring.viewer roles/serviceusage.serviceUsageConsumer roles/secretmanager.viewer
  roles/cloudquotas.viewer)
# And the cluster autoscaler's log alone (#85): the view hub-audit-autoscaler of each project's _Default bucket, its
# filter exactly this, which hub-audit reads by roles/logging.viewAccessor conditioned on that view alone.
audit_view=hub-audit-autoscaler
audit_view_filter='LOG_ID("container.googleapis.com/cluster-autoscaler-visibility")'
# And the registries' IAM (#115): its role of each project's own, which lists the repositories and reads their policies.
audit_registries_role=hubAuditRegistries
audit_registries_permissions='["artifactregistry.locations.list","artifactregistry.repositories.get","artifactregistry.repositories.getIamPolicy","artifactregistry.repositories.list"]'
# The release registry (#115): the ci project's repository, and its one writer.
release_repository=releases
release_project=tacplus-ci
release_publisher=serviceAccount:release-publish@tacplus-ci.iam.gserviceaccount.com
# The most a gates job may request (#87), in millicores and bytes: what a c4a-standard-4 spot node (stacks/dev) has
# left after GKE's DaemonSets (metadata server, logging, Dataplane V2, CSI, metrics) and the build's helper (50m 64Mi).
gates_request_cpu=3000
gates_request_memory=$((10 * 1024 * 1024 * 1024))

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
      # A Kubernetes quantity: CPU in millicores ("3", "3500m", "2.5"), memory in bytes ("10Gi", "10240Mi", "10G"); null
      # when it is not one.
      def millicpu: if test("^[0-9]+(\\.[0-9]+)?m$") then .[:-1] | tonumber elif test("^[0-9]+(\\.[0-9]+)?$") then tonumber * 1000 else null end;
      def bytes: [capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>|k|M|G|T|Ki|Mi|Gi|Ti)$")][0]
        | if . == null then null
          else (.n | tonumber) * {"": 1, k: 1e3, M: 1e6, G: 1e9, T: 1e12, Ki: 1024, Mi: 1048576, Gi: 1073741824, Ti: 1099511627776}[.u] end;
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
        # No SSH in any form (#108): no key in a VM'"'"'s metadata (the runner pools'"'"' keys are the fleeting plugin'"'"'s, set
        # at run time, never planned), and a looper VM blocks the project'"'"'s.
        (select(.type | IN("google_compute_instance", "google_compute_instance_template", "google_compute_region_instance_template"))
         | ($after.metadata // {}) as $m
         | (select($m | has("ssh-keys") or has("sshKeys")) | "\($a) has an SSH key in its metadata: no SSH in any form"),
           (select(any($after.tags[]?; . == "looper-vm") and $m["block-project-ssh-keys"] != "true")
            | "\($a) is a looper VM that does not block the project'"'"'s SSH keys (metadata block-project-ssh-keys \"true\"): no SSH in any form (#108)")),
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
         | . as $b
         | (select($b.role | IN("roles/owner", "roles/editor"))
            | if any($unknown[]; test("^(member|members|policy_data)($|\\.)")) then
                "\($a) grants \($b.role) to a member known only after apply: no service account holds it, the pipeline neither"
              else
                ($b.members[] | select(startswith("serviceAccount:"))
                 | "\($a) grants \($b.role) to \(.): no service account holds it, the pipeline neither (it could delete the cluster, and everything else)")
              end),
           (select($b.role == "roles/container.admin")
            | if any($unknown[]; test("^(member|members|policy_data)($|\\.)")) then
                "\($a) grants \($b.role) to a member known only after apply: no service account holds it but the pipeline itself"
              else
                ($b.members[] | select(startswith("serviceAccount:") and . != $pipeline)
                 | "\($a) grants \($b.role) to \(.): no service account holds it but the pipeline itself (it could delete the cluster)")
              end),
           # hub-audit'"'"'s viewAccessor (#85): in a member alone, conditioned on its project'"'"'s view hub-audit-autoscaler alone.
           (select($b.role == "roles/logging.viewAccessor") | $b.members[] | select(. == $audit)
            | select($rc.type != "google_project_iam_member"
                or ($after.condition // [] | map(.expression)) != ["resource.name == \"projects/\($after.project)/locations/global/buckets/_Default/views/\($audit_view)\""])
            | "\($a) grants \($b.role) to \(.) but on the view \($audit_view) of its project alone (a google_project_iam_member, its condition resource.name == \"projects/\($after.project // "PROJECT")/locations/global/buckets/_Default/views/\($audit_view)\"): the audit'"'"'s account reads the cluster autoscaler'"'"'s log alone (#85)"),
           (select($b.role | IN($audit_roles[], "roles/logging.viewAccessor") | not) | $b.members[] | select(. == $audit)
            # Its registries role (#115), on its own project alone, in a member.
            | select(($rc.type == "google_project_iam_member" and $b.role == "projects/\($after.project)/roles/\($audit_registries_role)") | not)
            | "\($a) grants \($b.role) to \(.): the audit'"'"'s account reads only (\($audit_roles | join(", ")), roles/logging.viewAccessor on the view \($audit_view) alone, and its own project'"'"'s \($audit_registries_role); never logging.viewer, as a job'"'"'s output may hold a secret)"),
           # The release registry (#115): release-publish writes, service accounts read, nothing else.
           (select($rc.type | test("^google_artifact_registry_repository_iam_(member|binding)$"))
            | select(($after.repository // "" | split("/") | last) == $release_repository and ($after.project // $release_project) == $release_project)
            | if any($unknown[]; test("^(member|members)($|\\.)")) then
                "\($a) grants \($b.role) on the release registry to a member known only after apply: each is written out"
              elif $b.role == "roles/artifactregistry.writer" then
                ($b.members[] | select(. != $release_publisher)
                 | "\($a) grants \($b.role) on the release registry to \(.): release-publish alone writes it")
              elif $b.role == "roles/artifactregistry.reader" then
                ($b.members[] | select(startswith("serviceAccount:") | not)
                 | "\($a) grants \($b.role) on the release registry to \(.): only a deployment'"'"'s service account reads it")
              else
                "\($a) grants \($b.role) on the release registry: its roles are writer (release-publish) and reader alone"
              end)),
        # hub-audit'"'"'s registries role (#115) lists the repositories and reads their policies, never an image.
        (select(.type == "google_project_iam_custom_role" and $after.role_id == $audit_registries_role)
         | ($after.permissions // [] | map(select(IN($audit_registries_permissions[]) | not))) as $extra
         | select($extra | length > 0)
         | "\($a): the role \($audit_registries_role) holds \($extra | join(", ")): hub-audit lists the repositories and reads their policies alone (\($audit_registries_permissions | join(", ")))"),
        # The view hub-audit reads (#85) holds the cluster autoscaler'"'"'s visibility log alone.
        (select(.type == "google_logging_log_view" and $after.name == $audit_view and $after.filter != $audit_view_filter)
         | "\($a): the view \($audit_view) filters \($after.filter // "a value known only after apply" | tojson), not exactly \($audit_view_filter): hub-audit reads the cluster autoscaler'"'"'s log alone, never a job'"'"'s output (#85)"),
        # A gates job'"'"'s request (#87) fits a c4a-standard-4 spot node after its DaemonSets: only its limits are the ceilings.
        (select(.type == "gitlab_project_variable" and ($after.key // "" | startswith("BUILD_GATES_REQUESTS_")))
         | ($after.value // "" | split(" ") | map(select(. != ""))) as $f
         | ($f[0] // "" | millicpu) as $cpu | ($f[1] // "" | bytes) as $mem
         | if $cpu == null or $mem == null then
             "\($a): \($after.key): its request (\($f[:2] | join(" ") | tojson)) cannot be read: \"<cpu> <memory> <cpu limit> <memory limit>\" (tacplus-dev/looper#202)"
           else
             (select($cpu > $gates_cpu)
              | "\($a): \($after.key) requests \($f[0]) CPU, more than \($gates_cpu / 1000) CPU: a c4a-standard-4 spot node has no more after its DaemonSets, so the gates job never schedules (#87); only its limit may be the runner'"'"'s 3500m"),
             (select($mem > $gates_memory)
              | "\($a): \($after.key) requests \($f[1]) of memory, more than \($gates_memory / 1073741824)Gi: a c4a-standard-4 spot node has no more after its DaemonSets, so the gates job never schedules (#87); only its limit may be the runner'"'"'s 12Gi")
           end),
        (select(.type == "google_container_cluster")
         | (select($after.private_cluster_config[0].enable_private_nodes != true)
            | "\($a) has no private nodes (private_cluster_config.enable_private_nodes): nodes have no external address"),
           # Only load balancers are public (#79): the control plane has no public endpoint, and admits private ranges alone.
           (select($after.private_cluster_config[0].enable_private_endpoint != true)
            | "\($a) has a public control-plane endpoint (private_cluster_config.enable_private_endpoint): only load balancers are public"),
           (($after.master_authorized_networks_config // [])[0] as $m
            | if $m == null then "\($a) has no master authorized networks (master_authorized_networks_config): its control plane admits the cluster'"'"'s own ranges alone"
              else (select($m.gcp_public_cidrs_access_enabled == true)
                    | "\($a) authorizes Google Cloud'"'"'s public ranges to its control plane (master_authorized_networks_config.gcp_public_cidrs_access_enabled)"),
                   ($m.cidr_blocks[]?.cidr_block | select(. as $s | all("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"; . as $net | $s | within($net) | not))
                    | "\($a) authorizes \(.) to its control plane, a public range")
              end)),
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
            | "\($a) does not run Container-Optimized OS (node_config.image_type is not COS_CONTAINERD)")))' --arg pipeline "serviceAccount:$pipeline_sa" \
      --arg audit "serviceAccount:$audit_sa" --arg audit_view "$audit_view" --arg audit_view_filter "$audit_view_filter" \
      --arg audit_registries_role "$audit_registries_role" --argjson audit_registries_permissions "$audit_registries_permissions" \
      --arg release_repository "$release_repository" --arg release_project "$release_project" --arg release_publisher "$release_publisher" \
      --argjson gates_cpu "$gates_request_cpu" --argjson gates_memory "$gates_request_memory" --argjson audit_roles "$(printf '%s\n' "${audit_roles[@]}" | jq -R . | jq -sc .)" "$p") ||
      { refuse "$p: cannot read its changes"; continue; }
    while IFS= read -r line; do [ -n "$line" ] && refuse "$p: $line"; done <<< "$out"
    # The node pools' quotas (#88), over the whole plan: what its C4A pools need at their maximum, with one node of the
    # largest being replaced, is what the project's quota preferences in their region ask, or more.
    out=$(jq -r '
      def region: sub("-[a-z]$"; "");
      def vcpus: (capture("^[a-z0-9]+-[a-z]+-(?<n>[0-9]+)") | .n | tonumber) // null;
      [.resource_changes[] | select(.change.after != null)] as $rcs
      | [$rcs[] | select(.type == "google_cloud_quotas_quota_preference") | .address as $a | .change.after | . + {address: $a}] as $prefs
      | ($prefs[] | select((.contact_email // "") == "")
         | "\(.address) has no contact_email: Google refuses an increase without one (the protected variable GCP_QUOTA_CONTACT, README, The node pools'"'"' quotas)"),
        ([$rcs[] | select(.type == "google_container_node_pool") | .address as $a | .change.after
          | (.node_config[0] // {}) as $n
          | {address: $a, project, region: ((.location // "") | region), machine_type: ($n.machine_type // ""), disk_type: ($n.disk_type // ""),
             disk_gb: $n.disk_size_gb,
             nodes: (if (.autoscaling // []) | length > 0 then .autoscaling[0] | (.total_max_node_count // null) // (if .max_node_count then .max_node_count * ([1, (.node_locations // [] | length)] | max) else null end)
                     else .node_count end)}
          | select(.machine_type | startswith("c4a-"))]
         | group_by([.project, .region])[]
         | .[0].project as $project | .[0].region as $region
         | (.[] | select(.nodes == null or (.machine_type | vcpus) == null or (.disk_type == "hyperdisk-balanced" and .disk_gb == null))
            | "\(.address): its machine type, maximum or disk cannot be read: the quotas it needs are unknown (#88)"),
           ([.[] | select(.nodes != null and (.machine_type | vcpus) != null)] as $pools
            | ([$pools[] | {need: (.nodes * (.machine_type | vcpus)), node: (.machine_type | vcpus)}]
               | {what: "C4A CPUs", quota_id: "CPUS-PER-VM-FAMILY-per-project-region", vm_family: "C4A", need: ((map(.need) | add) + (map(.node) | max))}),
              ([$pools[] | select(.disk_type == "hyperdisk-balanced" and .disk_gb != null) | {need: (.nodes * .disk_gb), node: .disk_gb}]
               | select(length > 0)
               | {what: "GB of Hyperdisk Balanced", quota_id: "HDB-TOTAL-GB-per-project-region", vm_family: null, need: ((map(.need) | add) + (map(.node) | max))})
            | . as $q
            | [$prefs[] | select(.service == "compute.googleapis.com" and .parent == "projects/\($project)" and .quota_id == $q.quota_id
                and (.dimensions // {}).region == $region and (.dimensions // {}).vm_family == $q.vm_family)] as $match
            | if ($match | length) == 0 then
                "the node pools of \($project) in \($region) need \($q.need) \($q.what) at their maximum, with one node being replaced, and no quota preference asks for them (\($q.quota_id)\(if $q.vm_family then ", vm_family \($q.vm_family)" else "" end)): a pool over its quota cannot grow (#88)"
              else
                $match[] | (.quota_config[0].preferred_value // "" | tostring | tonumber? // null) as $v
                | select($v == null or $v < $q.need)
                | "\(.address) asks \($v // "an unknown number of") \($q.what), fewer than the \($q.need) the node pools of \($project) in \($region) need at their maximum, with one node being replaced: a pool over its quota cannot grow (#88)"
              end))' "$p") ||
      { refuse "$p: cannot read its node pools and quotas"; continue; }
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
