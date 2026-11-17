#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The google provider (hashicorp/google), built from its source (#39), as the gitlab provider is
# (ci/gitlab-provider.sh). Upstream's 8.9.0 is built with go1.26.10 and x/net v0.61.0, and so is its latest release:
# they lack Go's net/http fix (GO-2026-6859, go1.26.11 and go1.27.4) and x/net's (v0.62.0), and it is the provider that
# holds the pipeline's Google credentials. This builds the same release, its tag at the pinned commit, with go1.27.4
# and x/net v0.62.0, and x/crypto v0.59.0, which deletes openpgp (GO-2026-5932, #76; the provider imports none of it),
# every module checked against the Go checksum database, as upstream builds it (CGO_ENABLED=0,
# -trimpath, its ldflags) and with no VCS stamp, so the build is reproducible: each one is refused unless its SHA-256
# is the pinned one. OpenTofu installs it from the mirror only (ci/tofurc.sh), and the lock files hold this build's
# hashes, not upstream's (ci/lock.sh). Drop it for the first upstream release built on a fixed Go (PROPOSALS.md).
#
#   ci/google-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                               # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "google-provider.sh: $*" >&2; exit 1; }

version=8.9.0
commit=ffc5d7f2c4af44558f1b6a7c66142fac3a7abd80   # tag v8.9.0
repo=https://github.com/hashicorp/terraform-provider-google.git
go_version=go1.27.4
x_net=v0.62.0
x_crypto=v0.59.0
declare -A sha256=(
  [linux_arm64]=83388e98e42a613528287279e9d3d9d258580abbfaccc9d64346e73a94a21a73
  [linux_amd64]=8c9a57081419361de36b735a12372a73aea2a8a1f6452c70395496279433904b
  [darwin_arm64]=ed172c0c185ade9545e47207768f00b6da19713fb5c9452cfc64264bb23e9bca
  [darwin_amd64]=eb11064f5d4f911463112226b54624c3e7ef23cac18199bb6eee65d86e958597
)

mirror=${1:?usage: ci/google-provider.sh MIRROR [OS_ARCH...]}
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
go get "golang.org/x/net@$x_net" "golang.org/x/crypto@$x_crypto" > "$tmp/get.log" 2>&1 ||
  { cat "$tmp/get.log" >&2; die "cannot require golang.org/x/net $x_net and golang.org/x/crypto $x_crypto"; }
[ "$(go version | cut -d' ' -f3)" = "$go_version" ] || die "go is $(go version), not $go_version"
name=terraform-provider-google_v$version
for p in "$@"; do
  out=$tmp/$p/$name
  GOOS=${p%_*} GOARCH=${p#*_} go build -trimpath -buildvcs=false -o "$out" \
    -ldflags "-s -w -X github.com/hashicorp/terraform-provider-google/version.ProviderVersion=$version" . ||
    die "the build for $p failed"
  got=$(sha256sum "$out" | cut -c1-64)
  [ "$got" = "${sha256[$p]}" ] || die "the build for $p has SHA-256 $got, not the pinned ${sha256[$p]}"
  dir=$mirror/registry.opentofu.org/hashicorp/google/$version/$p
  mkdir -p "$dir" && install -m 0755 "$out" "$dir/$name"
  echo "google-provider.sh: hashicorp/google $version ($go_version, x/net $x_net, x/crypto $x_crypto) for $p, SHA-256 $got"
done
