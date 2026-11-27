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
# merger, given looper-env's LOOPER_* settings alone; the merger, which runs no project code, without the container
# socket, and never idle. A check machine's exit 0 is idle: its group stops it (stopInstances, its disk kept), or it
# powers off. The merger's machine is the orchestrator (kick): a check machine whose group runs no VM is started when
# looper-check needed says so (in the looper image, on the host's network, with the cache), its stopped VM started or
# its group sized to 1; one running, not needed, or unreadable is left; one that stopped soon after its start, still
# needed, is started again after a backoff. A check machine that fails five times in a row stops. Needs bash and
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
  PATH=$here/tests/stub/looper-vm:$PATH STUB_LOOPER_VM=$stub LOOPER_VM_ROOT=$root LOOPER_VM_SCRIPT=$script LOOPER_VM_POLL=0 LOOPER_VM_KICK=3600 \
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
expected="docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus -e LOOPER_VM_MR=0 $image looper-vm --repo tacplus"
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

# A reserved machine (#111): the rolling check runs looper-vm check, with the socket (its builds), the cache and its
# app's IDs (looper-env), a line that is no LOOPER_* setting left out.
check_group=projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus
world "$image"
printf %s check > "$stub/attributes/looper-role"
printf %s "$check_group" > "$stub/attributes/looper-group"
printf '%s\n' LOOPER_MANAGER_APP_ID=5632100 LOOPER_MANAGER_INSTALLATION_ID=179024536 'PATH=/evil' 'LOOPER_X=a b' > "$stub/attributes/looper-env"
looper run
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus -e LOOPER_VM_MR=0 -e LOOPER_MANAGER_APP_ID=5632100 -e LOOPER_MANAGER_INSTALLATION_ID=179024536 $image looper-vm check --repo tacplus" "$stub/docker" &&
  grep -qxF "iptables $cutoff" "$stub/iptables" && ok "a rolling check's machine runs looper-vm check with its app's IDs alone, its builds cut off from the metadata server" || fail "the check: exit $rc, docker: $(cat "$stub/docker")"
[ "$rc" = 0 ] && ok "a check machine's exit 0 is idle (every check ended idle)" || fail "a check machine's exit 0: $rc"
looper post
grep -qxF "POST https://compute.googleapis.com/compute/v1/$check_group/stopInstances Bearer vm-token {\"instances\":[\"https://compute.googleapis.com/compute/v1/projects/tacplus-ci/zones/us-central1-b/instances/check-tacplus-x1y2\"]}" "$stub/calls" &&
  ! grep -q 'resize' "$stub/calls" && [ ! -s "$stub/systemctl" ] && ok "idle, a check machine's group stops it, its cache disk kept" || fail "a check machine's idle: $(cat "$stub/calls" "$stub/systemctl")"
world "$image"
printf %s check > "$stub/attributes/looper-role"; printf %s "$check_group" > "$stub/attributes/looper-group"
: > "$stub/resize-fails"
looper run
looper post
grep -qxF "systemctl poweroff --no-block" "$stub/systemctl" && ok "idle, its stop refused: a check machine powers off" || fail "a check machine's stop refused: $(cat "$stub/systemctl")"
world "$image"
printf %s check > "$stub/attributes/looper-role"; printf %s "$check_group" > "$stub/attributes/looper-group"
: > "$stub/preempt"
looper run
looper post
! grep -q stopInstances "$stub/calls" && [ ! -s "$stub/systemctl" ] && ok "a check machine's exit 0 during a stop is not idle" || fail "a check machine's stop: $(cat "$stub/calls")"

# A check machine that fails five times in a row (its identity refused, its image gone) stops rather than run on.
world "$image"
printf %s check > "$stub/attributes/looper-role"; printf %s "$check_group" > "$stub/attributes/looper-group"
echo 3 > "$stub/exit"
for _ in 1 2 3 4; do looper run; run_rc=$rc; looper post; [ "$run_rc" = 3 ] || break; done
[ "$run_rc" = 3 ] && ! grep -q stopInstances "$stub/calls" && ok "a check machine's four failures in a row are systemd's to start again" || fail "four failures: exit $run_rc, $(cat "$stub/calls")"
looper run
run_rc=$rc
looper post
[ "$run_rc" = 0 ] && grep -q "$check_group/stopInstances" "$stub/calls" && ok "its fifth failure in a row stops it" || fail "a fifth failure: exit $run_rc, $(cat "$stub/calls")"
rm -f "$stub/exit"; looper run; looper post; echo 3 > "$stub/exit"; : > "$stub/calls"
looper run
run_rc=$rc
looper post
[ "$run_rc" = 3 ] && ! grep -q stopInstances "$stub/calls" && ok "a check that ends idle starts the count again" || fail "the count after an idle exit: exit $run_rc"

