#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper VM's one script (#108; tacplus-dev/roadmap decisions/looper-build-vms-2026-11-24.md, point 10), the same
# for every project: files/looper-vm-cloud-init.yaml writes it and the unit looper-vm.service that runs it. It decides
# no work. What differs between projects is only the VM's metadata, which the ci stack writes from looper_vms:
# looper-repo (the tacplus-dev repository), or for an org's shared VM (decision point 12) looper-org and looper-except
# (the repositories with a VM of their own, NAME,...), looper-image (the looper-vm image, by digest; empty, nothing
# runs) and looper-group (the VM's own instance group, by resource name); and for a reserved machine (#111,
# reserved-vms.tf) looper-role: check, the rolling check of main (looper-vm check), or merger, the merger (looper-vm
# merger), which runs no project code and so gets no container socket; looper-env, the settings its container is given
# (NAME=VALUE a line, LOOPER_* alone: its GitHub App's IDs, the check's login), and for the merger looper-checks, the
# check machines it starts (GROUP --repo NAME, or GROUP --org ORG [--except NAME,...], a line). No secret is in the
# metadata or here: the container fetches its own credentials as the VM's service account.
#
#   looper-vm.sh run    ExecStart: the cache directory, made usable or made again, never waited on (point 3); the
#                       containers the main one starts through the socket (its builds, on Docker's bridge) cut off
#                       from the VM's metadata server, and so from the VM's account (#111), or nothing starts; the
#                       image pulled by its digest, bounded retries; then the main container, with the project's name,
#                       the cache and the VM's container socket (point 5), in the foreground. Its exit is the unit's:
#                       non-zero, systemd starts it again (Restart=on-failure); 0, it found no work, and the VM is idle,
#                       a check machine's too (every check ended idle: Jody, 2026-11-25, builders run only while used);
#                       the merger's 0 is a failure, started again: it is the one always-on machine. The merger's
#                       machine is the check machines' orchestrator too: every LOOPER_VM_KICK seconds, a kick.
#   looper-vm.sh kick   The orchestrator's pass (the merger's machine): each check machine of looper-checks whose group
#                       runs no VM is started when its check is needed (`looper-check needed` of its repositories, in
#                       the looper image, as the merger's app): its stopped VM started, its cache disk with it, or its
#                       group sized to 1 when it has none. What it cannot read, it says, and starts nothing.
#   looper-vm.sh stop   ExecStop: a stop asked of the unit (a spot preemption's shutdown, about 30 s): marks it, so
#                       that the container's exit is not taken for idle, and gives the container 25 s after its SIGTERM
#                       to push its checkpoints (TimeoutStopSec=30).
#   looper-vm.sh post   ExecStopPost: after an idle exit alone, resizes the VM's own group to 0 through the Compute
#                       API, with the VM's token (its account's one grant there, on that group alone): the group
#                       deletes the VM, and the project costs nothing until the kicker sizes it to 1 again. A check
#                       machine's group stops its VM instead (stopInstances): its boot disk, the cache, is kept for
#                       the next check, and nothing but the disk costs until the merger's machine starts it. If that
#                       call fails, it says so and powers the VM off: it never loops or waits on it.
#
# LOOPER_VM_ROOT, empty on the VM, is where tests/looper_vm_test.sh keeps the cache and the run directory instead of
# /; LOOPER_VM_POLL, 10 on the VM, the seconds between a failed pull and the next (times the try); LOOPER_VM_KICK, 60
# on the VM, the seconds between the orchestrator's kicks.
set -uo pipefail
root=${LOOPER_VM_ROOT:-} poll=${LOOPER_VM_POLL:-10} kick_every=${LOOPER_VM_KICK:-60}
md=http://metadata.google.internal/computeMetadata/v1
compute=https://compute.googleapis.com/compute/v1
cache=$root/var/lib/looper-cache
state=$root/run/looper-vm
log() { echo "looper-vm: $*"; }

# metadata KEY: an attribute of the VM, empty when it has none.
metadata() { curl -sf --max-time 10 --retry 3 -H 'Metadata-Flavor: Google' "$md/instance/attributes/$1" || true; }

