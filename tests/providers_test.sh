#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests that the gitlab provider is only ever our own build (ci/gitlab-provider.sh, #3): every lock file that names
# gitlabhq/gitlab pins it at the version that script builds, by the hashes of its pinned builds for each platform
# and by nothing else (none of upstream's); the stacks require that version; ci/tofurc.sh installs it from bin/'s
# mirror and never from a registry, and every script that runs tofu uses it. And that security-exceptions.yaml is
# what looper-scan reads (tacplus-dev/looper#49): a list of entries with exactly id, reason, decided_by and expires
# (YYYY-MM-DD), each id once. Needs bash, openssl, base64.
#
#   tests/providers_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
build=$here/ci/gitlab-provider.sh
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

version=$(sed -n 's/^version=\([0-9][0-9.]*\)$/\1/p' "$build" 2>/dev/null)
[ -n "$version" ] && ok "ci/gitlab-provider.sh builds gitlabhq/gitlab $version" || fail "ci/gitlab-provider.sh sets no version="
# The lock-file hash of each pinned build: h1 is Go's dirhash of the unpacked package, one file.
mapfile -t want < <(sed -n 's/^  \[\([a-z0-9]*_[a-z0-9]*\)\]=\([0-9a-f]\{64\}\)$/\2/p' "$build" 2>/dev/null |
  while read -r sha; do
    echo "h1:$(printf '%s  terraform-provider-gitlab_v%s\n' "$sha" "$version" | openssl dgst -sha256 -binary | base64)"
  done | LC_ALL=C sort)
[ "${#want[@]}" = 4 ] && ok "ci/gitlab-provider.sh pins four builds" || fail "ci/gitlab-provider.sh pins ${#want[@]} builds, not four (linux and darwin, arm64 and amd64)"

n=0
for lock in "$here"/stacks/*/.terraform.lock.hcl; do
  s=$(basename "$(dirname "$lock")")
  entry=$(sed -n '/^provider "registry.opentofu.org\/gitlabhq\/gitlab"/,/^}/p' "$lock")
  if [ -z "$entry" ]; then
    grep -q 'gitlabhq/gitlab' "$here/stacks/$s/versions.tf" && fail "$s requires gitlabhq/gitlab and its lock file has no entry"
    continue
  fi
  n=$((n + 1))
  [ "$(sed -n 's/^  version *= *"\(.*\)"$/\1/p' <<<"$entry")" = "$version" ] ||
    fail "$s: the lock file's gitlabhq/gitlab is not version $version"
  grep -A3 'gitlabhq/gitlab"' "$here/stacks/$s/versions.tf" | grep -qx "      version = \"$version\"" ||
    fail "$s: versions.tf does not require gitlabhq/gitlab $version"
  got=$(sed -n 's/^    "\(.*\)",$/\1/p' <<<"$entry" | LC_ALL=C sort)
  [ "$got" = "$(printf '%s\n' "${want[@]}")" ] && ok "$s: gitlabhq/gitlab is locked to our builds only" ||
    fail "$s: gitlabhq/gitlab's hashes are not exactly our builds' (ci/lock.sh): [$(echo $got)]"
done
[ "$n" -gt 0 ] || fail "no lock file names gitlabhq/gitlab"

# ci/tofurc.sh, sourced from a copy of the repository elsewhere: the mirror is that copy's bin/providers.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/bin" && cp -r "$here/ci" "$work/repo/"
cfg=$(bash -c 'set -eu; source "$1/ci/tofurc.sh"; echo "$TF_CLI_CONFIG_FILE"' - "$work/repo" 2>&1)
if [ -f "$cfg" ]; then
  flat=$(tr -s ' \n' ' ' < "$cfg")
  [[ $flat == *'filesystem_mirror { path = "'"$work"'/repo/bin/providers" include = ["registry.opentofu.org/gitlabhq/gitlab"] }'* ]] &&
    ok "ci/tofurc.sh: gitlabhq/gitlab from the checkout's bin/providers" || fail "ci/tofurc.sh: the mirror is not bin/providers for gitlabhq/gitlab only: $flat"
  [[ $flat == *'direct { exclude = ["registry.opentofu.org/gitlabhq/gitlab"] }'* ]] &&
    ok "ci/tofurc.sh: gitlabhq/gitlab never from a registry" || fail "ci/tofurc.sh: the registry is not refused gitlabhq/gitlab: $flat"
else
  fail "ci/tofurc.sh exports no TF_CLI_CONFIG_FILE: $cfg"
fi
for f in ci/lint.sh ci/checks.sh ci/tofu.sh ci/lock.sh; do
  grep -qx 'source "$here/ci/tofurc.sh"' "$here/$f" || fail "$f does not source ci/tofurc.sh"
done

# security-exceptions.yaml, as looper-scan's read_exceptions reads it.
exc=$here/security-exceptions.yaml
if [ -f "$exc" ]; then
  awk '
    /^[ \t]*(#|$)/ { next }
    /^exceptions:[ \t]*$/ { seen = 1; next }
    seen && /^  - [a-z_]+:/ { if (n) check(); n = 0; delete k; s = $0; sub(/^  - /, "", s); field(s); next }
    seen && n && /^    [a-z_]+:/ { s = $0; sub(/^    /, "", s); field(s); next }
    { print "line " NR ": not an exception entry: " $0; bad = 1 }
    function field(s, key, v) { key = s; sub(/:.*/, "", key); v = s; sub(/^[^:]*:[ \t]*/, "", v); gsub(/^"|"$/, "", v)
      if (key !~ /^(id|reason|decided_by|expires)$/ || key in k) { print "line " NR ": key " key; bad = 1 }
      k[key] = v; n++ }
    function check() {
      if (!("id" in k) || k["reason"] == "" || k["decided_by"] == "") { print "an entry lacks an id, a reason or decided_by: " k["id"]; bad = 1 }
      if (k["expires"] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { print k["id"] ": expires is not YYYY-MM-DD"; bad = 1 }
      if (k["id"] in ids) { print k["id"] ": twice"; bad = 1 }
      ids[k["id"]] = 1 }
    END { if (n) check(); if (!seen) { print "no exceptions: list"; bad = 1 }; exit bad }
  ' "$exc" > "$work/exc" && ok "security-exceptions.yaml: what looper-scan reads" ||
    fail "security-exceptions.yaml: $(tr '\n' ';' < "$work/exc")"
else
  fail "no security-exceptions.yaml"
fi

[ "$failed" = 0 ] && echo "providers: all passed" || { echo "providers: FAILED"; exit 1; }
