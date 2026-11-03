#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The startup-script of the runner manager (modules/projects/ci). Everything it installs is pinned in the VM's
# metadata, which the pipeline sets: GitLab Runner's two arm64 packages and the googlecloud fleeting plugin, each
# refused unless its SHA-256 is the pinned one. Then config.toml (metadata runner-config) with each pool's token
# from Secret Manager (runner-token-<pool>, its only enabled version: the gitlab stack replaces it when it
# re-registers a runner), and gitlab-runner restarted. Until a pool's token exists (the gitlab stack has not run
# yet), it waits for it. Nothing here prints a token.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
md() { curl -fsS -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1"; }
attr() { md "instance/attributes/$1"; }
say() { echo "manager-startup: $*"; }
die() { say "$*" >&2; exit 1; }

version=$(attr runner-version)
snapshot=$(attr apt-snapshot)
project=$(md project/project-id)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch URL SHA256 FILE: the download, refused unless its SHA-256 is SHA256.
fetch() {
  curl -fsSL --retry 3 -o "$3" "$1" || die "cannot download $1"
  echo "$2  $3" | sha256sum -c --quiet - || die "$1 is not the pinned $2"
}

if [ "$(gitlab-runner --version 2>/dev/null | sed -n 's/^Version: *//p')" != "${version#v}" ]; then
  base=https://gitlab-runner-downloads.s3.amazonaws.com/$version/deb
  fetch "$base/gitlab-runner-helper-images.deb" "$(attr runner-helper-deb-sha256)" "$tmp/gitlab-runner-helper-images.deb"
  fetch "$base/gitlab-runner_arm64.deb" "$(attr runner-deb-sha256)" "$tmp/gitlab-runner_arm64.deb"
  apt-get update -qq --snapshot "$snapshot"
  apt-get install -y -qq --snapshot "$snapshot" "$tmp/gitlab-runner-helper-images.deb" "$tmp/gitlab-runner_arm64.deb" >/dev/null
  say "gitlab-runner $version installed"
fi
plugin_version=$(attr fleeting-plugin-version)
fetch "https://gitlab.com/api/v4/projects/gitlab-org%2Ffleeting%2Fplugins%2Fgooglecloud/packages/generic/releases/$plugin_version/fleeting-plugin-googlecloud-linux-arm64" \
  "$(attr fleeting-plugin-sha256)" "$tmp/plugin"
install -m 0755 "$tmp/plugin" /usr/local/bin/fleeting-plugin-googlecloud

# token POOL: the pool's runner token on stdout, or nothing yet.
token() {
  local access
  access=$(md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
  curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$access") \
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
install -d -m 0700 /etc/gitlab-runner
install -m 0600 "$tmp/config.toml" /etc/gitlab-runner/config.toml
systemctl restart gitlab-runner
say "gitlab-runner $version running the pools: $(attr runner-pools)"
