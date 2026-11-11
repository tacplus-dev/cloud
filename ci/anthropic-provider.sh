#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The anthropic provider (ippontech/anthropic), built from its source (#34), as the gitlab provider is
# (ci/gitlab-provider.sh). It is the provider that holds the pipeline's org:admin token to the Anthropic organization
# (the anthropic stack), so it is our own build of its pinned release: the tag at the pinned commit, with go1.27.4
# (its go.mod names go1.27.3, without GO-2026-6859's net/http fix, #39), every module checked against the Go checksum
# database, as upstream builds it (CGO_ENABLED=0, -trimpath, its ldflags) and with no VCS stamp, so the build is
# reproducible: each one is refused unless its SHA-256 is the pinned one. OpenTofu installs it from the mirror only
# (ci/tofurc.sh), the lock files hold this build's hashes (ci/lock.sh), and the security job scans it (govulncheck).
# The provider releases often: a new release is a commit of its version, commit and builds' SHA-256, like any other pin.
#
#   ci/anthropic-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                                  # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "anthropic-provider.sh: $*" >&2; exit 1; }

version=1.92.0
commit=6b7d1bc71b17f3102d855018130c487806575415   # tag v1.92.0
repo=https://github.com/ippontech/terraform-provider-anthropic.git
go_version=go1.27.4
declare -A sha256=(
  [linux_arm64]=89f170bfbc23b892083fb7e79f1a9618913baf222d29222cdf3a839c2589b4ae
  [linux_amd64]=69c8fe11067a1fa6e2a66d728ddc01c8eaefe3982854af828e7025f2471ba05f
  [darwin_arm64]=9a372759815c58a20253d19658e984835a5d934edfa973c50bfe88356620efc8
  [darwin_amd64]=2af3c86bebdf4b0aeeb900dbb1d40bffb1d0d71ec536b50cf2f0b6769e71ba8c
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
