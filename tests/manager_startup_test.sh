#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the runner manager's startup-script (modules/projects/ci/files/manager-startup.sh, #40) against stubs: a
# metadata server, the bucket and Secret Manager behind a stub curl (tests/stub/manager), and stub systemctl, id and
# useradd, in a scratch root (MANAGER_ROOT). It installs GitLab Runner and the fleeting plugin from the bucket only,
# with the VM's token, each by the SHA-256 its metadata pins; it refuses an object whose SHA-256 is not that one,
# installing nothing; it asks nothing of any other host (no upstream download, no apt); it installs the service as
# upstream's package does; on a reboot with the same pins it fetches nothing; and config.toml gets each pool's token.
# A config pushed to the running manager (#46): its watcher, installed and enabled, re-runs the startup script when
# the metadata changes, and that run rewrites config.toml without restarting gitlab-runner (which reloads it), so no
# job is lost; a new build, or a runner not running, is restarted.
# Needs bash, python3 and sha256sum.
#
#   tests/manager_startup_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/modules/projects/ci/files/manager-startup.sh
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The stub world: the builds (a gitlab-runner that logs its arguments) and the metadata.
stub=$work/stub root=$work/root
mkdir -p "$stub/objects/gitlab-runner" "$stub/objects/fleeting-plugin-googlecloud" "$stub/attributes"
cat > "$work/gitlab-runner" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { echo 'Version:      19.5.3'; exit 0; }
echo "gitlab-runner \$*" >> "$stub/log"
EOF
printf 'plugin build\n' > "$work/plugin"
runner_sha=$(sha256sum "$work/gitlab-runner" | cut -c1-64) plugin_sha=$(sha256sum "$work/plugin" | cut -c1-64)
cp "$work/gitlab-runner" "$stub/objects/gitlab-runner/$runner_sha"
cp "$work/plugin" "$stub/objects/fleeting-plugin-googlecloud/$plugin_sha"
attrs() {
  printf %s tacplus-ci-runner-bin > "$stub/attributes/runner-bucket"
  printf %s "$1" > "$stub/attributes/runner-sha256"
  printf %s "$2" > "$stub/attributes/fleeting-plugin-sha256"
  printf %s 'shared deploy' > "$stub/attributes/runner-pools"
  printf 'concurrent = 1\ntoken = "@TOKEN:shared@"\ntoken = "@TOKEN:deploy@"\n' > "$stub/attributes/runner-config"
}
run() { : > "$stub/calls"; : > "$stub/log"; PATH=$here/tests/stub/manager:$PATH STUB_MANAGER=$stub MANAGER_ROOT=$root bash "$script" > "$work/out" 2>&1; }

attrs "$runner_sha" "$plugin_sha"
run && ok "the startup exits 0" || fail "exit: $(cat "$work/out")"
cmp -s "$root/usr/bin/gitlab-runner" "$work/gitlab-runner" && [ -x "$root/usr/bin/gitlab-runner" ] &&
  cmp -s "$root/usr/local/bin/fleeting-plugin-googlecloud" "$work/plugin" && [ -x "$root/usr/local/bin/fleeting-plugin-googlecloud" ] &&
  ok "both builds installed, executable" || fail "installed: $(ls -lR "$root" 2>&1)"
grep -qxF "GET https://storage.googleapis.com/storage/v1/b/tacplus-ci-runner-bin/o/gitlab-runner%2F$runner_sha?alt=media Bearer vm-token" "$stub/calls" &&
  grep -qxF "GET https://storage.googleapis.com/storage/v1/b/tacplus-ci-runner-bin/o/fleeting-plugin-googlecloud%2F$plugin_sha?alt=media Bearer vm-token" "$stub/calls" &&
  ok "each fetched from the bucket, by its SHA-256, with the VM's token" || fail "calls: $(cat "$stub/calls")"
! grep -vE '^GET (http://metadata\.google\.internal/|https://storage\.googleapis\.com/storage/v1/b/tacplus-ci-runner-bin/o/|https://secretmanager\.googleapis\.com/v1/projects/tacplus-ci/secrets/runner-token-)' "$stub/calls" &&
  ok "nothing asked of any other host (no upstream, no apt)" || fail "other hosts: $(cat "$stub/calls")"
! grep -qE 'apt|dpkg' "$stub/log" && ! grep -qE 'apt-get|dpkg' "$script" && ok "no package installed" || fail "packages: $(cat "$stub/log")"
grep -qxF 'useradd --system --shell /bin/bash --comment GitLab Runner --create-home --skel /dev/null gitlab-runner' "$stub/log" &&
  grep -qxF 'gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner' "$stub/log" &&
  grep -qxF 'systemctl restart gitlab-runner' "$stub/log" && ok "the service set up as upstream's package does, and restarted" ||
  fail "service: $(cat "$stub/log")"