# The VM's account's access token, empty when the metadata server gives none.
vm_token() {
  curl -sf --max-time 10 --retry 3 -H 'Metadata-Flavor: Google' "$md/instance/service-accounts/default/token" |
    sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# envs: looper-env's settings as docker's -e arguments, in env; a line that is no LOOPER_* setting is left out, said.
envs() {
  local line re='^LOOPER_[A-Z0-9_]+=[]A-Za-z0-9._/@:[-]*$'
  env=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ $line =~ $re ]]; then env+=(-e "$line"); else log "looper-env [$line] is no LOOPER_* setting: left out"; fi
  done <<< "$(metadata looper-env)"
}

# The cache is only a cache (point 3): a directory that is not one, or cannot be written, is removed and made again;
# if even that fails, the container starts without it, cold. Never repaired by hand, never waited on.
cache_ready() {
  local probe=$cache/.looper-vm-probe
  if mkdir -p "$cache" 2>/dev/null && : > "$probe" 2>/dev/null && rm -f "$probe"; then cache_exec; return 0; fi
  log "the cache $cache is unusable: removed and made again"
  rm -rf "$cache" 2>/dev/null
  if mkdir -p "$cache" 2>/dev/null && : > "$probe" 2>/dev/null && rm -f "$probe"; then cache_exec; return 0; fi
  log "the cache $cache cannot be made: the container starts cold"
}

# The build containers never reach the metadata server (#111; the panel's finding 5): it hands out the VM's account's
# tokens, which sign with its GitHub App's key and read its secrets. They run on Docker's bridge, so their packets
# to it are forwarded through DOCKER-USER, where one rule refuses every TCP port of it but DNS's (it is their
# resolver too); the main container, on the host's network, still reaches it. Made once a boot (a restart's run
# finds it); if it cannot be made, nothing starts.
metadata_cutoff() {
  local rule=(DOCKER-USER -d 169.254.169.254/32 -p tcp ! --dport 53 -j REJECT --reject-with tcp-reset)
  iptables -w -C "${rule[@]}" 2>/dev/null || iptables -w -I "${rule[@]}"
}

# COS mounts /var noexec, and the build containers run what they cache there (Go keeps each `go run` binary in its
# GOCACHE, looper#245): the cache is bind-mounted on itself, once a boot, and that mount remounted exec. If that
# fails it says so; the container still starts.
cache_exec() {
  if ! { mountpoint -q "$cache" || mount --bind "$cache" "$cache"; } || ! mount -o remount,bind,exec "$cache"; then
    log "the cache $cache could not be made exec: a build that runs a cached binary fails"
  fi
}

