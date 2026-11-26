#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the looper VM's script (modules/projects/ci/files/looper-vm.sh, #108) against stubs (tests/stub/looper-vm: the
# metadata server and Compute's resize behind a stub curl, docker and systemctl), in a scratch root (LOOPER_VM_ROOT).
# With no image in the metadata, or one not by digest, nothing runs and the VM is not sized down. With one: the cache
# directory is made, or removed and made again when unusable; the image is pulled by its digest, retried a bounded
# number of times (all failed, the run fails, for systemd to start it again, and no container starts); the main
# container runs with the project's name, the cache and the VM's container socket, on the host's network. Its exit 0
# is idle: post resizes the VM's own group (the metadata's looper-group) to 0 with the VM's token, and if that fails
# powers the VM off. A non-zero exit, or an exit 0 during a stop (a spot preemption), is not idle: nothing is resized.
# stop gives the container 25 s. Before any container starts, the containers the main one starts through the socket
# (the builds) are cut off from the VM's metadata server (#111): one iptables rule in DOCKER-USER, made once; if it
# cannot be made, nothing starts. A reserved machine (#111, looper-role check or merger) runs looper-vm check or
# merger; the merger, which runs no project code, without the container socket; neither is ever idle. Needs bash and
# coreutils' timeout.
#
#   tests/looper_vm_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/modules/projects/ci/files/looper-vm.sh
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub=$work/stub root=$work/root
image=ghcr.io/tacplus-dev/looper/looper-vm@sha256:$(printf '%064d' 1)
group=projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/looper-vm-tacplus

# world IMAGE: a fresh VM whose metadata names tacplus, IMAGE and its group.
world() {
  rm -rf "$stub" "$root" && mkdir -p "$stub/attributes" "$root"
  printf %s tacplus > "$stub/attributes/looper-repo"
  printf %s "$1" > "$stub/attributes/looper-image"
  printf %s "$group" > "$stub/attributes/looper-group"
  : > "$stub/calls"; : > "$stub/docker"; : > "$stub/systemctl"; : > "$stub/mount"; : > "$stub/iptables"
}
# looper ARG: the script, as the unit runs it; its status in $rc.
looper() {
  PATH=$here/tests/stub/looper-vm:$PATH STUB_LOOPER_VM=$stub LOOPER_VM_ROOT=$root LOOPER_VM_SCRIPT=$script LOOPER_VM_POLL=0 \
    timeout 60 bash "$script" "$1" >> "$work/out" 2>&1
  rc=$?
}
# The rule that keeps the build containers (Docker's bridge, forwarded through DOCKER-USER) off the metadata server:
# every TCP port but DNS's, which the containers' resolver is.
cutoff="-w -I DOCKER-USER -d 169.254.169.254/32 -p tcp ! --dport 53 -j REJECT --reject-with tcp-reset"
resized() { grep -qxF "POST https://compute.googleapis.com/compute/v1/$group/resize?size=0 Bearer vm-token" "$stub/calls"; }

# No image yet (looper#239): nothing runs, and the group is left as it is.
world ""
looper run
[ "$rc" = 0 ] && [ ! -s "$stub/docker" ] && ok "no image: the run exits 0 and starts no container" || fail "no image: exit $rc, docker: $(cat "$stub/docker")"
looper post
! resized && [ ! -s "$stub/systemctl" ] && ok "no image: the group is not resized, the VM not powered off" || fail "no image: $(cat "$stub/calls" "$stub/systemctl")"

# An image not by digest: refused, nothing runs.
world ghcr.io/tacplus-dev/looper/looper-vm:1.0
looper run
[ "$rc" = 0 ] && [ ! -s "$stub/docker" ] && ok "an image by tag is refused: no pull, no container" || fail "an image by tag: exit $rc, docker: $(cat "$stub/docker")"

