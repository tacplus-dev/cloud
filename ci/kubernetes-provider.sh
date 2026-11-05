#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The kubernetes provider (hashicorp/kubernetes), built from its source (#18), as the gitlab provider is
# (ci/gitlab-provider.sh). Upstream's 3.4.0, its latest release, is built with go1.26.3: it lacks Go's crypto/x509,
# crypto/tls and net/http fixes since, and it is the provider that holds the pipeline's token to dev's cluster. This
# builds the same release, its tag at the pinned commit, with go1.27.3 and x/net v0.62.0, every module checked
# against the Go checksum database, as upstream builds it (CGO_ENABLED=0, -trimpath, -buildvcs=false, its ldflags),
# so the build is reproducible: each one is refused unless its SHA-256 is the pinned one. OpenTofu installs it from
# the mirror only (ci/tofurc.sh), and the lock files hold this build's hashes, not upstream's (ci/lock.sh). Its
# kin-openapi v0.111.0 stays (the fixed releases change its API): security-exceptions.yaml. Drop it for the first
# upstream release built on a fixed Go and against kin-openapi v0.144.0 or later (PROPOSALS.md).
#
#   ci/kubernetes-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                                   # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "kubernetes-provider.sh: $*" >&2; exit 1; }

version=3.4.0
commit=f76a1ae8afd51777c8ef068b3cfaf34d58a32803   # tag v3.4.0
repo=https://github.com/hashicorp/terraform-provider-kubernetes.git
go_version=go1.27.3
x_net=v0.62.0
declare -A sha256=(
  [linux_arm64]=32f8e3b588ded5511e696b00aea1a75101cd2b6431fcaf0f017a34abdc456a16
  [linux_amd64]=64868ae819d4d8c4d3f4f9c705930a0e3467e2dc4db49fda848f4a318da2421a
  [darwin_arm64]=f03a1ccfd8e800ec1ce57fcdee4012e9f9eb3d44cb47f50e3fa8e7825ef832cd
  [darwin_amd64]=62883b947e1fbd60fd54346554f425dd472a9a5e36c1eade0b7296345f34d75c
)

mirror=${1:?usage: ci/kubernetes-provider.sh MIRROR [OS_ARCH...]}
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
name=terraform-provider-kubernetes_v$version
for p in "$@"; do
  out=$tmp/$p/$name
  GOOS=${p%_*} GOARCH=${p#*_} go build -trimpath -buildvcs=false -o "$out" \
    -ldflags "-s -w -X 'main.Version=$version'" . || die "the build for $p failed"
  got=$(sha256sum "$out" | cut -c1-64)
  [ "$got" = "${sha256[$p]}" ] || die "the build for $p has SHA-256 $got, not the pinned ${sha256[$p]}"
  dir=$mirror/registry.opentofu.org/hashicorp/kubernetes/$version/$p
  mkdir -p "$dir" && install -m 0755 "$out" "$dir/$name"
  echo "kubernetes-provider.sh: hashicorp/kubernetes $version ($go_version, x/net $x_net) for $p, SHA-256 $got"
done
