#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pipeline's tools, each pinned by version and by the SHA-256 of its release download, into bin/ (the lint job's
# artifact; none holds a secret). A download whose checksum differs is refused. Nothing resolves "latest"
# (tacplus-dev/roadmap decisions/deterministic-deployments-2026-11-02.md).
#
#   bin/tofu          OpenTofu: fmt, validate, test, plan, apply (the providers are pinned by hash in each stack's
#                     .terraform.lock.hcl)
#   bin/tflint        with the google ruleset, installed where .tflint.hcl's pinned version expects it
#                     (bin/tflint.d, TFLINT_PLUGIN_DIR); `tflint --init` is never run
#   bin/shellcheck    the scripts
#   bin/yq            the tests (built from its pinned module version, checked against the Go checksum database)
#   bin/gitleaks      secrets, in the tree and its history (ci/security.sh, and tests/security_test.sh): built
#                     from its pinned module version with the pinned Go (scanners_go), refused unless the module's
#                     hash (h1:, a SHA-256 of its files) is the pinned one, its dependencies checked against the Go
#                     checksum database (upstream's release is built with go1.24.11, without Go's fixes since), and
#                     with the fixed klauspost/compress and brotli its release lacks (#24)
#   bin/providers     the gitlab and kubernetes providers, our own builds from their source for this platform
#                     (ci/gitlab-provider.sh, ci/kubernetes-provider.sh, pinned by commit and by the SHA-256 of the
#                     build): OpenTofu installs them from there only (ci/tofurc.sh)
#   bin/manager       GitLab Runner and its googlecloud fleeting plugin for the runner manager (linux arm64), our
#                     builds (ci/runner.sh, pinned by commit and by the SHA-256 of the build in stacks/ci/main.tf),
#                     which the ci stack uploads to the manager's bucket (#40)
#
# And with `security`, the security job's (ci/security.sh), only that job's (they are large):
#
#   bin/osv-scanner   the tree's dependency manifests and lock files: built as gitleaks is (upstream's release is
#                     built with go1.27.0), with the fixed klauspost/compress (#24)
#   bin/trivy         the CI image: upstream's release, by SHA-256
#   bin/govulncheck   the pinned binaries (-mode=binary): built as gitleaks is
#   bin/scan/         the pinned binaries that are not tools here, to scan: the google provider (OpenTofu's plugin
#                     cache, filled by an init of each stack: by the lock files' hashes), and GitLab Runner and its
#                     fleeting plugin, by the version and SHA-256 stacks/ci/main.tf pins (arm64, the manager's)
#
#   ci/tools.sh [security]   # needs curl, unzip, xz, sha256sum, git, jq and go (ghcr.io/tacplus-dev/tacplus/build;
#                            # the pinned Go is fetched by the go command, by the checksum database); linux arm64
#                            # or amd64; security also dpkg-deb
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$here/bin
die() { echo "tools.sh: $*" >&2; exit 1; }

tofu_version=1.13.2
tflint_version=0.65.0
tflint_google_version=0.41.0   # .tflint.hcl names the same version
shellcheck_version=0.11.0
yq_version=v4.54.1
# The Go that builds the scanners (gobuild): the latest, with the standard library's fixes.
scanners_go=go1.27.3
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

