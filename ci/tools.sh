#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline's tools, each pinned by version and by the SHA-256 of its release download or of our reproducible build,
# into bin/ (the lint job's artifact; none holds a secret). A download or build whose checksum differs is refused. Nothing resolves "latest"
# (tacplus-dev/roadmap decisions/deterministic-deployments-2026-11-02.md).
#
#   bin/tofu          OpenTofu: fmt, validate, test, plan, apply (the providers are pinned by hash in each stack's
#                     .terraform.lock.hcl): built from its release's module source as upstream builds it, but with
#                     the pinned Go (tools_go; upstream's release is built with go1.27.3, without GO-2026-6859's fix,
#                     #39), refused unless the module's hash is the pinned one and the build's SHA-256 too (srcbuild)
#   bin/tflint        with the google ruleset, installed where .tflint.hcl's pinned version expects it
#                     (bin/tflint.d, TFLINT_PLUGIN_DIR); `tflint --init` is never run; both built as tofu is
#   bin/shellcheck    the scripts
#   bin/yq            the tests (built from its pinned module version with the pinned Go, checked against the Go
#                     checksum database)
#   bin/gitleaks      secrets, in the tree and its history (ci/security.sh, and tests/security_test.sh): built
#                     from its pinned module version with the pinned Go (tools_go), refused unless the module's
#                     hash (h1:, a SHA-256 of its files) is the pinned one, its dependencies checked against the Go
#                     checksum database (upstream's release is built with go1.24.11, without Go's fixes since), and
#                     with the fixed klauspost/compress and brotli its release lacks (#24)
#   bin/providers     the gitlab, kubernetes, google and anthropic providers, our own builds from their source for
#                     this platform (ci/gitlab-provider.sh, ci/kubernetes-provider.sh, ci/google-provider.sh,
#                     ci/anthropic-provider.sh, pinned by
#                     commit and by the SHA-256 of the build): OpenTofu installs them from there only (ci/tofurc.sh)
#   bin/manager       GitLab Runner and its googlecloud fleeting plugin for the runner manager (linux arm64), our
#                     builds (ci/runner.sh, pinned by commit and by the SHA-256 of the build in stacks/ci/main.tf),
#                     which the ci stack uploads to the manager's bucket (#40)
#
# And with `security`, the security job's (ci/security.sh), only that job's (they are large):
#
#   bin/osv-scanner   the tree's dependency manifests and lock files: built as gitleaks is (upstream's release is
#                     built with go1.27.0), with the fixed klauspost/compress (#24)
#   bin/trivy         the CI image: built as tofu is (upstream's release is built with go1.27.3, #39)
#   bin/govulncheck   the pinned binaries (-mode=binary): built as gitleaks is
#   bin/scan/         the pinned binaries that are not tools here, to scan: GitLab Runner and its fleeting plugin, the
#                     very builds the manager installs (bin/manager, of the tools job); every provider is ours, in
#                     bin/providers (#39)
#
#   ci/tools.sh [security]   # needs curl, xz, sha256sum, git, jq and go (ghcr.io/tacplus-dev/tacplus/build;
#                            # the pinned Go is fetched by the go command, by the checksum database); linux arm64
#                            # or amd64; security after ci/tools.sh (bin/manager)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$here/bin
die() { echo "tools.sh: $*" >&2; exit 1; }

tofu_version=1.13.2
tofu_sum=h1:iC+P5kFxXbBiTWm2bb8CkoTiq3IcU9BBZZVtQr9fsb8=
tflint_version=0.65.0
tflint_sum=h1:R+3+mkZuO8eCQy0bzkP9Pz1JPmNePXnOXX2T6K142j4=
tflint_google_version=0.41.0   # .tflint.hcl names the same version
tflint_google_sum=h1:f1FcPYLq1WxGqeSK8QV2JfXZB3O4QY7ChCFfOwjBjcs=
shellcheck_version=0.11.0
yq_version=v4.54.1
# The Go that builds the scanners (gobuild): the latest, with the standard library's fixes.
tools_go=go1.27.4
gitleaks_version=v8.30.1
gitleaks_sum=h1:PmEvCfVI7ti9dV3s5aMZUY7sS2GxRvG3yzih7E+cS3w=
osv_scanner_version=v2.7.0
osv_scanner_sum=h1:7aOrJ9vB7qbzxC3R+QCXs03SHQiRuM80RJdqZhUEl2g=
# What gitleaks and OSV-Scanner are built with in place of their releases' (#24): the first fixed versions, which no
# release of them requires yet (GO-2026-6865 in both, GO-2026-6888 in gitleaks).
klauspost_compress=github.com/klauspost/compress@v1.20.2
brotli=github.com/andybalholm/brotli@v1.2.7
govulncheck_version=v1.1.4
govulncheck_sum=h1:Ju8QsuyhX3Hk8ma3CesTbO8vfJD9EvUBgHvkxHBzj0I=
trivy_version=0.76.1
trivy_sum=h1:xzXcxZpfkZpTxAHzfuG3KS5BRP17KG70+c0uFFwZUU4=

