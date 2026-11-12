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
[ "$(cat "$root/etc/gitlab-runner/config.toml")" = "$(printf 'concurrent = 1\ntoken = "glrt-shared-token"\ntoken = "glrt-deploy-token"')" ] &&
  [ "$(stat -c %a "$root/etc/gitlab-runner/config.toml")" = 600 ] && ok "config.toml with each pool's token, 0600" ||
  fail "config: $(cat "$root/etc/gitlab-runner/config.toml")"
! grep -q glrt- "$work/out" && ok "no token printed" || fail "printed: $(cat "$work/out")"

# A reboot: the same pins, the builds already there, the user and the unit too.
touch "$stub/user"; mkdir -p "$root/etc/systemd/system" && touch "$root/etc/systemd/system/gitlab-runner.service"
run && ! grep -q storage.googleapis.com "$stub/calls" && ! grep -qE '^(useradd|gitlab-runner install)' "$stub/log" &&
  grep -qxF 'systemctl restart gitlab-runner' "$stub/log" && ok "a reboot with the same pins fetches and installs nothing again" ||
  fail "reboot: $(cat "$work/out" "$stub/calls" "$stub/log")"

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