# The image runs: pulled by digest, the container with the repo, the cache and the socket; exit 0 is idle.
world "$image"
looper run
expected="docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus $image looper-vm --repo tacplus"
[ "$rc" = 0 ] && grep -qxF "docker pull $image" "$stub/docker" && grep -qxF "$expected" "$stub/docker" &&
  ok "the image is pulled by digest and runs with the repo, the cache and the container socket" || fail "the run: exit $rc, docker: $(cat "$stub/docker")"
[ -d "$root/var/lib/looper-cache" ] && ok "the cache directory is made" || fail "no cache directory"
[ "$(cat "$stub/mount")" = "mountpoint -q $root/var/lib/looper-cache
mount --bind $root/var/lib/looper-cache $root/var/lib/looper-cache
mount -o remount,bind,exec $root/var/lib/looper-cache" ] && ok "the cache is bind-mounted on itself and remounted exec (looper#245)" || fail "the cache mount: $(cat "$stub/mount")"
! grep -qiE 'token|secret|key' "$stub/docker" && ok "the container is given no credential" || fail "a credential on docker's command line: $(cat "$stub/docker")"
grep -qxF "iptables ${cutoff/-I/-C}" "$stub/iptables" && grep -qxF "iptables $cutoff" "$stub/iptables" &&
  ok "the build containers are cut off from the metadata server (#111)" || fail "the metadata cut-off: $(cat "$stub/iptables")"
looper post
resized && [ ! -s "$stub/systemctl" ] && ok "idle: the VM's own group is resized to 0 with the VM's token" || fail "idle: $(cat "$stub/calls" "$stub/systemctl")"

: > "$stub/calls"
looper post
! resized && ok "a second post (a restart's) resizes nothing" || fail "a second post resized again"

# A restart's run finds the rule made: it is not made twice.
world "$image"
: > "$stub/iptables-rule"
looper run
[ "$rc" = 0 ] && ! grep -q -- ' -I ' "$stub/iptables" && grep -q '^docker run ' "$stub/docker" && ok "the cut-off made already is not made again" || fail "the cut-off again: $(cat "$stub/iptables")"

# The cut-off cannot be made: nothing starts, and systemd tries again (#111: build containers must not reach it).
world "$image"
: > "$stub/iptables-fails"
looper run
[ "$rc" = 1 ] && ! grep -q '^docker run ' "$stub/docker" && ok "no cut-off: no container, the run fails" || fail "no cut-off: exit $rc, docker: $(cat "$stub/docker")"
looper post
! resized && ok "no cut-off is not idle" || fail "no cut-off resized the group"

# A reserved machine (#111): the rolling check runs looper-vm check, with the socket (its builds) and the cache.
world "$image"
printf %s check > "$stub/attributes/looper-role"
looper run
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus $image looper-vm check --repo tacplus" "$stub/docker" &&
  grep -qxF "iptables $cutoff" "$stub/iptables" && ok "a rolling check's machine runs looper-vm check, its builds cut off from the metadata server" || fail "the check: exit $rc, docker: $(cat "$stub/docker")"
[ "$rc" != 0 ] && ok "a reserved machine's exit 0 is not idle: systemd starts it again" || fail "a reserved machine's exit 0 ended the unit"
looper post
! resized && [ ! -s "$stub/systemctl" ] && ok "a reserved machine never sizes itself down" || fail "a reserved machine resized: $(cat "$stub/calls" "$stub/systemctl")"

# The merger's machine runs no project code (#111): looper-vm merger, with no container socket.
world "$image"
printf '' > "$stub/attributes/looper-repo"; printf %s tacplus-dev > "$stub/attributes/looper-org"; printf %s merger > "$stub/attributes/looper-role"
looper run
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus-dev $image looper-vm merger --org tacplus-dev" "$stub/docker" &&
  ok "the merger's machine runs looper-vm merger, with no container socket" || fail "the merger: exit $rc, docker: $(cat "$stub/docker")"
looper post
! resized && ok "the merger's machine never sizes itself down" || fail "the merger resized"

# A role it does not know: nothing runs.
world "$image"
printf %s build > "$stub/attributes/looper-role"
looper run
[ "$rc" = 0 ] && ! grep -q '^docker run ' "$stub/docker" && ok "an unknown looper-role runs nothing" || fail "an unknown role: exit $rc, docker: $(cat "$stub/docker")"

# An org's shared VM (decision point 12): looper-org and looper-except, no looper-repo: the parent works the org but
# the repositories with a VM of their own. An org VM that also names a repository is refused.
world "$image"
printf '' > "$stub/attributes/looper-repo"; printf %s tacplus-dev > "$stub/attributes/looper-org"; printf %s tacplus > "$stub/attributes/looper-except"
looper run
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus-dev $image looper-vm --org tacplus-dev --except tacplus" "$stub/docker" &&
  ok "an org's shared VM runs looper-vm --org, less the repositories with their own VM" || fail "the org VM: exit $rc, docker: $(cat "$stub/docker")"
world "$image"
printf %s tacplus-dev > "$stub/attributes/looper-org"
looper run
[ "$rc" = 0 ] && ! grep -q '^docker run ' "$stub/docker" && ok "an org VM that names a repository too runs nothing" || fail "org and repo: exit $rc, docker: $(cat "$stub/docker")"

# The resize fails: the VM powers off, it does not loop.
world "$image"
: > "$stub/resize-fails"
looper run
looper post
[ "$rc" = 0 ] && grep -qxF "systemctl poweroff --no-block" "$stub/systemctl" && ok "idle, the resize refused: the VM powers off" || fail "resize refused: exit $rc, $(cat "$stub/systemctl")"

# A failure is not idle: systemd starts it again (Restart=on-failure), nothing is resized.
world "$image"
echo 3 > "$stub/exit"
looper run
[ "$rc" = 3 ] && ok "the container's failure is the run's" || fail "a failure: exit $rc"
looper post
! resized && ok "a failure resizes nothing" || fail "a failure resized the group"

# A spot preemption: the unit's stop during the run; the container's exit 0 is not idle.
world "$image"
: > "$stub/preempt"
looper run
grep -qxF "docker stop -t 25 looper-vm" "$stub/docker" && ok "a stop gives the container 25 s after its SIGTERM" || fail "the stop: $(cat "$stub/docker")"
looper post
! resized && [ ! -s "$stub/systemctl" ] && ok "a preemption's exit 0 is not idle: the group stays at 1, which recreates the VM" || fail "a preemption resized the group: $(cat "$stub/calls")"

# The pull is retried, bounded.
world "$image"
echo 2 > "$stub/pull-fails"
looper run
[ "$rc" = 0 ] && [ "$(grep -c '^docker pull ' "$stub/docker")" = 3 ] && grep -q '^docker run ' "$stub/docker" && ok "two failed pulls, the third runs" || fail "retried pull: exit $rc, $(cat "$stub/docker")"
world "$image"
echo 99 > "$stub/pull-fails"
looper run
[ "$rc" = 1 ] && [ "$(grep -c '^docker pull ' "$stub/docker")" = 5 ] && ! grep -q '^docker run ' "$stub/docker" && ok "five failed pulls: the run fails, no container" || fail "failed pulls: exit $rc, $(cat "$stub/docker")"

# An unusable cache is removed and made again, never waited on.
world "$image"
mkdir -p "$root/var/lib" && echo junk > "$root/var/lib/looper-cache"
looper run
[ "$rc" = 0 ] && [ -d "$root/var/lib/looper-cache" ] && grep -q '^docker run ' "$stub/docker" && ok "a cache that is no directory is made again, and the container runs" || fail "unusable cache: exit $rc"
world "$image"
mkdir -p "$root/var/lib/looper-cache/cargo" && echo kept > "$root/var/lib/looper-cache/cargo/x"
looper run
[ "$(cat "$root/var/lib/looper-cache/cargo/x" 2>/dev/null)" = kept ] && ok "a usable cache is kept" || fail "a usable cache was not kept"

[ "$failed" = 0 ] || { echo "--- output"; cat "$work/out"; }
exit "$failed"
