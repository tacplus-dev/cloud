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
#
#   ci/tools.sh       # needs curl, unzip, xz, sha256sum and go (ghcr.io/tacplus-dev/tacplus/build); linux arm64 or amd64
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$here/bin
die() { echo "tools.sh: $*" >&2; exit 1; }

tofu_version=1.13.2
tflint_version=0.65.0
tflint_google_version=0.41.0   # .tflint.hcl names the same version
shellcheck_version=0.11.0
yq_version=v4.54.1

case $(uname -m) in
  aarch64|arm64) arch=arm64 sc_arch=aarch64
    tofu_sha=6e815c58a09ee957de606ff48cefad082942e70afc43b737ff975654c54ec453
    tflint_sha=843017c47a98be1de4d88fa038daa293770fe25cd01656c4f08b2e30d1d3b3a0
    tflint_google_sha=d6a527cf803feb46d50e2052f85f5497875a6807040e56e64c26637cfa14b13d
    shellcheck_sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
  x86_64|amd64) arch=amd64 sc_arch=x86_64
    tofu_sha=723bebb0df8411daff1e5fc3862e28ff5581fe5634087f4c29a9aa41d78208b5
    tflint_sha=d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61
    tflint_google_sha=efb3910bbc9f0b90bebd76d475ca6cd2cf04a032f6cddc8fa7a334e5011da6d6
    shellcheck_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
  *) die "no pinned tools for $(uname -m)" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# fetch URL SHA256: the download in $tmp/<its name>, refused unless its SHA-256 is SHA256.
fetch() {
  local f=$tmp/${1##*/}
  curl -sSfL --retry 3 -o "$f" "$1" || die "cannot download $1"
  echo "$2  $f" | sha256sum -c --quiet - >/dev/null 2>&1 || die "$1: SHA-256 $(sha256sum "$f" | cut -c1-64), not the pinned $2"
  echo "$f"
}

mkdir -p "$bin"
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
GOBIN=$bin GOFLAGS=-mod=mod go install "github.com/mikefarah/yq/v4@$yq_version"
chmod 0755 "$bin/tofu" "$bin/tflint" "$plugin/tflint-ruleset-google"
echo "bin/: tofu $("$bin/tofu" version | head -1 | cut -d' ' -f2), tflint $tflint_version (google $tflint_google_version), shellcheck $shellcheck_version, yq $yq_version"