# The SHA-256 of each download, and of each of our builds (srcbuild: tofu, tflint, its ruleset, trivy).
case $(uname -m) in
  aarch64|arm64) arch=arm64 sc_arch=aarch64
    tofu_sha=9a0b800592049ecf6a46f2bb85c2be5eef40629cf622cbe86fb87a14f0d735e4
    tflint_sha=6b8a1597aa76882b241c18a5d47189c81350b2e66f0da86097b6f92d38031e43
    tflint_google_sha=932d8448fc1f3bbdbcd73bd608f499b0971fe8679d6f6ff584506df2575a46c0
    shellcheck_sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    trivy_sha=b6ff7d266b3b0a00c0ad5fb15785e4a458bf46d427059cae771e0975b16a5280 ;;
  x86_64|amd64) arch=amd64 sc_arch=x86_64
    tofu_sha=11f9f212f0319c691d23be8155cbacfd8711eb70bb41563ba6c03758fe1f343d
    tflint_sha=1083943c5bae26197f78d550134d324b5bfa95e212acc1d25dade10bf39b4e6d
    tflint_google_sha=2ab3ff771be9efedaaf7e61fd93a3917440a0ea19a2f24cdd38d2b1806009496
    shellcheck_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    trivy_sha=8eec523a45b922f1dd97aba7db0d825e7d46a65230db1a10b05a1f54da33b328 ;;
  *) die "no pinned tools for $(uname -m)" ;;
