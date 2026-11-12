#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# GitLab Runner and its googlecloud fleeting plugin, the runner manager's two binaries, built from their source (#40).
# Upstream's releases (v19.5.3, v1.3.1) are built with go1.26.10 (GO-2026-6859, net/http), x/net v0.58.0 and v0.59.0,
# and the runner with klauspost/compress v1.20.0 (GO-2026-6603 to 6617, 6865) and go-jose v4.1.4 (CVE-2026-116587).
# This builds the same releases, their tags at the pinned commits, with go1.27.4, x/net v0.62.0, klauspost/compress
# v1.20.2 and go-jose v4.1.6, every module checked against the Go checksum database, as upstream builds them (CGO_ENABLED=0, its ldflags) but with -trimpath, no VCS stamp and
# the commit's date as the build's, so the build is reproducible: each one is refused unless its SHA-256 is the pinned
# one. linux/arm64 only, the manager's; a cross-build, so on any host. The versions, commits and SHA-256s are
# stacks/ci/main.tf's runner block; the ci stack serves the builds to the manager from a bucket only it reads
# (modules/projects/ci/runner-bin.tf): nothing it runs comes from upstream at boot. Drop the Go and module bumps for
# the first upstream releases built with them (PROPOSALS.md). The runner's release and recipe are tacplus-dev/cluster's
# too, whose runner and helper images are built from the same commit (cluster#21, #44): a bump here names it there.
#
#   ci/runner.sh DIR   # gitlab-runner and fleeting-plugin-googlecloud into DIR. Needs git, sed and go (the
#                      # toolchain is GOTOOLCHAIN's, fetched by the go command).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "runner.sh: $*" >&2; exit 1; }

go_version=go1.27.4
deps=(golang.org/x/net@v0.62.0 github.com/klauspost/compress@v1.20.2 github.com/go-jose/go-jose/v4@v4.1.6)
main=$here/stacks/ci/main.tf
pin() { sed -n "s/^    $1 *= *\"\(.*\)\"$/\1/p" "$main"; }

out=${1:?usage: ci/runner.sh DIR}
mkdir -p "$out" && out=$(cd "$out" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GOTOOLCHAIN=$go_version GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0 GOEXPERIMENT='' \
  GONOSUMDB='' GOPRIVATE='' GOINSECURE='' GOFIPS140=off

# build NAME REPO COMMIT SHA256 PACKAGE LDFLAGS: PACKAGE of REPO at COMMIT into DIR/NAME, with the
# fixed dependencies the module has; refused unless the build's SHA-256 is SHA256. @BUILT@ in LDFLAGS is the commit's
# time.
build() {
  local name=$1 repo=$2 commit=$3 sha=$4 pkg=$5 ldflags=$6 src=$tmp/$1 d get=() got built
  [[ $commit =~ ^[0-9a-f]{40}$ && $sha =~ ^[0-9a-f]{64}$ ]] || die "$main pins no commit or SHA-256 for $name"
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "$repo" "$commit" || die "cannot fetch $commit from $repo"
  git -C "$src" checkout -q FETCH_HEAD
  [ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || die "$repo gave $(git -C "$src" rev-parse HEAD), not $commit"
  built=$(TZ=UTC0 git -C "$src" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)
  rm -rf "$src/.git"
  for d in "${deps[@]}"; do
    (cd "$src" && go list -m "${d%@*}" >/dev/null 2>&1) && get+=("$d")
  done
  (cd "$src" && go get "${get[@]}" > "$tmp/get.log" 2>&1) || { cat "$tmp/get.log" >&2; die "cannot require ${get[*]} in $name"; }
  [ "$(cd "$src" && go version | cut -d' ' -f3)" = "$go_version" ] || die "go is $(cd "$src" && go version), not $go_version"
  (cd "$src" && go build -trimpath -buildvcs=false -ldflags "${ldflags//@BUILT@/$built}" -o "$tmp/out/$name" "$pkg") ||
    die "the build of $name failed"
  got=$(sha256sum "$tmp/out/$name" | cut -c1-64)
  [ "$got" = "$sha" ] || die "the build of $name has SHA-256 $got, not the pinned $sha"
  install -m 0755 "$tmp/out/$name" "$out/$name"
  echo "runner.sh: $name ($go_version, ${get[*]}) for linux/arm64, SHA-256 $got"
}

v=$(pin version) c=$(pin commit)
r=gitlab.com/gitlab-org/gitlab-runner/common
# Upstream's: its Makefile's GO_LDFLAGS (NAME, VERSION, BRANCH, -w); REVISION and BUILT, which its build reads from
# the VCS stamp, set from the commit. Not its release's frozen FIPS 140 module (GOFIPS140=v1.0.0, which go1.27 also
# turns on, fips140=on): Go's own crypto, with its fixes since.
build gitlab-runner https://gitlab.com/gitlab-org/gitlab-runner.git "$c" "$(pin runner_sha256)" . \
  "-X $r.NAME=gitlab-runner -X $r.VERSION=${v#v} -X $r.BRANCH=$(pin branch) -X $r.REVISION=${c:0:8} -X $r.BUILT=@BUILT@ -w"
v=$(pin plugin_version) c=$(pin plugin_commit)
p=gitlab.com/gitlab-org/fleeting/fleeting-plugin-googlecloud
# Upstream's: its Makefile's GO_LDFLAGS, BUILT the commit's time and REFERENCE the tag (its CI's pipeline ref).
build fleeting-plugin-googlecloud https://gitlab.com/gitlab-org/fleeting/plugins/googlecloud.git "$c" "$(pin plugin_sha256)" \
  ./cmd/fleeting-plugin-googlecloud \
  "-X $p.NAME=fleeting-plugin-googlecloud -X $p.VERSION=$v -X $p.REVISION=${c:0:8} -X $p.BUILT=@BUILT@ -X $p.REFERENCE=$v -w -extldflags '-static'"