case $(uname -m) in
  aarch64|arm64) arch=arm64 sc_arch=aarch64 trivy_arch=ARM64
    tofu_sha=6e815c58a09ee957de606ff48cefad082942e70afc43b737ff975654c54ec453
    tflint_sha=843017c47a98be1de4d88fa038daa293770fe25cd01656c4f08b2e30d1d3b3a0
    tflint_google_sha=d6a527cf803feb46d50e2052f85f5497875a6807040e56e64c26637cfa14b13d
    shellcheck_sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    trivy_sha=e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f ;;
  x86_64|amd64) arch=amd64 sc_arch=x86_64 trivy_arch=64bit
    tofu_sha=723bebb0df8411daff1e5fc3862e28ff5581fe5634087f4c29a9aa41d78208b5
    tflint_sha=d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61
    tflint_google_sha=efb3910bbc9f0b90bebd76d475ca6cd2cf04a032f6cddc8fa7a334e5011da6d6
    shellcheck_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    trivy_sha=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0 ;;
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
# scanners_go; refused unless the module's hash is SUM. With dependencies, built in a copy of the module's source
# that requires them (go get, checked against the Go checksum database), for fixes its release lacks.
gobuild() {
  local m=$1 v=$2 sum=$3 pkg=$4 j src; shift 4
  j=$(cd "$tmp" && GOTOOLCHAIN=$scanners_go GOFLAGS=-mod=mod go mod download -json "$m@$v") || die "cannot download $m@$v"
  [ "$(jq -r .Sum <<<"$j")" = "$sum" ] || die "$m@$v: $(jq -r .Sum <<<"$j"), not the pinned $sum"
  if [ $# -eq 0 ]; then
    (cd "$tmp" && GOBIN=$bin GOTOOLCHAIN=$scanners_go GOFLAGS=-mod=mod go install "$pkg@$v") || die "cannot build $pkg@$v"
    return
  fi
  src=$tmp/src/$m
  mkdir -p "$src" && cp -R "$(jq -r .Dir <<<"$j")/." "$src" && chmod -R u+w "$src"
  (cd "$src" && export GOTOOLCHAIN=$scanners_go GOFLAGS=-mod=mod &&
    go get "$@" > "$tmp/get.log" 2>&1 && go build -o "$bin/" ".${pkg#"$m"}") ||
    { cat "$tmp/get.log" >&2; die "cannot build $pkg@$v with $*"; }
}

# The security job's tools and the binaries it scans (above).
security() {
  local f main runner plugin s
  gobuild github.com/google/osv-scanner/v2 "$osv_scanner_version" "$osv_scanner_sum" github.com/google/osv-scanner/v2/cmd/osv-scanner \
    "$klauspost_compress"
  f=$(fetch "https://github.com/aquasecurity/trivy/releases/download/v$trivy_version/trivy_${trivy_version}_Linux-$trivy_arch.tar.gz" "$trivy_sha")
  tar -xzf "$f" -C "$tmp" trivy
  install -m 0755 "$tmp/trivy" "$bin/trivy"
  gobuild golang.org/x/vuln "$govulncheck_version" "$govulncheck_sum" golang.org/x/vuln/cmd/govulncheck
  rm -rf "$bin/scan" && mkdir -p "$bin/scan/plugins"
  # shellcheck source=ci/tofurc.sh
  source "$here/ci/tofurc.sh"
  for s in "$here"/stacks/*/; do
    # Its own data directory: the stack's .terraform/ is left as it was.
    (cd "$s" && TF_DATA_DIR=$tmp/tf-$(basename "$s") TF_PLUGIN_CACHE_DIR=$bin/scan/plugins \
      "$bin/tofu" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null) ||
      die "tofu init ${s#"$here"/}: the providers to scan"
  done
  main=$here/stacks/ci/main.tf
  pin() { sed -n "s/^    $1 *= *\"\(.*\)\"$/\1/p" "$main"; }
  runner=$(pin version) plugin=$(pin plugin_version)
  [ -n "$runner" ] && [ -n "$plugin" ] || die "$main pins no GitLab Runner or fleeting plugin version"
  f=$(fetch "https://gitlab-runner-downloads.s3.amazonaws.com/$runner/deb/gitlab-runner_arm64.deb" "$(pin deb_sha256)")
  dpkg-deb -x "$f" "$tmp/runner"
  install -m 0755 "$tmp/runner/usr/bin/gitlab-runner" "$bin/scan/gitlab-runner"
  f=$(fetch "https://gitlab.com/api/v4/projects/gitlab-org%2Ffleeting%2Fplugins%2Fgooglecloud/packages/generic/releases/$plugin/fleeting-plugin-googlecloud-linux-arm64" "$(pin upstream_plugin_sha256)")
  install -m 0755 "$f" "$bin/scan/fleeting-plugin-googlecloud"
  echo "bin/: osv-scanner $osv_scanner_version, trivy $trivy_version, govulncheck $govulncheck_version; bin/scan/: the providers, GitLab Runner $runner, the fleeting plugin $plugin"
}

mkdir -p "$bin"
if [ "$security" = yes ]; then security; exit 0; fi
z=$(fetch "https://github.com/opentofu/opentofu/releases/download/v$tofu_version/tofu_${tofu_version}_linux_$arch.zip" "$tofu_sha")
unzip -qo "$z" tofu -d "$bin"
z=$(fetch "https://github.com/terraform-linters/tflint/releases/download/v$tflint_version/tflint_linux_$arch.zip" "$tflint_sha")
unzip -qo "$z" tflint -d "$bin"
plugin=$bin/tflint.d/github.com/terraform-linters/tflint-ruleset-google/$tflint_google_version
mkdir -p "$plugin"
z=$(fetch "https://github.com/terraform-linters/tflint-ruleset-google/releases/download/v$tflint_google_version/tflint-ruleset-google_linux_$arch.zip" "$tflint_google_sha")
unzip -qo "$z" tflint-ruleset-google -d "$plugin"
t=$(fetch "https://github.com/koalaman/shellcheck/releases/download/v$shellcheck_version/shellcheck-v$shellcheck_version.linux.$sc_arch.tar.xz" "$shellcheck_sha")
tar -xJf "$t" -C "$tmp" "shellcheck-v$shellcheck_version/shellcheck"
install -m 0755 "$tmp/shellcheck-v$shellcheck_version/shellcheck" "$bin/shellcheck"
gobuild github.com/zricethezav/gitleaks/v8 "$gitleaks_version" "$gitleaks_sum" github.com/zricethezav/gitleaks/v8 \
  "$klauspost_compress" "$brotli"
GOBIN=$bin GOFLAGS=-mod=mod go install "github.com/mikefarah/yq/v4@$yq_version"
"$here/ci/gitlab-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/kubernetes-provider.sh" "$bin/providers" "linux_$arch"
"$here/ci/runner.sh" "$bin/manager"
chmod 0755 "$bin/tofu" "$bin/tflint" "$plugin/tflint-ruleset-google"
echo "bin/: tofu $("$bin/tofu" version | head -1 | cut -d' ' -f2), tflint $tflint_version (google $tflint_google_version), shellcheck $shellcheck_version, yq $yq_version, gitleaks $gitleaks_version, the gitlab and kubernetes providers (providers/), GitLab Runner and its fleeting plugin (manager/)"