esac
case ${1:-} in '') security=no ;; security) security=yes ;; *) die "usage: ci/tools.sh [security]" ;; esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# fetch URL SHA256: the download in $tmp/<its name>, refused unless its SHA-256 is SHA256.
fetch() {
  local f=$tmp/${1##*/}
  curl -sSfL --retry 3 -o "$f" "$1" || die "cannot download $1"
  echo "$2  $f" | sha256sum -c --quiet - >/dev/null 2>&1 || die "$1: SHA-256 $(sha256sum "$f" | cut -c1-64), not the pinned $2"
  echo "$f"
}
# gobuild MODULE VERSION SUM PACKAGE [DEPENDENCY@VERSION...]: PACKAGE of MODULE@VERSION into bin/, built with Go
# tools_go; refused unless the module's hash is SUM. With dependencies, built in a copy of the module's source
# that requires them (go get, checked against the Go checksum database), for fixes its release lacks.
gobuild() {
  local m=$1 v=$2 sum=$3 pkg=$4 j src; shift 4
  j=$(cd "$tmp" && GOTOOLCHAIN=$tools_go GOFLAGS=-mod=mod go mod download -json "$m@$v") || die "cannot download $m@$v"
  [ "$(jq -r .Sum <<<"$j")" = "$sum" ] || die "$m@$v: $(jq -r .Sum <<<"$j"), not the pinned $sum"
  if [ $# -eq 0 ]; then
    (cd "$tmp" && GOBIN=$bin GOTOOLCHAIN=$tools_go GOFLAGS=-mod=mod go install "$pkg@$v") || die "cannot build $pkg@$v"
    return
  fi
  src=$tmp/src/$m
  mkdir -p "$src" && cp -R "$(jq -r .Dir <<<"$j")/." "$src" && chmod -R u+w "$src"
  (cd "$src" && export GOTOOLCHAIN=$tools_go GOFLAGS=-mod=mod &&
    go get "$@" > "$tmp/get.log" 2>&1 && go build -o "$bin/" ".${pkg#"$m"}") ||
    { cat "$tmp/get.log" >&2; die "cannot build $pkg@$v with $*"; }
}

# srcbuild MODULE VERSION SUM PACKAGE SHA256 LDFLAGS: PACKAGE of MODULE@VERSION built from the module's source (refused
# unless its hash is SUM) as its release is (CGO_ENABLED=0, -trimpath, LDFLAGS), but with Go tools_go, and with no VCS
# stamp, so reproducibly (#39): the build's path on stdout, refused unless its SHA-256 is SHA256.
srcbuild() {
  local m=$1 v=$2 sum=$3 pkg=$4 sha=$5 ldflags=$6 j src out
  j=$(cd "$tmp" && GOTOOLCHAIN=$tools_go GOFLAGS=-mod=mod go mod download -json "$m@$v") || die "cannot download $m@$v"
  [ "$(jq -r .Sum <<<"$j")" = "$sum" ] || die "$m@$v: $(jq -r .Sum <<<"$j"), not the pinned $sum"
  src=$tmp/src/$m out=$tmp/build/${pkg##*/}
  mkdir -p "$src" && cp -R "$(jq -r .Dir <<<"$j")/." "$src" && chmod -R u+w "$src"
  (cd "$src" && GOTOOLCHAIN=$tools_go GOFLAGS=-mod=readonly CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT='' \
    go build -trimpath -buildvcs=false -ldflags "$ldflags" -o "$out" ".${pkg#"$m"}" >&2) || die "cannot build $pkg@$v"
  echo "$sha  $out" | sha256sum -c --quiet - >/dev/null 2>&1 ||
    die "$pkg@$v: the build's SHA-256 is $(sha256sum "$out" | cut -c1-64), not the pinned $sha"
  echo "$out"
}

# The security job's tools and the binaries it scans (above).
security() {
  local f b
  gobuild github.com/google/osv-scanner/v2 "$osv_scanner_version" "$osv_scanner_sum" github.com/google/osv-scanner/v2/cmd/osv-scanner \
    "$klauspost_compress"
  f=$(srcbuild github.com/aquasecurity/trivy "v$trivy_version" "$trivy_sum" github.com/aquasecurity/trivy/cmd/trivy "$trivy_sha" \
    "-s -w -X github.com/aquasecurity/trivy/pkg/version/app.ver=$trivy_version")
  install -m 0755 "$f" "$bin/trivy"
  gobuild golang.org/x/vuln "$govulncheck_version" "$govulncheck_sum" golang.org/x/vuln/cmd/govulncheck
  rm -rf "$bin/scan" && mkdir -p "$bin/scan"
  for b in gitlab-runner fleeting-plugin-googlecloud; do
    [ -f "$bin/manager/$b" ] || die "no bin/manager/$b: ci/tools.sh builds it (ci/runner.sh)"
    install -m 0755 "$bin/manager/$b" "$bin/scan/$b"
  done
  echo "bin/: osv-scanner $osv_scanner_version, trivy $trivy_version, govulncheck $govulncheck_version; bin/scan/: our GitLab Runner and fleeting plugin (bin/manager)"
}

mkdir -p "$bin"
if [ "$security" = yes ]; then security; exit 0; fi
f=$(srcbuild github.com/opentofu/opentofu "v$tofu_version" "$tofu_sum" github.com/opentofu/opentofu/cmd/tofu "$tofu_sha" \
  "-s -w -X 'github.com/opentofu/opentofu/version.dev=no'")
install -m 0755 "$f" "$bin/tofu"
f=$(srcbuild github.com/terraform-linters/tflint "v$tflint_version" "$tflint_sum" github.com/terraform-linters/tflint "$tflint_sha" "-s -w")
install -m 0755 "$f" "$bin/tflint"
plugin=$bin/tflint.d/github.com/terraform-linters/tflint-ruleset-google/$tflint_google_version
mkdir -p "$plugin"
f=$(srcbuild github.com/terraform-linters/tflint-ruleset-google "v$tflint_google_version" "$tflint_google_sum" \
  github.com/terraform-linters/tflint-ruleset-google "$tflint_google_sha" "-s -w")
install -m 0755 "$f" "$plugin/tflint-ruleset-google"
t=$(fetch "https://github.com/koalaman/shellcheck/releases/download/v$shellcheck_version/shellcheck-v$shellcheck_version.linux.$sc_arch.tar.xz" "$shellcheck_sha")
tar -xJf "$t" -C "$tmp" "shellcheck-v$shellcheck_version/shellcheck"
install -m 0755 "$tmp/shellcheck-v$shellcheck_version/shellcheck" "$bin/shellcheck"
gobuild github.com/zricethezav/gitleaks/v8 "$gitleaks_version" "$gitleaks_sum" github.com/zricethezav/gitleaks/v8 \
  "$klauspost_compress" "$brotli"
GOBIN=$bin GOTOOLCHAIN=$tools_go GOFLAGS=-mod=mod go install "github.com/mikefarah/yq/v4@$yq_version"
"$here/ci/gitlab-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/kubernetes-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/google-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/anthropic-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/runner.sh" "$bin/manager"
echo "bin/: tofu $("$bin/tofu" version | head -1 | cut -d' ' -f2), tflint $tflint_version (google $tflint_google_version), shellcheck $shellcheck_version, yq $yq_version, gitleaks $gitleaks_version, the gitlab, kubernetes, google and anthropic providers (providers/), GitLab Runner and its fleeting plugin (manager/), all built with $tools_go"