watch=$root/usr/local/sbin/runner-config-watch
[ -x "$watch" ] && grep -qxF "ExecStart=/usr/local/sbin/runner-config-watch" "$root/etc/systemd/system/runner-config-watch.service" &&
  grep -qxF 'systemctl enable --now runner-config-watch.service' "$stub/log" && ok "the metadata watcher installed and enabled" ||
  fail "watcher: $(ls -lR "$root" 2>&1; cat "$stub/log")"
[ "$(cat "$root/etc/gitlab-runner/config.toml")" = "$(printf 'concurrent = 1\ntoken = "glrt-shared-token"\ntoken = "glrt-deploy-token"')" ] &&
  [ "$(stat -c %a "$root/etc/gitlab-runner/config.toml")" = 600 ] && ok "config.toml with each pool's token, 0600" ||
  fail "config: $(cat "$root/etc/gitlab-runner/config.toml")"
! grep -q glrt- "$work/out" && ok "no token printed" || fail "printed: $(cat "$work/out")"

# A reboot: the same pins, the builds already there, the user and the unit too.
touch "$stub/user"; mkdir -p "$root/etc/systemd/system" && touch "$root/etc/systemd/system/gitlab-runner.service"
run && ! grep -q storage.googleapis.com "$stub/calls" && ! grep -qE '^(useradd|gitlab-runner install)' "$stub/log" &&
  grep -qxF 'systemctl restart gitlab-runner' "$stub/log" && ok "a reboot with the same pins fetches and installs nothing again" ||
  fail "reboot: $(cat "$work/out" "$stub/calls" "$stub/log")"

# A config pushed to the running manager (#46): the same pins, gitlab-runner running: config.toml rewritten, nothing
# fetched, gitlab-runner not restarted (it reloads config.toml; its jobs go on).
touch "$stub/active"
printf 'concurrent = 2\ntoken = "@TOKEN:shared@"\ntoken = "@TOKEN:deploy@"\n' > "$stub/attributes/runner-config"
run && [ "$(cat "$root/etc/gitlab-runner/config.toml")" = "$(printf 'concurrent = 2\ntoken = "glrt-shared-token"\ntoken = "glrt-deploy-token"')" ] &&
  [ "$(stat -c %a "$root/etc/gitlab-runner/config.toml")" = 600 ] && ! grep -q storage.googleapis.com "$stub/calls" &&
  ! grep -q 'restart gitlab-runner' "$stub/log" && ok "a config pushed to the running manager: config.toml rewritten, gitlab-runner not restarted" ||
  fail "config push: $(cat "$work/out" "$stub/log")"

# A new build on a running manager: installed and restarted.
cp "$work/gitlab-runner" "$work/gitlab-runner-2" && echo '# 2' >> "$work/gitlab-runner-2"
runner2_sha=$(sha256sum "$work/gitlab-runner-2" | cut -c1-64)
cp "$work/gitlab-runner-2" "$stub/objects/gitlab-runner/$runner2_sha"
attrs "$runner2_sha" "$plugin_sha"
run && cmp -s "$root/usr/bin/gitlab-runner" "$work/gitlab-runner-2" && grep -qxF 'systemctl restart gitlab-runner' "$stub/log" &&
  ok "a new build on a running manager: installed and restarted" || fail "new build: $(cat "$work/out" "$stub/log")"
rm -f "$stub/active"

# The watcher: on a change of the metadata (a new ETag), the startup script again; on none (a wait that times out
# with the same ETag), nothing; each wait from the last ETag seen.
printf 'e1\ne2\ne2\n' > "$stub/etags"; : > "$stub/calls"; : > "$stub/log"
md='http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=true'
PATH=$here/tests/stub/manager:$PATH STUB_MANAGER=$stub RUNNER_WATCH_ROUNDS=2 timeout 20 "$watch" > "$work/out" 2>&1 &&
  [ "$(grep -c . "$stub/log")" = 1 ] && grep -qxF 'systemctl restart google-startup-scripts.service' "$stub/log" &&
  [ "$(cat "$stub/calls")" = "$(printf 'GET %s\nGET %s\nGET %s' "$md" "$md&wait_for_change=true&last_etag=e1&timeout_sec=3600" "$md&wait_for_change=true&last_etag=e2&timeout_sec=3600")" ] &&
  ok "the watcher re-runs the startup script once per change of the metadata" || fail "watch: $(cat "$work/out" "$stub/calls" "$stub/log")"

# The reaper (#49): installed and enabled; each round it lists the groups runner-groups names and deletes a VM creating
# on a capacity or quota error once it has been seen stuck for RUNNER_REAP_AFTER seconds, nothing else: not a VM still
# creating with no error, one failing for another reason, or one running.
reap=$root/usr/local/sbin/runner-reap
[ -x "$reap" ] && grep -qxF "ExecStart=/usr/local/sbin/runner-reap" "$root/etc/systemd/system/runner-reap.service" &&
  ok "the reaper installed" || fail "reaper: $(ls -lR "$root" 2>&1)"
