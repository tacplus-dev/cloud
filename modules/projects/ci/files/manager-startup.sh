#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The startup-script of the runner manager (modules/projects/ci). It installs GitLab Runner and the googlecloud
# fleeting plugin, our arm64 builds (ci/runner.sh, #40), from the bucket the VM's metadata names (runner-bucket), which
# only the manager's account reads, with the VM's token: each object is named by its SHA-256 and refused unless it has
# the one the metadata pins. Nothing comes from upstream, and no package is installed: gitlab-runner's service is the
# one upstream's package sets up, its user and its unit (gitlab-runner install). Then config.toml (metadata
# runner-config) with each pool's token from Secret Manager (runner-token-<pool>, its only enabled version: the gitlab
# stack replaces it when it re-registers a runner), and gitlab-runner restarted. Until a pool's token exists (the
# gitlab stack has not run yet), it waits for it. Nothing here prints a token.
#
# The config is pushed to the running manager, not by replacing it (#46): the ci stack updates the metadata in place,
# and runner-config-watch, a unit this script installs, re-runs this script (google-startup-scripts.service) when the
# metadata changes. That run rewrites config.toml, which gitlab-runner reloads by itself, its jobs untouched: it is
# restarted only on a new build, or when it is not running.
#
# MANAGER_ROOT, empty on the VM, is where tests/manager_startup_test.sh installs instead of /.
set -Eeuo pipefail
root=${MANAGER_ROOT:-}
md() { curl -fsS -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1"; }
attr() { md "instance/attributes/$1"; }
say() { echo "manager-startup: $*"; }
die() { say "$*" >&2; exit 1; }
# access: the VM's access token (the manager's account), on stdout.
access() { md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'; }

project=$(md project/project-id)
bucket=$(attr runner-bucket)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# get NAME SHA256 PATH: the bucket's object NAME/SHA256 installed at PATH, refused unless its SHA-256 is SHA256; nothing
# fetched if PATH already is that build (a reboot, a config pushed). installed is set when it installs one.
installed=''
get() {
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "no SHA-256 pinned for $1"
  if [ -f "$root$3" ] && echo "$2  $root$3" | sha256sum -c --quiet - >/dev/null 2>&1; then return; fi
  curl -fsSL --retry 3 -H @<(printf 'Authorization: Bearer %s\n' "$(access)") -o "$tmp/$1" \
    "https://storage.googleapis.com/storage/v1/b/$bucket/o/$1%2F$2?alt=media" || die "cannot download $1/$2 from gs://$bucket"
  echo "$2  $tmp/$1" | sha256sum -c --quiet - || die "gs://$bucket/$1/$2 is not the pinned build"
  install -D -m 0755 "$tmp/$1" "$root$3"
  installed=1
  say "$1 installed, SHA-256 $2"
}
get gitlab-runner "$(attr runner-sha256)" /usr/bin/gitlab-runner
get fleeting-plugin-googlecloud "$(attr fleeting-plugin-sha256)" /usr/local/bin/fleeting-plugin-googlecloud

# The service as upstream's package's post-install sets it up: its user, and the unit gitlab-runner writes.
id -u gitlab-runner >/dev/null 2>&1 ||
  useradd --system --shell /bin/bash --comment 'GitLab Runner' --create-home --skel /dev/null gitlab-runner
[ -f "$root/etc/systemd/system/gitlab-runner.service" ] ||
  "$root/usr/bin/gitlab-runner" install --user=gitlab-runner --working-directory=/home/gitlab-runner

# The watcher (#46): each change of the metadata runs this script again. The guest agent's metadata server answers a
# wait_for_change when the attributes' ETag differs from the last one seen, or at its timeout with the same one.
install -d "$root/usr/local/sbin" "$root/etc/systemd/system"
cat > "$root/usr/local/sbin/runner-config-watch" <<'WATCH'
#!/bin/bash
# The runner manager's metadata watcher (tacplus-dev/cloud modules/projects/ci/files/manager-startup.sh, #46): when the
# metadata changes (the ci stack pushes a config in place), the startup script again, which rewrites config.toml.
# RUNNER_WATCH_ROUNDS, empty on the VM, is how many waits tests/manager_startup_test.sh lets it make.
set -uo pipefail
url='http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=true'
etag() { curl -fsS -o /dev/null -D - -H Metadata-Flavor:Google "$1" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p'; }
rounds=${RUNNER_WATCH_ROUNDS:-0} n=0
until last=$(etag "$url") && [ -n "$last" ]; do sleep 10; done
while [ "$rounds" = 0 ] || [ "$n" -lt "$rounds" ]; do
  n=$((n + 1))
  now=$(etag "$url&wait_for_change=true&last_etag=$last&timeout_sec=3600") && [ -n "$now" ] || { sleep 10; continue; }
  [ "$now" = "$last" ] && continue
  last=$now
  echo "runner-config-watch: the metadata changed: the startup script again"
  systemctl restart google-startup-scripts.service || echo "runner-config-watch: the startup script failed (its journal says why)" >&2
done
WATCH
chmod 0755 "$root/usr/local/sbin/runner-config-watch"
cat > "$root/etc/systemd/system/runner-config-watch.service" <<'UNIT'
[Unit]
Description=Re-run the runner manager's startup script when its metadata changes (tacplus-dev/cloud#46)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/sbin/runner-config-watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now runner-config-watch.service

# token POOL: the pool's runner token on stdout, or nothing yet.
token() {
  curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$(access)") \
      "https://secretmanager.googleapis.com/v1/projects/$project/secrets/runner-token-$1/versions/latest:access" 2>/dev/null |
    python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode())'
}

( umask 077; attr runner-config > "$tmp/config.toml" )
for pool in $(attr runner-pools); do
  until t=$(token "$pool") && [[ $t =~ ^glrt-[A-Za-z0-9_.-]+$ ]]; do
    say "no runner token for the pool $pool yet (runner-token-$pool: the gitlab stack writes it); waiting"
    sleep 60
  done
  python3 - "$tmp/config.toml" "@TOKEN:$pool@" "$t" <<'PY'
import sys
path, mark, value = sys.argv[1:]
text = open(path).read()
assert text.count(mark) == 1, mark
open(path, "w").write(text.replace(mark, value))
PY
done
install -d -m 0700 "$root/etc/gitlab-runner"
# Whole or not at all: gitlab-runner reloads config.toml when it changes, and must never read half of one.
install -m 0600 "$tmp/config.toml" "$root/etc/gitlab-runner/.config.toml.new"
mv -f "$root/etc/gitlab-runner/.config.toml.new" "$root/etc/gitlab-runner/config.toml"
if [ -n "$installed" ] || ! systemctl is-active --quiet gitlab-runner; then
  systemctl restart gitlab-runner
else
  say "config.toml rewritten: gitlab-runner reloads it, its running jobs untouched"
fi
say "gitlab-runner $("$root/usr/bin/gitlab-runner" --version | sed -n 's/^Version: *//p') running the pools: $(attr runner-pools)"
