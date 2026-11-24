#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper VM's one script (#108; tacplus-dev/roadmap decisions/looper-build-vms-2026-11-24.md, point 10), the same
# for every project: files/looper-vm-cloud-init.yaml writes it and the unit looper-vm.service that runs it. It decides
# no work. What differs between projects is only the VM's metadata, which the ci stack writes from looper_vms:
# looper-repo (the tacplus-dev repository), looper-image (the looper-vm image, by digest; empty, nothing runs) and
# looper-group (the VM's own instance group, by resource name). No secret is in the metadata or here: the container
# fetches its own credentials as the VM's service account.
#
#   looper-vm.sh run    ExecStart: the cache directory, made usable or made again, never waited on (point 3); the
#                       image pulled by its digest, bounded retries; then the main container, with the project's name,
#                       the cache and the VM's container socket (point 5), in the foreground. Its exit is the unit's:
#                       non-zero, systemd starts it again (Restart=on-failure); 0, it found no work, and the VM is idle.
#   looper-vm.sh stop   ExecStop: a stop asked of the unit (a spot preemption's shutdown, about 30 s): marks it, so
#                       that the container's exit is not taken for idle, and gives the container 25 s after its SIGTERM
#                       to push its checkpoints (TimeoutStopSec=30).
#   looper-vm.sh post   ExecStopPost: after an idle exit alone, resizes the VM's own group to 0 through the Compute
#                       API, with the VM's token (its account's one grant there, on that group alone): the group
#                       deletes the VM, and the project costs nothing until the kicker sizes it to 1 again. If that
#                       call fails, it says so and powers the VM off: it never loops or waits on it.
#
# LOOPER_VM_ROOT, empty on the VM, is where tests/looper_vm_test.sh keeps the cache and the run directory instead of
# /; LOOPER_VM_POLL, 10 on the VM, the seconds between a failed pull and the next (times the try).
set -uo pipefail
root=${LOOPER_VM_ROOT:-} poll=${LOOPER_VM_POLL:-10}
md=http://metadata.google.internal/computeMetadata/v1
cache=$root/var/lib/looper-cache
state=$root/run/looper-vm
log() { echo "looper-vm: $*"; }

# metadata KEY: an attribute of the VM, empty when it has none.
metadata() { curl -sf --max-time 10 --retry 3 -H 'Metadata-Flavor: Google' "$md/instance/attributes/$1" || true; }

# The cache is only a cache (point 3): a directory that is not one, or cannot be written, is removed and made again;
# if even that fails, the container starts without it, cold. Never repaired by hand, never waited on.
cache_ready() {
  local probe=$cache/.looper-vm-probe
  if mkdir -p "$cache" 2>/dev/null && : > "$probe" 2>/dev/null && rm -f "$probe"; then return 0; fi
  log "the cache $cache is unusable: removed and made again"
  rm -rf "$cache" 2>/dev/null
  if mkdir -p "$cache" 2>/dev/null && : > "$probe" 2>/dev/null && rm -f "$probe"; then return 0; fi
  log "the cache $cache cannot be made: the container starts cold"
}

run() {
  local repo image try
  mkdir -p "$state" && rm -f "$state/stopping" "$state/idle"
  repo=$(metadata looper-repo) image=$(metadata looper-image)
  if [ -z "$image" ]; then
    log "no looper-image in the metadata: nothing to run (the group stays as the kicker sized it)"
    return 0
  fi
  if ! [[ $repo =~ ^[a-z0-9][a-z0-9._-]*$ ]] || ! [[ $image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
    log "looper-repo [$repo] is not a repository's name, or looper-image [$image] is not an image by digest: nothing runs"
    return 0
  fi
  cache_ready
  for try in 1 2 3 4 5; do
    timeout 600 docker pull "$image" && break
    [ "$try" = 5 ] && { log "cannot pull $image after $try tries: systemd tries again"; return 1; }
    log "pull $try of $image failed: again in $((try * poll)) s"
    sleep $((try * poll))
  done
  docker rm -f looper-vm >/dev/null 2>&1
  log "starting $image for $repo"
  docker run --rm --name looper-vm --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$cache:/var/lib/looper-cache" \
    -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST="$cache" -e LOOPER_VM_REPO="$repo" \
    "$image" looper-vm --repo "$repo"
  local rc=$?
  if [ "$rc" = 0 ] && [ ! -f "$state/stopping" ]; then
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
  local group token
  group=$(metadata looper-group)
  token=$(curl -sf --max-time 10 --retry 3 -H 'Metadata-Flavor: Google' "$md/instance/service-accounts/default/token" |
    sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [[ $group =~ ^projects/[a-z0-9-]+/zones/[a-z0-9-]+/instanceGroupManagers/[a-z0-9-]+$ ]] && [ -n "$token" ] &&
    curl -sf --max-time 30 --retry 3 -X POST -H "Authorization: Bearer $token" -H 'Content-Length: 0' \
      "https://compute.googleapis.com/compute/v1/$group/resize?size=0" >/dev/null; then
    log "idle: $group resized to 0, which deletes this VM"
  else
    log "idle, but $group could not be resized to 0: powering off"
    systemctl poweroff --no-block
  fi
  return 0
}

case ${1:-} in
  run) run ;;
  stop) stop ;;
  post) post ;;
  *) echo "usage: looper-vm.sh run|stop|post" >&2; exit 2 ;;
esac