run() {
  local repo org except image role try work env=() kicker='' socket=(-v /var/run/docker.sock:/var/run/docker.sock)
  mkdir -p "$state" && rm -f "$state/stopping" "$state/idle"
  repo=$(metadata looper-repo) org=$(metadata looper-org) except=$(metadata looper-except) image=$(metadata looper-image)
  role=$(metadata looper-role)
  if [ -z "$image" ]; then
    log "no looper-image in the metadata: nothing to run (the group stays as the kicker sized it)"
    return 0
  fi
  if ! [[ $image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
    log "looper-image [$image] is not an image by digest: nothing runs"
    return 0
  fi
  if [ -n "$org" ]; then
    if ! [[ $org =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ! [[ $except =~ ^([a-z0-9][a-z0-9._-]*(,[a-z0-9][a-z0-9._-]*)*)?$ ]] || [ -n "$repo" ]; then
      log "looper-org [$org] with looper-except [$except] and looper-repo [$repo] is not an org's shared VM: nothing runs"
      return 0
    fi
    work=(--org "$org"); [ -z "$except" ] || work+=(--except "$except")
  elif [[ $repo =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    work=(--repo "$repo")
  else
    log "looper-repo [$repo] is not a repository's name: nothing runs"
    return 0
  fi
  case $role in
    '') ;;
    check) work=(check "${work[@]}") ;;
    merger) work=(merger "${work[@]}") socket=() ;;
    *) log "looper-role [$role] is none of check and merger: nothing runs"; return 0 ;;
  esac
  [ -z "$role" ] || envs
  cache_ready
  if ! metadata_cutoff; then
    log "the build containers could not be cut off from the metadata server: nothing starts, systemd tries again"
    return 1
  fi
  for try in 1 2 3 4 5; do
    timeout 600 docker pull "$image" && break
    [ "$try" = 5 ] && { log "cannot pull $image after $try tries: systemd tries again"; return 1; }
    log "pull $try of $image failed: again in $((try * poll)) s"
    sleep $((try * poll))
  done
  docker rm -f looper-vm >/dev/null 2>&1
  if [ "$role" = merger ] && [ -n "$(metadata looper-checks)" ]; then
    orchestrate &
    kicker=$!
  fi
  log "starting $image for ${work[*]}"
  # LOOPER_VM_MR=0: a report's --land still queues with the manager. The looper's merge requests (looper#250) are
  # merged by nobody until the merger and the rolling check are live together (tacplus-dev/roadmap
  # decisions/agentic-dev-flow-2026-11-25.md); this goes when they are.
  # Docker's gcplogs driver sends the container's output to Cloud Logging as it is written (the VM's account is a
  # logWriter): with --rm, a container that dies at once took its log with it before the agent read it.
  docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false \
    "${socket[@]}" \
    -v "$cache:/var/lib/looper-cache" \
    -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST="$cache" -e LOOPER_VM_REPO="${repo:-$org}" \
    -e LOOPER_VM_MR=0 "${env[@]}" \
    "$image" looper-vm "${work[@]}"
  local rc=$?
  [ -z "$kicker" ] || kill "$kicker" 2>/dev/null
  if [ "$rc" = 0 ] && [ "$role" = merger ] && [ ! -f "$state/stopping" ]; then
    log "the container exited 0: the merger's machine is never idle, systemd starts it again"
    return 1
  elif [ "$rc" = 0 ] && [ ! -f "$state/stopping" ]; then
    log "the container exited 0: idle"
    : > "$state/idle"
  else
    log "the container exited $rc$([ -f "$state/stopping" ] && echo ', on a stop')"
  fi
  return "$rc"
}

stop() {
  mkdir -p "$state" && : > "$state/stopping"
  docker stop -t 25 looper-vm >/dev/null 2>&1
  return 0
}

post() {
  [ -f "$state/idle" ] || return 0
  rm -f "$state/idle"
  local group token name
  group=$(metadata looper-group)
  token=$(vm_token)
  if [ "$(metadata looper-role)" = check ]; then
    name=$(curl -sf --max-time 10 --retry 3 -H 'Metadata-Flavor: Google' "$md/instance/name" || true)
    if [[ $group =~ ^projects/[a-z0-9-]+/zones/[a-z0-9-]+/instanceGroupManagers/[a-z0-9-]+$ ]] && [[ $name =~ ^[a-z][a-z0-9-]*$ ]] &&
      [ -n "$token" ] && curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"instances\":[\"$compute/${group%/instanceGroupManagers/*}/instances/$name\"]}" "$compute/$group/stopInstances" >/dev/null; then
      log "idle: $group stops this VM, its cache disk kept"
    else
      log "idle, but $group could not stop this VM: powering off"
      systemctl poweroff --no-block
    fi
    return 0
  fi
  if [[ $group =~ ^projects/[a-z0-9-]+/zones/[a-z0-9-]+/instanceGroupManagers/[a-z0-9-]+$ ]] && [ -n "$token" ] &&
    curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' \
      "$compute/$group/resize?size=0" >/dev/null; then
    log "idle: $group resized to 0, which deletes this VM"
  else
    log "idle, but $group could not be resized to 0: powering off"
    systemctl poweroff --no-block
  fi
  return 0
}

# Run in the looper image by kick, as the merger's app: exit 0 when the check of one of the repositories (--repo NAME,
# or --org ORG [--except NAME,...]: its unarchived ones less those) is needed, 1 when none is, 2 when it cannot tell.
needed_script='set -u
GH_TOKEN=$(looper-token mint merger) || { echo "no token of the merger (looper-token mint merger)"; exit 2; }
export GH_TOKEN
if [ "$1" = --repo ]; then
  repos=$2
else
  export LOOPER_ORG=$2
  repos=$(gh repo list "$2" --no-archived --source --limit 1000 --json name --jq ".[].name") || { echo "the repositories of $2 cannot be listed"; exit 2; }
  for x in $(echo "${4:-}" | tr , " "); do repos=$(printf "%s\n" $repos | grep -vxF "$x"); done
fi
rc=1
for r in $repos; do
  looper-check needed --repo "$r"; c=$?
  [ "$c" = 0 ] && exit 0
  [ "$c" = 1 ] || rc=2
done
exit "$rc"'

# field NAME JSON: a whole-number field of Compute's answer, 0 when it has none.
field() { local v; v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([0-9]*\).*/\1/p" <<< "$2" | head -n 1); echo "${v:-0}"; }

# One pass of the orchestrator, on the merger's machine (#111; Jody, 2026-11-25: "If we need a manager then we run a
# very small orchestrator"): each check machine whose group runs no VM is asked for (looper-check needed) and, when
# needed, started: its stopped VM (startInstances), which keeps its cache disk, or a first one (resize to 1). Its
# account's one grant in Compute is that, on the check machines' groups alone.
kick() {
  local image token group args g stopped vm env=() rc
  image=$(metadata looper-image)
  [[ $image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || return 0
  envs
  mkdir -p "$state"
  while read -r group args; do
    [ -n "$group" ] || continue
    if ! [[ $group =~ ^projects/[a-z0-9-]+/zones/[a-z0-9-]+/instanceGroupManagers/[a-z0-9-]+$ ]] ||
      ! [[ $args =~ ^(--repo\ [a-z0-9][a-z0-9._-]*|--org\ [A-Za-z0-9][A-Za-z0-9._-]*(\ --except\ [a-z0-9][a-z0-9._-]*(,[a-z0-9][a-z0-9._-]*)*)?)$ ]]; then
      log "kick: looper-checks [$group $args] is no check machine: skipped"
      continue
    fi
    token=$(vm_token)
    if [ -z "$token" ] || ! g=$(curl -sf --max-time 30 --retry 3 -H "Authorization: Bearer $token" "$compute/$group"); then
      log "kick: $group cannot be read: not started"
      continue
    fi
    [ "$(field targetSize "$g")" = 0 ] || continue
    stopped=$(field targetStoppedSize "$g")
    # shellcheck disable=SC2086 # args: --repo NAME, or --org ORG [--except NAME,...], checked above
    docker run --rm --network host --log-driver=none -v "$cache:/var/lib/looper-cache" -e LOOPER_VM=1 -e LOOPER_FORGE=github \
      -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CHECK_DIR=/var/lib/looper-cache/needed "${env[@]}" \
      "$image" bash -c "$needed_script" needed $args > "$state/needed.log" 2>&1
    rc=$?
    log "kick: ${group##*/}: $(tail -n 1 "$state/needed.log" | cut -c1-300)"
    [ "$rc" = 0 ] || continue
    if [ "$stopped" != 0 ]; then
      vm=$(curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' "$compute/$group/listManagedInstances" |
        sed -n 's/.*"instance"[[:space:]]*:[[:space:]]*"\(https:[^"]*\)".*/\1/p' | head -n 1)
      if [ -n "$vm" ] && curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "{\"instances\":[\"$vm\"]}" "$compute/$group/startInstances" >/dev/null; then
        log "kick: ${group##*/}: its stopped VM ${vm##*/} started"
      else
        log "kick: ${group##*/}: its stopped VM could not be started"
      fi
    elif curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' "$compute/$group/resize?size=1" >/dev/null; then
      log "kick: ${group##*/}: sized to 1"
    else
      log "kick: ${group##*/}: could not be sized to 1"
    fi
  done <<< "$(metadata looper-checks)"
  return 0
}

# The orchestrator, beside the merger's container: a kick every LOOPER_VM_KICK seconds until the run ends it.
orchestrate() {
  local s
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  while :; do
    sleep "$kick_every" & s=$!
    wait "$s"
    kick
  done
}

case ${1:-} in
  run) run ;;
  stop) stop ;;
  post) post ;;
  kick) kick ;;
  *) echo "usage: looper-vm.sh run|stop|post|kick" >&2; exit 2 ;;
esac
