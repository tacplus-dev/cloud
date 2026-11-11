#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The gitlab provider (gitlabhq/gitlab), built from its source (#3). Upstream's 19.5.0, its latest release, is built
# with go1.26.5 and x/net v0.58.0: it lacks Go's crypto/x509, crypto/tls and net/http fixes (go1.26.6 to go1.26.10)
# and x/net's (v0.60.0, v0.62.0), and it is the provider that talks to gitlab.com with the project's token. This
# builds the same release, its tag at the pinned commit, with go1.27.4 and x/net v0.62.0, every module checked
# against the Go checksum database, as upstream builds it (CGO_ENABLED=0, -trimpath, its ldflags) and with no VCS
# stamp, so the build is reproducible: each one is refused unless its SHA-256 is the pinned one. OpenTofu installs
# it from the mirror only (ci/tofurc.sh), and the lock files hold this build's hashes, not upstream's (ci/lock.sh).
# Drop it for the first upstream release built on a fixed Go (PROPOSALS.md).
#
#   ci/gitlab-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                               # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "gitlab-provider.sh: $*" >&2; exit 1; }

version=19.5.0
commit=2929be292a5961995e47e5776b3f358d53e9ef9b   # tag v19.5.0
repo=https://gitlab.com/gitlab-org/terraform-provider-gitlab.git
go_version=go1.27.4
x_net=v0.62.0
declare -A sha256=(
  [linux_arm64]=cd32aa3cdb9f0702a13f9fa47183ed1d5fcd4b57933de4d63c7083d05caf350e
  [linux_amd64]=01eab6040c1dd2d98e3487a00bdd0003e423038331a1c47d73c4edf107483cba
  [darwin_arm64]=f9dab24327d2c6a00457f91adc77c5171bf0f8d1cc555a8debafd1d3e0d0ff7e
  [darwin_amd64]=5629e23dfa93df5750840420b39f06ec3a1b7ff5f22191965bb6bc6335ae32e7
)

mirror=${1:?usage: ci/gitlab-provider.sh MIRROR [OS_ARCH...]}
shift
[ $# -gt 0 ] || set -- "$(go env GOHOSTOS)_$(go env GOHOSTARCH)"
for p in "$@"; do [ -n "${sha256[$p]:-}" ] || die "no pinned build for $p"; done
mkdir -p "$mirror" && mirror=$(cd "$mirror" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/src"
git -C "$tmp/src" fetch -q --depth 1 "$repo" "$commit" || die "cannot fetch $commit from $repo"
git -C "$tmp/src" checkout -q FETCH_HEAD
[ "$(git -C "$tmp/src" rev-parse HEAD)" = "$commit" ] || die "$repo gave $(git -C "$tmp/src" rev-parse HEAD), not $commit"
rm -rf "$tmp/src/.git"

export GOTOOLCHAIN=$go_version GOFLAGS=-mod=mod CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT='' GONOSUMDB='' GOPRIVATE='' GOINSECURE=''
cd "$tmp/src"
go get "golang.org/x/net@$x_net" > "$tmp/get.log" 2>&1 || { cat "$tmp/get.log" >&2; die "cannot require golang.org/x/net $x_net"; }
[ "$(go version | cut -d' ' -f3)" = "$go_version" ] || die "go is $(go version), not $go_version"
name=terraform-provider-gitlab_v$version
for p in "$@"; do
  out=$tmp/$p/$name
  GOOS=${p%_*} GOARCH=${p#*_} go build -trimpath -buildvcs=false -o "$out" \
    -ldflags "-s -w -X main.version=$version -X main.commit=$commit" . || die "the build for $p failed"
  got=$(sha256sum "$out" | cut -c1-64)
  [ "$got" = "${sha256[$p]}" ] || die "the build for $p has SHA-256 $got, not the pinned ${sha256[$p]}"
  dir=$mirror/registry.opentofu.org/gitlabhq/gitlab/$version/$p
  mkdir -p "$dir" && install -m 0755 "$out" "$dir/$name"
  echo "gitlab-provider.sh: gitlabhq/gitlab $version ($go_version, x/net $x_net) for $p, SHA-256 $got"
done
