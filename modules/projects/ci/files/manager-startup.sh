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
# fetched if PATH already is that build (a reboot).
get() {
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "no SHA-256 pinned for $1"
  if [ -f "$root$3" ] && echo "$2  $root$3" | sha256sum -c --quiet - >/dev/null 2>&1; then return; fi
  curl -fsSL --retry 3 -H @<(printf 'Authorization: Bearer %s\n' "$(access)") -o "$tmp/$1" \
    "https://storage.googleapis.com/storage/v1/b/$bucket/o/$1%2F$2?alt=media" || die "cannot download $1/$2 from gs://$bucket"
  echo "$2  $tmp/$1" | sha256sum -c --quiet - || die "gs://$bucket/$1/$2 is not the pinned build"
  install -D -m 0755 "$tmp/$1" "$root$3"
  say "$1 installed, SHA-256 $2"
}
get gitlab-runner "$(attr runner-sha256)" /usr/bin/gitlab-runner
get fleeting-plugin-googlecloud "$(attr fleeting-plugin-sha256)" /usr/local/bin/fleeting-plugin-googlecloud

# The service as upstream's package's post-install sets it up: its user, and the unit gitlab-runner writes.
id -u gitlab-runner >/dev/null 2>&1 ||
  useradd --system --shell /bin/bash --comment 'GitLab Runner' --create-home --skel /dev/null gitlab-runner
[ -f "$root/etc/systemd/system/gitlab-runner.service" ] ||
  "$root/usr/bin/gitlab-runner" install --user=gitlab-runner --working-directory=/home/gitlab-runner

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
install -m 0600 "$tmp/config.toml" "$root/etc/gitlab-runner/config.toml"
systemctl restart gitlab-runner
say "gitlab-runner $("$root/usr/bin/gitlab-runner" --version | sed -n 's/^Version: *//p') running the pools: $(attr runner-pools)"