# The merger's machine runs no project code (#111): looper-vm merger, with no container socket, as its app; never idle.
world "$image"
printf '' > "$stub/attributes/looper-repo"; printf %s tacplus-dev > "$stub/attributes/looper-org"; printf %s merger > "$stub/attributes/looper-role"
printf '%s\n' LOOPER_MERGER_KEY=tacplus-manager 'LOOPER_CHECK_LOGIN=tacplus-manager[bot]' > "$stub/attributes/looper-env"
printf '%s\n' "$check_group --repo tacplus" > "$stub/attributes/looper-checks"
looper run
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus-dev -e LOOPER_VM_MR=0 -e LOOPER_MERGER_KEY=tacplus-manager -e LOOPER_CHECK_LOGIN=tacplus-manager[bot] $image looper-vm merger --org tacplus-dev" "$stub/docker" &&
  ok "the merger's machine runs looper-vm merger as its app, with no container socket" || fail "the merger: exit $rc, docker: $(cat "$stub/docker")"
[ "$rc" != 0 ] && ok "the merger's exit 0 is not idle: systemd starts it again" || fail "the merger's exit 0 ended the unit"
looper post
! grep -q -e resize -e Instances "$stub/calls" && ok "the merger's machine never sizes itself down" || fail "the merger resized: $(cat "$stub/calls")"

# The orchestrator (the merger's machine, #111): a kick asks looper-check needed of a check machine that runs no VM, in
# the looper image on the host's network with the cache and the merger's settings, and starts its stopped VM.
# merger_world: the merger's machine, its checks tacplus's machine and the org's (less tacplus), each group at
# SIZE STOPPED (none: a group that cannot be read).
org_group=projects/tacplus-ci/zones/us-central1-b/instanceGroupManagers/check-tacplus-dev
merger_world() {
  world "$image"
  printf '' > "$stub/attributes/looper-repo"; printf %s tacplus-dev > "$stub/attributes/looper-org"; printf %s merger > "$stub/attributes/looper-role"
  printf '%s\n' LOOPER_MERGER_KEY=tacplus-manager > "$stub/attributes/looper-env"
  printf '%s\n' "$check_group --repo tacplus" "$org_group --org tacplus-dev --except tacplus" > "$stub/attributes/looper-checks"
  [ "$1" = none ] || printf '{\n "name": "check-tacplus",\n "targetSize": %s,\n "targetStoppedSize": %s\n}\n' "$1" "$2" > "$stub/group-check-tacplus"
  printf '{\n "name": "check-tacplus-dev",\n "targetSize": 1\n}\n' > "$stub/group-check-tacplus-dev"
  printf '{\n "managedInstances": [\n  {\n   "instance": "https://www.googleapis.com/compute/v1/projects/tacplus-ci/zones/us-central1-b/instances/check-tacplus-x1y2",\n   "instanceStatus": "TERMINATED"\n  }\n ]\n}\n' > "$stub/managed"
}
needed_run="docker run --rm --network host --log-driver=none -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_VM=1 -e LOOPER_FORGE=github -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CHECK_DIR=/var/lib/looper-cache/needed -e LOOPER_MERGER_KEY=tacplus-manager $image bash -c "
merger_world 0 1
echo 0 > "$stub/needed-exit"
looper kick
grep -qF "$needed_run" "$stub/docker" && grep -q ' needed --repo tacplus$' "$stub/docker" && [ "$(grep -c ' needed ' "$stub/docker")" = 1 ] &&
  ok "a kick asks needed of a check machine at 0, in the looper image with the cache, and not of one running" || fail "the kick's question: $(cat "$stub/docker")"
grep -qxF "POST https://compute.googleapis.com/compute/v1/$check_group/startInstances Bearer vm-token {\"instances\":[\"https://www.googleapis.com/compute/v1/projects/tacplus-ci/zones/us-central1-b/instances/check-tacplus-x1y2\"]}" "$stub/calls" &&
  ! grep -q resize "$stub/calls" && ok "needed, the check machine's stopped VM is started (its cache disk with it)" || fail "the start: $(cat "$stub/calls")"
