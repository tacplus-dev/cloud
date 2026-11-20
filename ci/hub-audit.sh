#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The audit job's report (#77): what the hub read with gcloud on the Mac, read by the pipeline instead, as the
# read-only account hub-audit (ci/lib.sh ci_audit), into DIR/audit.json and DIR/audit.md, the job's artifact, which the
# hub downloads (README, The hub's audit). For each PROJECT:
#   - exposure: the enabled ingress allow rules open to 0.0.0.0/0 or ::/0, the VMs with an external IP, the external
#     addresses and what uses each, the load balancers (forwarding rules);
#   - inventory: every VM (its machine type, provisioning model, status, creation), every node pool (machine type,
#     spot, its autoscaling's min and max, its nodes now: the VMs GKE labels with its cluster and pool), the disks by type;
#   - quotas: CPUS_ALL_REGIONS, and REGION's CPUS, SSD_TOTAL_GB, PREEMPTIBLE_CPUS, T2A_CPUS and C4A_CPUS, with usage;
#   - utilization, over the last hour, the maximum of 10-minute windows (Cloud Monitoring): each VM's CPU, each GKE
#     node's CPU (of its allocatable), and each container's CPU and memory used against its requests in namespace ci;
#   - secrets: their names and their versions' states, never a value;
#   - scheduling (#85), through each cluster's API (container.viewer; the job runs in the cluster, which alone reaches
#     its private endpoint): each spot node (of a pool with spot, or labelled so), its allocatable CPU and memory, and
#     the pods on it, each with its phase, creation, owner (its owner references, or the GitLab job of a runner's pod)
#     and requests (its containers', or an init container's if more, and its overhead), summed; and the pods not
#     scheduled, with why. A pod's spec, its env with it, is read into the temporary directory and never written out;
#   - the cluster autoscaler (#85), when AUDIT_AUTOSCALER_LOG is true (ci/lib.sh ci_autoscaler_log): its events of the
#     last 6 hours (container.googleapis.com/cluster-autoscaler-visibility), through the log view hub-audit-autoscaler
#     of each project's _Default bucket, the one log hub-audit may read (modules/projects/ci/hub-audit.tf): each
#     no-scale-up by pool, zone and reason (a pool rejected or skipped, or none), with its count, first and last times
#     and the pods it left, and each scale-up error, joined to the pools its decision tried. False, until the host
#     grants what the views need, it is noted as not read.
# It only reads: lists and describes, Monitoring's timeSeries.list, Logging's entries.list of that view, and the
# cluster's nodes and pods. An API not enabled in a project is noted, its list empty (none can exist there). It fails,
# both files written, on an exposure finding (an ingress rule open to 0.0.0.0/0 or ::/0, a VM with an external IP) or
# a read it could not make, so the job shows red. AUDIT_NOW (epoch seconds, default now) ends the hour and the
# autoscaler's hours, and MONITORING_API and LOGGING_API are Monitoring's and Logging's endpoints, for
# tests/hub_audit_test.sh.
#
#   AUDIT_AUTOSCALER_LOG=true|false ci/hub-audit.sh DIR REGION PROJECT...
#                                     # needs gcloud (signed in: ci/lib.sh ci_audit), curl, jq, base64 and date
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: ci/hub-audit.sh DIR REGION PROJECT..." >&2; exit 2; }
autoscaler_log=${AUDIT_AUTOSCALER_LOG:-false}
case $autoscaler_log in
  true | false) ;;
  *) echo "usage: AUDIT_AUTOSCALER_LOG is true or false (ci/lib.sh ci_autoscaler_log), not [$autoscaler_log]" >&2; exit 2 ;;
esac
out=$1 region=$2
shift 2
mkdir -p "$out" || exit 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
now=${AUDIT_NOW:-$(date -u +%s)}
end=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ) && start=$(date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ) &&
  log_start=$(date -u -d "@$((now - 6 * 3600))" +%Y-%m-%dT%H:%M:%SZ) || exit 2
