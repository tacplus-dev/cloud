#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The kubernetes provider (hashicorp/kubernetes), built from its source (#18), as the gitlab provider is
# (ci/gitlab-provider.sh). Upstream's 3.4.0, its latest release, is built with go1.26.3: it lacks Go's crypto/x509,
# crypto/tls and net/http fixes since, and it is the provider that holds the pipeline's token to dev's cluster. This
# builds the same release, its tag at the pinned commit, with go1.27.4, x/net v0.62.0 and kin-openapi v0.152.0 (#23: its
# v0.111.0 has the advisories of #18 and #23, fixed by v0.149.0), every module checked against the Go checksum
# database, as upstream builds it (CGO_ENABLED=0, -trimpath, -buildvcs=false, its ldflags), so the build is
# reproducible: each one is refused unless its SHA-256 is the pinned one. kin-openapi's API changed since v0.111.0:
# ci/kubernetes-provider.patch ports the provider's manifest/openapi to it, and its tests run before the build.
# OpenTofu installs it from the mirror only (ci/tofurc.sh), and the lock files hold this build's hashes, not
# upstream's (ci/lock.sh). Drop the kin-openapi override and the patch for the first upstream release against
# kin-openapi v0.149.0 or later, and the build for the first one also built on a fixed Go (PROPOSALS.md).
#
#   ci/kubernetes-provider.sh MIRROR [OS_ARCH...]   # into MIRROR, an unpacked filesystem mirror; default the host's
#                                                   # platform. Needs git and go (the toolchain is GOTOOLCHAIN's).
set -euo pipefail
die() { echo "kubernetes-provider.sh: $*" >&2; exit 1; }

version=3.4.0
commit=f76a1ae8afd51777c8ef068b3cfaf34d58a32803   # tag v3.4.0
repo=https://github.com/hashicorp/terraform-provider-kubernetes.git
go_version=go1.27.4
x_net=v0.62.0
kin_openapi=v0.152.0
here=$(cd "$(dirname "$0")/.." && pwd)
declare -A sha256=(
  [linux_arm64]=d48723368123a92dd55fc6252c7800b807434d59afca6ad933df1b73585d49c8
  [linux_amd64]=044149fb534a697f110d22f29c936f2fc93d8b265c9b88d00fe8d04a27b28542
  [darwin_arm64]=fd4ea93a792a356fd8bbd5d78e1592270d0cbf42f1cf723be11b44cc63cf063f
  [darwin_amd64]=095b238a3cd3a24257599a34d68dee5738169892bc521f1a9ef010675e0ce385
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
git -C "$tmp/src" apply "$here/ci/kubernetes-provider.patch" || die "ci/kubernetes-provider.patch does not apply"
rm -rf "$tmp/src/.git"

export GOTOOLCHAIN=$go_version GOFLAGS=-mod=mod CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT='' GONOSUMDB='' GOPRIVATE='' GOINSECURE=''
cd "$tmp/src"
go get "golang.org/x/net@$x_net" > "$tmp/get.log" 2>&1 || { cat "$tmp/get.log" >&2; die "cannot require golang.org/x/net $x_net"; }
go get "github.com/getkin/kin-openapi@$kin_openapi" > "$tmp/get.log" 2>&1 ||
  { cat "$tmp/get.log" >&2; die "cannot require github.com/getkin/kin-openapi $kin_openapi"; }
go test ./manifest/openapi/ > "$tmp/test.log" 2>&1 ||
  { cat "$tmp/test.log" >&2; die "manifest/openapi's tests fail on kin-openapi $kin_openapi (ci/kubernetes-provider.patch)"; }
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
  echo "kubernetes-provider.sh: hashicorp/kubernetes $version ($go_version, x/net $x_net, kin-openapi $kin_openapi) for $p, SHA-256 $got"
done