vm() { printf 'https://www.googleapis.com/compute/v1/projects/tacplus-ci/zones/%s/instances/%s' "$1" "$2"; }
mi() { # mi ZONE NAME ACTION [CODE]: a managed instance, as listManagedInstances gives it
  local attempt=''
  [ -z "${4:-}" ] || attempt=$(printf ', "lastAttempt": {"errors": {"errors": [{"code": "%s", "message": "..."}]}}' "$4")
  printf '{"instance": "%s", "currentAction": "%s"%s}' "$(vm "$1" "$2")" "$3" "$attempt"
}
mkdir -p "$stub/compute"
printf 'regions/us-central1/instanceGroupManagers/runner-build zones/us-central1-b/instanceGroupManagers/runner-shared' > "$stub/attributes/runner-groups"
printf '{"managedInstances": [%s, %s, %s]}' "$(mi us-central1-b runner-build-a CREATING ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS)" \
  "$(mi us-central1-a runner-build-b CREATING)" "$(mi us-central1-f runner-build-c NONE)" > "$stub/compute/regions_us-central1_instanceGroupManagers_runner-build.json"
printf '{"managedInstances": [%s, %s]}' "$(mi us-central1-b runner-shared-d CREATING QUOTA_EXCEEDED)" \
  "$(mi us-central1-b runner-shared-e CREATING CONDITION_NOT_MET)" > "$stub/compute/zones_us-central1-b_instanceGroupManagers_runner-shared.json"
reaping() { : > "$stub/calls"; PATH=$here/tests/stub/manager:$PATH STUB_MANAGER=$stub RUNNER_REAP_STATE=$work/reap RUNNER_REAP_ROUNDS=1 timeout 20 "$reap" > "$work/out" 2>&1; }
compute=https://compute.googleapis.com/compute/v1/projects/tacplus-ci
reaping && grep -qxF "POST $compute/regions/us-central1/instanceGroupManagers/runner-build/listManagedInstances Bearer vm-token" "$stub/calls" &&
  grep -qxF "POST $compute/zones/us-central1-b/instanceGroupManagers/runner-shared/listManagedInstances Bearer vm-token" "$stub/calls" &&
  ! grep -q deleteInstances "$stub/calls" && ok "a VM just seen stuck creating is left to its group a while" || fail "first round: $(cat "$work/out" "$stub/calls")"
# The build's stuck VM, first seen long ago: deleted; the shared pool's, seen a round ago only, not yet.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d={k: 0 for k in d}; json.dump(d, open(p, "w"))' "$work/reap/regions_us-central1_instanceGroupManagers_runner-build"
reaping && [ "$(grep -c deleteInstances "$stub/calls")" = 1 ] &&
  grep -qxF "POST $compute/regions/us-central1/instanceGroupManagers/runner-build/deleteInstances Bearer vm-token" "$stub/calls" &&
  grep -qxF "{\"instances\": [\"$(vm us-central1-b runner-build-a)\"], \"skipInstancesOnValidationError\": true}" "$stub/calls" &&
  grep -qF "runner-reap: deleting from regions/us-central1/instanceGroupManagers/runner-build" "$work/out" &&
  ok "a VM stuck creating on a capacity error is deleted, and nothing else" || fail "reap: $(cat "$work/out" "$stub/calls")"
# Gone from its group: forgotten. And a round that cannot list a group goes on to the next.
printf '{"managedInstances": [%s]}' "$(mi us-central1-f runner-build-c NONE)" > "$stub/compute/regions_us-central1_instanceGroupManagers_runner-build.json"
rm "$stub/compute/zones_us-central1-b_instanceGroupManagers_runner-shared.json"
reaping && [ "$(cat "$work/reap/regions_us-central1_instanceGroupManagers_runner-build")" = '{}' ] && ! grep -q deleteInstances "$stub/calls" &&
  grep -qF "runner-reap: cannot list zones/us-central1-b/instanceGroupManagers/runner-shared" "$work/out" &&
  ok "a VM gone from its group is forgotten; a group it cannot list is skipped" || fail "forget: $(cat "$work/out" "$stub/calls")"

# An object that is not the build its name pins: refused, nothing installed, no service started.
rm -rf "$root" "$stub/user"
cp "$work/plugin" "$stub/objects/gitlab-runner/$runner_sha"
attrs "$runner_sha" "$plugin_sha"
! run && grep -qF "gs://tacplus-ci-runner-bin/gitlab-runner/$runner_sha is not the pinned build" "$work/out" &&
  [ ! -e "$root/usr/bin/gitlab-runner" ] && ! grep -q systemctl "$stub/log" && ok "an object that is not its SHA-256: refused, nothing installed" ||
  fail "wrong sha: $(cat "$work/out")"

# A missing pin: refused before any download.
attrs "" "$plugin_sha"
! run && grep -qF 'no SHA-256 pinned for gitlab-runner' "$work/out" && ! grep -q storage.googleapis.com "$stub/calls" &&
  ok "no pin: refused, nothing fetched" || fail "no pin: $(cat "$work/out")"

[ "$failed" = 0 ] || exit 1