merger_world 0 0
echo 0 > "$stub/needed-exit"
looper kick
grep -qxF "POST https://compute.googleapis.com/compute/v1/$check_group/resize?size=1 Bearer vm-token" "$stub/calls" && ! grep -q startInstances "$stub/calls" &&
  ok "needed, a check machine with no VM yet is sized to 1" || fail "the first VM: $(cat "$stub/calls")"
merger_world 0 1
looper kick
grep -q ' needed --repo tacplus$' "$stub/docker" && ! grep -q -e startInstances -e resize "$stub/calls" && ok "not needed: nothing is started" || fail "not needed: $(cat "$stub/calls")"
merger_world 0 1
echo 2 > "$stub/needed-exit"
looper kick
! grep -q -e startInstances -e resize "$stub/calls" && ok "needed cannot tell: nothing is started" || fail "needed unreadable: $(cat "$stub/calls")"
merger_world none
echo 0 > "$stub/needed-exit"
printf '%s\n' "$check_group --repo tacplus" "$check_group --repo 'x;y'" > "$stub/attributes/looper-checks"
looper kick
! grep -q ' needed ' "$stub/docker" && ! grep -q -e startInstances -e resize "$stub/calls" && ok "a group that cannot be read, or a looper-checks line that is no check machine, is left" || fail "unreadable group: $(cat "$stub/docker" "$stub/calls")"
# A machine that stopped soon after its start, its check still needed, ended without a verdict: it is started again
# once its backoff (15 minutes, doubled each time) has passed since it stopped; a look that finds it not needed ends it.
merger_world 0 1
echo 0 > "$stub/needed-exit"
looper kick
: > "$stub/calls"
looper kick
! grep -q startInstances "$stub/calls" && grep -q 'stopped 0m after its start, its check still needed: started again in 15m' "$work/out" &&
  ok "a check machine that stopped at once, still needed, waits out its backoff" || fail "the backoff: $(cat "$stub/calls")"
kicked=$root/run/looper-vm/kick-check-tacplus
read -r last fails seen < "$kicked"
echo "$((last - 1000)) $fails $((seen - 1000))" > "$kicked"
looper kick
read -r last fails seen < "$kicked"
grep -q startInstances "$stub/calls" && [ "$fails" = 1 ] && ok "its backoff passed, it is started again, the next backoff doubled" || fail "after the backoff: fails $fails, $(cat "$stub/calls")"
echo 1 > "$stub/needed-exit"
looper kick
[ ! -f "$kicked" ] && ok "a look that finds its check not needed ends the backoff" || fail "the backoff record stays: $(cat "$kicked")"
echo "$(($(date +%s) - 3600)) 0 0" > "$kicked"
echo 0 > "$stub/needed-exit"; : > "$stub/calls"
looper kick
read -r last fails seen < "$kicked"
grep -q startInstances "$stub/calls" && [ "$fails" = 0 ] && ok "a machine that ran past its backoff is started at once, no backoff" || fail "a long run: fails $fails, $(cat "$stub/calls")"
merger_world 0 0
echo 0 > "$stub/needed-exit"
printf '{"name": "check-tacplus-dev", "targetSize": 0}' > "$stub/group-check-tacplus-dev"
printf '%s\n' "$org_group --org tacplus-dev --except tacplus" > "$stub/attributes/looper-checks"
looper kick
grep -q ' needed --org tacplus-dev --except tacplus$' "$stub/docker" && grep -qxF "POST https://compute.googleapis.com/compute/v1/$org_group/resize?size=1 Bearer vm-token" "$stub/calls" &&
  ok "the org's check machine is asked for the org less the repositories with their own" || fail "the org's check: $(cat "$stub/docker" "$stub/calls")"
merger_world 0 1
echo 0 > "$stub/needed-exit"
looper run
[ "$rc" = 1 ] && ! grep -q ' needed ' "$stub/docker" && ok "the merger's run starts its orchestrator beside it, and ends it with the container" || fail "the merger's run with checks: exit $rc, $(cat "$stub/docker")"

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
grep -qxF "docker run --rm --name looper-vm --network host --log-driver=gcplogs --log-opt gcp-log-cmd=false -v /var/run/docker.sock:/var/run/docker.sock -v $root/var/lib/looper-cache:/var/lib/looper-cache -e LOOPER_CACHE=/var/lib/looper-cache -e LOOPER_CACHE_HOST=$root/var/lib/looper-cache -e LOOPER_VM_REPO=tacplus-dev -e LOOPER_VM_MR=0 $image looper-vm --org tacplus-dev --except tacplus" "$stub/docker" &&
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
