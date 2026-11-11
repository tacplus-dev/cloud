#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The anthropic provider (ippontech/anthropic), built from its source (#34), as the gitlab provider is
# (ci/gitlab-provider.sh). It is the provider that holds the pipeline's org:admin token to the Anthropic organization
# (the anthropic stack), so it is our own build of its pinned release: the tag at the pinned commit, with the Go its
# go.mod names (go1.27.3), every module checked against the Go checksum database, as upstream builds it
# (CGO_ENABLED=0, -trimpath, its ldflags) and with no VCS stamp, so the build is reproducible: each one is refused
# unless its SHA-256 is the pinned one. OpenTofu installs it from the mirror only (ci/tofurc.sh), the lock files hold
# this build's hashes (ci/lock.sh), and the security job scans it (govulncheck). The provider releases often: a new
# release is a commit of its version, commit and builds' SHA-256, like any other pin.
#
#   ci/anthropic-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                                  # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "anthropic-provider.sh: $*" >&2; exit 1; }

version=1.92.0
commit=6b7d1bc71b17f3102d855018130c487806575415   # tag v1.92.0
repo=https://github.com/ippontech/terraform-provider-anthropic.git
go_version=go1.27.3
declare -A sha256=(
  [linux_arm64]=50b696493af6a29a4e639c775959c3e0a80f654d7b5d0cbcd1caafd21f7396eb
  [linux_amd64]=1e3f5c42b040cef33a792caf16f87241203374ddae26fb7c786023594dbedd6a
  [darwin_arm64]=e0b5af053beded9615a8f40ac0650f32450028c7a9bed70a1290a2aff35a689c
  [darwin_amd64]=8fdc19c08fcb39197d017c498c285427854613415301d90187c8b4bb2fa93b82
)

mirror=${1:?usage: ci/anthropic-provider.sh MIRROR [OS_ARCH...]}
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
[ "$(go version | cut -d' ' -f3)" = "$go_version" ] || die "go is $(go version), not $go_version"
name=terraform-provider-anthropic_v$version
for p in "$@"; do
  out=$tmp/$p/$name
  GOOS=${p%_*} GOARCH=${p#*_} go build -trimpath -buildvcs=false -o "$out" \
    -ldflags "-s -w -X main.version=$version -X main.commit=$commit" . || die "the build for $p failed"
  got=$(sha256sum "$out" | cut -c1-64)
  [ "$got" = "${sha256[$p]}" ] || die "the build for $p has SHA-256 $got, not the pinned ${sha256[$p]}"
  dir=$mirror/registry.opentofu.org/ippontech/anthropic/$version/$p
  mkdir -p "$dir" && install -m 0755 "$out" "$dir/$name"
  echo "anthropic-provider.sh: ippontech/anthropic $version ($go_version) for $p, SHA-256 $got"
done