api=${MONITORING_API:-https://monitoring.googleapis.com}
logging=${LOGGING_API:-https://logging.googleapis.com}
: > "$tmp/errors"
: > "$tmp/unavailable"

# failed PROJECT FILE WHAT: the read of FILE that failed (its error in FILE.err): an API not enabled is unavailable (nothing of it can exist), any
# other refusal an error.
failed() {
  local why
  why=$(grep -m1 -E '^ERROR|"message"' "$2.err" 2>/dev/null || head -c 300 "$2.err" 2>/dev/null)
  why=$(tr '\n' ' ' <<< "$why" | sed 's/^ *//; s/ *$//')
  if grep -qE 'SERVICE_DISABLED|has not been used in project|is disabled' "$2.err" 2>/dev/null; then
    jq -nc --arg p "$1" --arg w "$3" '{project: $p, what: $w, why: "its API is not enabled"}' >> "$tmp/unavailable"
  else
    jq -nc --arg p "$1" --arg w "$3" --arg e "$why" '{project: $p, what: $w, error: $e}' >> "$tmp/errors"
  fi
}
# read_json PROJECT FILE EMPTY WHAT GCLOUD-ARGS...: gcloud's JSON into FILE, or EMPTY ([] or {}) and the failure.
read_json() {
  local p=$1 f=$2 empty=$3 what=$4
  shift 4
  gcloud "$@" --project="$p" --format=json < /dev/null > "$f" 2> "$f.err" && jq -e . "$f" > /dev/null 2>&1 && return
  failed "$p" "$f" "$what"
  echo "$empty" > "$f"
  return 1
}

# The Monitoring token, once: hub-audit's, as gcloud holds it. Never printed.
if token=$(gcloud auth print-access-token 2> "$tmp/token.err") && [ -n "$token" ]; then
  ( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth" )
else
  jq -nc --arg e "$(head -c 300 "$tmp/token.err" | tr '\n' ' ')" '{project: "", what: "a Monitoring token", error: $e}' >> "$tmp/errors"
fi
unset token
# series PROJECT FILE WHAT ALIGNER FILTER: the time series of FILTER over the hour, aligned to 10-minute windows by
# ALIGNER, every page, as one array in FILE ([] and the failure if a page is refused).
series() {
  local p=$1 f=$2 what=$3 aligner=$4 filter=$5 page='' code n=0
  echo '[]' > "$f"
  [ -f "$tmp/auth" ] || return 1
  while :; do
    n=$((n + 1))
    code=$(curl -sS -G -o "$f.page" -w '%{http_code}' -H @"$tmp/auth" "$api/v3/projects/$p/timeSeries" \
      --data-urlencode "filter=$filter" --data-urlencode "interval.startTime=$start" --data-urlencode "interval.endTime=$end" \
      --data-urlencode "aggregation.alignmentPeriod=600s" --data-urlencode "aggregation.perSeriesAligner=$aligner" \
      --data-urlencode "pageSize=1000" ${page:+--data-urlencode "pageToken=$page"} 2> "$f.err")
    if [ "$code" != 200 ] || ! jq -e 'type == "object"' "$f.page" > /dev/null 2>&1; then
      { echo "HTTP ${code:-none}"; cat "$f.page" 2>/dev/null; } >> "$f.err"
      failed "$p" "$f" "$what"
      echo '[]' > "$f"
      return 1
    fi
    jq -s '.[0] + (.[1].timeSeries // [])' "$f" "$f.page" > "$f.next" && mv "$f.next" "$f"
    page=$(jq -r '.nextPageToken // empty' "$f.page")
    [ -n "$page" ] && [ "$n" -lt 100 ] || break
  done
}
# entries PROJECT FILE WHAT: the cluster autoscaler's log entries of the last 6 hours, oldest first, through the view
# hub-audit-autoscaler of PROJECT's _Default bucket, every page, as one array in FILE, each entry's time and payload
# alone ([] and the failure if a page is refused).
entries() {
  local p=$1 f=$2 what=$3 page='' code n=0
  echo '[]' > "$f"
  [ -f "$tmp/auth" ] || return 1
  while :; do
    n=$((n + 1))
    jq -nc --arg view "projects/$p/locations/global/buckets/_Default/views/hub-audit-autoscaler" --arg page "$page" \
      --arg filter "logName=\"projects/$p/logs/container.googleapis.com%2Fcluster-autoscaler-visibility\" AND timestamp>=\"$log_start\" AND timestamp<\"$end\"" \
      '{resourceNames: [$view], filter: $filter, orderBy: "timestamp asc", pageSize: 1000} + (if $page == "" then {} else {pageToken: $page} end)' > "$f.body"
    code=$(curl -sS -o "$f.page" -w '%{http_code}' -X POST -H @"$tmp/auth" -H 'Content-Type: application/json' \
      --data-binary @"$f.body" "$logging/v2/entries:list" 2> "$f.err")
    if [ "$code" != 200 ] || ! jq -e 'type == "object"' "$f.page" > /dev/null 2>&1; then
      { echo "HTTP ${code:-none}"; cat "$f.page" 2>/dev/null; } >> "$f.err"
      failed "$p" "$f" "$what"
      echo '[]' > "$f"
      return 1
    fi
    jq -s '.[0] + [.[1].entries[]? | {timestamp, payload: (.jsonPayload // {})}]' "$f" "$f.page" > "$f.next" && mv "$f.next" "$f"
    page=$(jq -r '.nextPageToken // empty' "$f.page")
    [ -n "$page" ] && [ "$n" -lt 100 ] || break
  done
}
# kube PROJECT FILE WHAT ENDPOINT CA PATH [CURL-ARGS...]: a GET of PATH on the cluster's API at ENDPOINT (its CA the
# file CA), as hub-audit, into FILE (the failure if refused, FILE removed).
kube() {
  local p=$1 f=$2 what=$3 ep=$4 ca=$5 path=$6 code
  shift 6
  [ -f "$tmp/auth" ] || return 1
  code=$(curl -sS -G -o "$f" -w '%{http_code}' --cacert "$ca" -H @"$tmp/auth" "https://$ep$path" "$@" 2> "$f.err")
  [ "$code" = 200 ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1 && return
  { echo "HTTP ${code:-none}"; head -c 300 "$f" 2>/dev/null; } >> "$f.err"
  rm -f "$f"
  failed "$p" "$f" "$what"
  return 1
}
# A Kubernetes quantity (100m, 2, 13456244Ki, 4G), as a number: cores or bytes.
qty='def qty: if . == null then 0 else tostring | capture("^(?<n>[0-9.eE+-]+?)(?<s>m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$") as $c
  | ($c.n | tonumber) * ({"": 1, m: 0.001, k: 1e3, M: 1e6, G: 1e9, T: 1e12, P: 1e15, E: 1e18, Ki: 1024, Mi: 1048576,
      Gi: 1073741824, Ti: 1099511627776, Pi: 1125899906842624, Ei: 1152921504606846976}[$c.s // ""]) end;'

for p in "$@"; do
  d=$tmp/p/$p
  mkdir -p "$d"
  read_json "$p" "$d/firewall-rules.json" '[]' "firewall rules" compute firewall-rules list
  read_json "$p" "$d/instances.json" '[]' "VMs" compute instances list
  read_json "$p" "$d/addresses.json" '[]' "addresses" compute addresses list
  read_json "$p" "$d/forwarding-rules.json" '[]' "forwarding rules" compute forwarding-rules list
  read_json "$p" "$d/disks.json" '[]' "disks" compute disks list
  read_json "$p" "$d/clusters.json" '[]' "clusters" container clusters list
  # Each cluster's nodes and its pods not finished, read whole into the temporary directory and cut down at once to
  # what the report says: no pod's spec (its env) goes further.
  : > "$d/kube.jsonl"
  jq -c '.[] | {name, endpoint: (.endpoint // ""), ca: (.masterAuth.clusterCaCertificate // "")}' "$d/clusters.json" | while read -r c; do
    name=$(jq -r .name <<< "$c") ep=$(jq -r .endpoint <<< "$c")
    if [ -z "$ep" ] || ! jq -r .ca <<< "$c" | base64 -d > "$d/ca-$name.pem" 2> /dev/null || [ ! -s "$d/ca-$name.pem" ]; then
      jq -nc --arg p "$p" --arg w "the cluster $name's nodes and pods" '{project: $p, what: $w, error: "its description has no endpoint or CA"}' >> "$tmp/errors"
      continue
    fi
    kube "$p" "$d/nodes.raw" "the cluster $name's nodes" "$ep" "$d/ca-$name.pem" /api/v1/nodes &&
      kube "$p" "$d/pods.raw" "the cluster $name's pods" "$ep" "$d/ca-$name.pem" /api/v1/pods \
        --data-urlencode 'fieldSelector=status.phase!=Succeeded,status.phase!=Failed' &&
      jq -nc --arg cluster "$name" --slurpfile nodes "$d/nodes.raw" --slurpfile pods "$d/pods.raw" "$qty"'
        def cpu: . * 1000 | round / 1000;
        def requests($r): ([(.spec.containers // [])[] | .resources.requests[$r]? | qty] | add // 0) as $run
          | ([(.spec.initContainers // [])[] | .resources.requests[$r]? | qty] | max // 0) as $init
          | ([$run, $init] | max) + ((.spec.overhead // {})[$r] | qty);
        {cluster: $cluster,
         nodes: [$nodes[0].items[]? | .metadata.labels as $l
           | {name: .metadata.name, pool: $l["cloud.google.com/gke-nodepool"], zone: $l["topology.kubernetes.io/zone"],
              spot: ($l["cloud.google.com/gke-spot"] == "true"), created: .metadata.creationTimestamp,
              cpu: (.status.allocatable.cpu | qty | cpu), memory: (.status.allocatable.memory | qty | round)}] | sort_by(.name),
         pods: [$pods[0].items[]? | (.metadata.annotations // {})["job.runner.gitlab.com/url"] as $job | (.metadata.ownerReferences // []) as $o
           | {namespace: .metadata.namespace, name: .metadata.name, node: .spec.nodeName, phase: .status.phase,
              created: .metadata.creationTimestamp,
              owner: (if ($o | length) > 0 then $o | map("\(.kind)/\(.name)") | join(", ") elif $job then "GitLab job \($job)" else null end),
              cpu: (requests("cpu") | cpu), memory: (requests("memory") | round),
              why: ([.status.conditions[]? | select(.type == "PodScheduled" and .status == "False") | .message // .reason][0])}]}' >> "$d/kube.jsonl" ||
      jq -nc --arg p "$p" --arg w "the cluster $name's nodes and pods" '{project: $p, what: $w, error: "cannot read them"}' >> "$tmp/errors"
    rm -f "$d/nodes.raw" "$d/pods.raw"
  done
  read_json "$p" "$d/project-info.json" '{}' "the project's quotas" compute project-info describe
  read_json "$p" "$d/region.json" '{}' "the quotas of $region" compute regions describe "$region"
  : > "$d/secrets.jsonl"
  if read_json "$p" "$d/secrets.json" '[]' "secrets" secrets list; then
    jq -r '.[].name | split("/") | last' "$d/secrets.json" | while read -r s; do
      read_json "$p" "$d/versions.json" '[]' "the versions of the secret $s" secrets versions list "$s"
      jq -c --arg s "$s" '{name: $s, versions: [.[] | {version: (.name | split("/") | last), state}]}' "$d/versions.json" >> "$d/secrets.jsonl"
    done
  fi
  ns='resource.labels.namespace_name = "ci"'
  series "$p" "$d/m-vm-cpu.json" "the VMs' CPU" ALIGN_MAX 'metric.type = "compute.googleapis.com/instance/cpu/utilization"'
  series "$p" "$d/m-node-cpu.json" "the nodes' CPU" ALIGN_MAX 'metric.type = "kubernetes.io/node/cpu/allocatable_utilization"'
  series "$p" "$d/m-ctr-cpu.json" "the containers' CPU" ALIGN_RATE "metric.type = \"kubernetes.io/container/cpu/core_usage_time\" AND $ns"
  series "$p" "$d/m-ctr-cpu-req.json" "the containers' CPU requests" ALIGN_MAX "metric.type = \"kubernetes.io/container/cpu/request_cores\" AND $ns"
  series "$p" "$d/m-ctr-mem.json" "the containers' memory" ALIGN_MAX "metric.type = \"kubernetes.io/container/memory/used_bytes\" AND metric.labels.memory_type = \"non-evictable\" AND $ns"
  series "$p" "$d/m-ctr-mem-req.json" "the containers' memory requests" ALIGN_MAX "metric.type = \"kubernetes.io/container/memory/request_bytes\" AND $ns"
  if [ "$autoscaler_log" = true ]; then
    entries "$p" "$d/autoscaler.json" "the cluster autoscaler's events"
  else
    echo '[]' > "$d/autoscaler.json"
    jq -nc --arg p "$p" '{project: $p, what: "the cluster autoscaler'"'"'s events", why: "its log view waits on the host'"'"'s grant (modules/settings autoscaler_log)"}' >> "$tmp/unavailable"
  fi
  args=(--arg project "$p")
  for f in "$d"/*.json; do
    k=$(basename "$f" .json)
    case $k in secrets | versions) continue ;; esac
    args+=(--slurpfile "${k//-/_}" "$f")
  done
  jq -n "${args[@]}" --slurpfile secrets <(jq -s . "$d/secrets.jsonl") --slurpfile kube <(jq -s . "$d/kube.jsonl") \
    '$ARGS.named | with_entries(.value |= if type == "array" then .[0] else . end) | .secrets = $secrets[0] | .kube = $kube[0]' > "$tmp/p/$p.json" ||
    jq -nc --arg p "$p" '{project: $p, what: "its lists", error: "cannot read them"}' >> "$tmp/errors"
done

jq -n --arg start "$start" --arg end "$end" --arg log_start "$log_start" --arg autoscaler_log "$autoscaler_log" --arg region "$region" --arg commit "${CLOUD_COMMIT:-}" \
  --arg pipeline "${CI_PIPELINE_URL:-}" --arg job "${CI_JOB_URL:-}" \
  --slurpfile ps <(cat "$tmp"/p/*.json 2>/dev/null | jq -s .) \
  --slurpfile errors <(jq -s . "$tmp/errors") --slurpfile unavailable <(jq -s . "$tmp/unavailable") '
  def base: split("/") | last;
  # The last two segments of a URL: its kind and name (forwardingRules/gateway).
  def ref: split("/") | .[-2:] | join("/");
  def scope: if .region then (.region | base) elif .zone then (.zone | base) else "global" end;
  def maxv: [.points[]?.value | (.doubleValue // (.int64Value | tonumber?)) // empty] | max;
  def world: IN("0.0.0.0/0", "::/0");
  # An autoscaler message: its ID and parameters.
  def msg: .messageId + (if (.parameters // []) | length > 0 then ": " + (.parameters | join(", ")) else "" end);
  $ps[0] as $ps
  | ([$ps[] | .project as $p | .firewall_rules[]
      | select((.direction // "INGRESS") == "INGRESS" and ((.allowed // []) | length > 0) and any(.sourceRanges[]?; world))
      | {project: $p, name, network: ((.network // "") | base), sources: [.sourceRanges[] | select(world)],
         allowed: [.allowed[] | .IPProtocol + (if .ports then ":" + (.ports | join(",")) else "" end)],
         target_tags: (.targetTags // []), disabled: (.disabled // false)}]) as $open
  | ([$ps[] | .project as $p | .instances[]
      | [.networkInterfaces[]? | (.accessConfigs // [])[], (.ipv6AccessConfigs // [])[]] as $ac
      | select($ac | length > 0)
      | {project: $p, vm: .name, zone: (.zone | base), ips: [$ac[] | .natIP // .externalIpv6 // "(none yet)"]}]) as $external
  | {
    generated: $end, commit: $commit, pipeline: $pipeline, job: $job, region: $region, projects: [$ps[].project],
    exposure: {
      open_ingress: $open,
      external_ips: $external,
      external_addresses: [$ps[] | .project as $p | .addresses[] | select((.addressType // "EXTERNAL") == "EXTERNAL")
        | {project: $p, name, scope: scope, address, status, users: [.users[]? | ref]}],
      load_balancers: [$ps[] | .project as $p | .forwarding_rules[]
        | {project: $p, name, scope: scope, ip: .IPAddress, protocol: .IPProtocol, ports: (.portRange // ((.ports // []) | join(","))),
           scheme: .loadBalancingScheme, target: ((.target // .backendService // "") | ref)}]
    },
    inventory: {
      vms: [$ps[] | .project as $p | .instances[]
        | {project: $p, name, zone: (.zone | base), machine_type: (.machineType | base),
           provisioning: (.scheduling.provisioningModel // (if .scheduling.preemptible then "PREEMPTIBLE" else "STANDARD" end)),
           status, created: .creationTimestamp}],
      node_pools: [$ps[] | .project as $p | .instances as $vms | .clusters[] | .name as $c | .location as $l | .nodePools[]?
        | .name as $n
        | {project: $p, cluster: $c, location: $l, name: $n, machine_type: .config.machineType, spot: (.config.spot // false),
           autoscaling: (.autoscaling.enabled // false),
           min: (if .autoscaling.enabled then .autoscaling.minNodeCount // .autoscaling.totalMinNodeCount else null end),
           max: (if .autoscaling.enabled then .autoscaling.maxNodeCount // .autoscaling.totalMaxNodeCount else null end),
           nodes: ([$vms[] | select(.labels["goog-k8s-cluster-name"] == $c and .labels["goog-k8s-node-pool-name"] == $n)] | length)}],
      disks: [$ps[] | .project as $p | .disks | group_by(.type | base)[]
        | {project: $p, type: (.[0].type | base), count: length, gb: (map(.sizeGb | tonumber) | add)}]
    },
    quotas: [$ps[] | .project as $p
      | (.project_info.quotas // []) as $g | (.region.quotas // []) as $r
      | ({scope: "global", metric: "CPUS_ALL_REGIONS", q: $g},
         ("CPUS", "SSD_TOTAL_GB", "PREEMPTIBLE_CPUS", "T2A_CPUS", "C4A_CPUS" | {scope: $region, metric: ., q: $r}))
      | .metric as $m | ([.q[] | select(.metric == $m)][0] // {}) as $found
      | {project: $p, scope, metric, limit: $found.limit, usage: $found.usage}],
    utilization: {
      window: {start: $start, end: $end, alignment_seconds: 600, aggregation: "max"},
      vms: [$ps[] | .project as $p | .m_vm_cpu[]
        | {project: $p, vm: .metric.labels.instance_name, zone: .resource.labels.zone, cpu_max: maxv}],
      nodes: [$ps[] | .project as $p | .m_node_cpu[]
        | {project: $p, cluster: .resource.labels.cluster_name, node: .resource.labels.node_name, cpu_max: maxv}],
      containers: [$ps[] | .project as $p
        | def key: .resource.labels | [.cluster_name, .pod_name, .container_name] | join("/");
          def by($m): reduce $m[] as $s ({}; .[$s | key] = ($s | maxv));
          by(.m_ctr_cpu) as $cpu | by(.m_ctr_cpu_req) as $cpu_req | by(.m_ctr_mem) as $mem | by(.m_ctr_mem_req) as $mem_req
        | [.m_ctr_cpu[], .m_ctr_cpu_req[], .m_ctr_mem[], .m_ctr_mem_req[] | .resource.labels] | unique_by([.cluster_name, .pod_name, .container_name])[]
        | ([.cluster_name, .pod_name, .container_name] | join("/")) as $k
        | {project: $p, cluster: .cluster_name, pod: .pod_name, container: .container_name,
           cpu_used_max: $cpu[$k], cpu_requested: $cpu_req[$k], memory_used_max: $mem[$k], memory_requested: $mem_req[$k]}]
    },
    scheduling: {
      spot_nodes: [$ps[] | .project as $p
        | ([.clusters[] | {key: .name, value: [.nodePools[]? | select(.config.spot) | .name]}] | from_entries) as $spot
        | .kube[] | .cluster as $c | .pods as $pods | .nodes[]
        | select(.spot or (.pool as $n | any(($spot[$c] // [])[]; . == $n)))
        | . as $node | [$pods[] | select(.node == $node.name)] | sort_by(.namespace, .name)
        | {project: $p, cluster: $c, pool: $node.pool, node: $node.name, zone: $node.zone, created: $node.created,
           cpu_allocatable: $node.cpu, memory_allocatable: $node.memory,
           cpu_requested: (map(.cpu) | add // 0 | . * 1000 | round / 1000), memory_requested: (map(.memory) | add // 0),
           pods: [.[] | {namespace, name, phase, created, owner, cpu_requested: .cpu, memory_requested: .memory}]}],
      pending_pods: [$ps[] | .project as $p | .kube[] | .cluster as $c | .pods[] | select(.node == null and .phase == "Pending")
        | {project: $p, cluster: $c, namespace, name, created, owner, cpu_requested: .cpu, memory_requested: .memory, why}]
    },
    autoscaler: {
      read: ($autoscaler_log == "true"),
      window: {start: $log_start, end: $end},
      # Each event once per pool, zone and reason, then counted across the hours.
      no_scale_up: ([$ps[] | .project as $p | .autoscaler[] | .timestamp as $t | .payload.noDecisionStatus.noScaleUp // empty
          | [(.unhandledPodGroups[]? | [.podGroup.samplePod // empty | "\(.namespace)/\(.name)"] as $pods
              | .rejectedMigs[]? | {pool: .mig.nodepool, zone: .mig.zone, reason: (.reason | msg), pods: $pods}),
             (.skippedMigs[]? | {pool: .mig.nodepool, zone: .mig.zone, reason: (.reason | msg), pods: []}),
             (.reason // empty | {pool: null, zone: null, reason: msg, pods: []})]
          | group_by([.pool, .zone, .reason])[] | {project: $p, pool: .[0].pool, zone: .[0].zone, reason: .[0].reason, t: $t, pods: (map(.pods[]) | unique)}]
        | group_by([.project, .pool, .zone, .reason])
        | map({project: .[0].project, pool: .[0].pool, zone: .[0].zone, reason: .[0].reason, count: length,
               first: (map(.t) | min), last: (map(.t) | max), pods: (map(.pods[]) | unique)})),
      scale_up_errors: [$ps[] | .project as $p | .autoscaler as $e
        | ([$e[] | .payload.decision // empty | select(.eventId)
            | {key: .eventId, value: [.scaleUp.increasedMigs[]? | {pool: .mig.nodepool, zone: .mig.zone, requested: .requestedNodes}]}] | from_entries) as $tried
        | $e[] | .timestamp as $t | .payload.resultInfo.results[]? | select(.errorMsg)
        | {project: $p, time: $t, event_id: .eventId, error: (.errorMsg | msg), pools: ($tried[.eventId] // [])}]
    },
    secrets: [$ps[] | .project as $p | .secrets[] | {project: $p} + .],
    findings: ([$open[] | select(.disabled | not)
        | "\(.project): firewall rule \(.name) allows ingress from \(.sources | join(" and ")) (\(.allowed | join(" ")))"]
      + [$external[] | "\(.project): VM \(.vm) has an external IP (\(.ips | join(", ")))"]),
    unavailable: $unavailable[0],
    errors: $errors[0]
  }' > "$out/audit.json" || { echo "audit: cannot write its report" >&2; exit 1; }

jq -r '
  def cell: if . == null then "-" elif type == "array" then (if length == 0 then "-" else join(", ") end) else tostring end;
  def row: map(cell | gsub("\\|"; "\\|")) | "| " + join(" | ") + " |";
  def table($head; $rows): if ($rows | length) == 0 then "None.", "" else ($head | row), ($head | map("---") | row), ($rows[] | row), "" end;
  def pct: if . == null then null else (. * 1000 | round / 10 | tostring) + "%" end;
  def cores: if . == null then null else (. * 1000 | round / 1000 | tostring) end;
  def mib: if . == null then null else (. / 1048576 | round | tostring) + " MiB" end;
  "# Cloud audit, \(.generated)", "",
  "Projects \(.projects | join(", ")), region \(.region); tacplus-dev/cloud@\(.commit | if . == "" then "unknown" else . end), read as hub-audit. \(if .pipeline != "" then "Pipeline: \(.pipeline)." else "" end)", "",
  (if (.findings | length) > 0 then "**Exposure findings (the job fails):**", "", (.findings[] | "- \(.)"), "" else "No exposure finding.", "" end),
  (if (.errors | length) > 0 then "**Reads that failed (the job fails):**", "", (.errors[] | "- \(.project): \(.what): \(.error)"), "" else empty end),
  (.unavailable | group_by(.why)[] | "Not read, \(.[0].why): \(map("\(.project) \(.what)") | join("; ")).", ""),
  "## Exposure", "",
  "### Ingress open to 0.0.0.0/0", "", table(["project", "rule", "network", "sources", "allows", "targets", "disabled"];
    [.exposure.open_ingress[] | [.project, .name, .network, .sources, .allowed, .target_tags, .disabled]]),
  "### VMs with an external IP", "", table(["project", "VM", "zone", "IPs"]; [.exposure.external_ips[] | [.project, .vm, .zone, .ips]]),
  "### External addresses", "", table(["project", "name", "scope", "address", "status", "users"];
    [.exposure.external_addresses[] | [.project, .name, .scope, .address, .status, .users]]),
  "### Load balancers (forwarding rules)", "", table(["project", "name", "scope", "IP", "protocol", "ports", "scheme", "target"];
    [.exposure.load_balancers[] | [.project, .name, .scope, .ip, .protocol, .ports, .scheme, .target]]),
  "## Inventory", "",
  "### VMs", "", table(["project", "name", "zone", "type", "provisioning", "status", "created"];
    [.inventory.vms[] | [.project, .name, .zone, .machine_type, .provisioning, .status, .created]]),
  "### Node pools", "", table(["project", "cluster", "pool", "machine", "spot", "min", "max", "nodes"];
    [.inventory.node_pools[] | [.project, .cluster, .name, .machine_type, .spot, (if .autoscaling then .min else "fixed" end), (if .autoscaling then .max else "fixed" end), .nodes]]),
  "### Disks by type", "", table(["project", "type", "disks", "GB"]; [.inventory.disks[] | [.project, .type, .count, .gb]]),
  "## Quotas", "", table(["project", "scope", "metric", "usage", "limit"]; [.quotas[] | [.project, .scope, .metric, .usage, .limit]]),
  "## Utilization, \(.utilization.window.start) to \(.utilization.window.end) (the maximum of 10-minute windows)", "",
  "### CPU per VM", "", table(["project", "VM", "zone", "CPU max"]; [.utilization.vms[] | [.project, .vm, .zone, (.cpu_max | pct)]]),
  "### CPU per node (of its allocatable)", "", table(["project", "cluster", "node", "CPU max"]; [.utilization.nodes[] | [.project, .cluster, .node, (.cpu_max | pct)]]),
  "### Containers in namespace ci: used against requested", "", table(["project", "cluster", "pod", "container", "CPU used (cores)", "CPU requested", "memory used", "memory requested"];
    [.utilization.containers[] | [.project, .cluster, .pod, .container, (.cpu_used_max | cores), (.cpu_requested | cores), (.memory_used_max | mib), (.memory_requested | mib)]]),
  "## Scheduling", "",
  "### Spot nodes: requested against allocatable", "", table(["project", "cluster", "pool", "node", "zone", "created", "CPU (cores)", "memory", "pods"];
    [.scheduling.spot_nodes[] | [.project, .cluster, .pool, .node, .zone, .created, "\(.cpu_requested | cores) of \(.cpu_allocatable | cores)",
      "\(.memory_requested / 1048576 | round) of \(.memory_allocatable / 1048576 | round) MiB", (.pods | length)]]),
  "### Pods on the spot nodes", "", table(["project", "node", "pod", "phase", "created", "owner", "CPU requested", "memory requested"];
    [.scheduling.spot_nodes[] | . as $n | .pods[] | [$n.project, $n.node, "\(.namespace)/\(.name)", .phase, .created, .owner, (.cpu_requested | cores), (.memory_requested | mib)]]),
  "### Pods not scheduled", "", table(["project", "cluster", "pod", "created", "owner", "CPU requested", "memory requested", "why"];
    [.scheduling.pending_pods[] | [.project, .cluster, "\(.namespace)/\(.name)", .created, .owner, (.cpu_requested | cores), (.memory_requested | mib), .why]]),
  "## Cluster autoscaler, \(.autoscaler.window.start) to \(.autoscaler.window.end)", "",
  (if .autoscaler.read | not then "Not read: its log view waits on the host'"'"'s grant of roles/logging.configWriter to the pipeline (modules/settings autoscaler_log; README, What the host organization provides).", "" else empty end),
  "### No scale-up, by pool, zone and reason", "", table(["project", "pool", "zone", "reason", "times", "first", "last", "pods left"];
    [.autoscaler.no_scale_up[] | [.project, .pool, .zone, .reason, .count, .first, .last, .pods]]),
  "### Scale-up errors", "", table(["project", "time", "event", "error", "pools tried"];
    [.autoscaler.scale_up_errors[] | [.project, .time, .event_id, .error, [.pools[] | "\(.pool) \(.zone) +\(.requested)"]]]),
  "## Secrets (names and version states only)", "", table(["project", "secret", "versions"];
    [.secrets[] | [.project, .name, [.versions[] | "\(.version) \(.state)"]]])
  ' "$out/audit.json" > "$out/audit.md" || { echo "audit: cannot write its summary" >&2; exit 1; }

cat "$out/audit.md"
jq -e '(.findings | length) == 0 and (.errors | length) == 0' "$out/audit.json" > /dev/null && exit 0
echo "audit: $(jq '.findings | length' "$out/audit.json") exposure finding(s), $(jq '.errors | length' "$out/audit.json") failed read(s): see above" >&2
exit 1
