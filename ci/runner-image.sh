#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The pools' image bump (#4, README The runners' image): after a bake, pins its image by name in modules/settings
# (runner_image) and writes the startup-script the pools run on it, looper's runner/startup.sh at the commit the
# bake ran, to modules/projects/ci/files/runner-startup.sh with its commit and SHA-256. Nothing else changes: commit
# the result, and the pipeline plans and applies it. A revert is the rollback, while the bake keeps the old image.
#
#   ci/runner-image.sh NAME COMMIT   # NAME: the bake's last line, runner-arm64-docker-<date>-<time>; COMMIT: looper's
#
# RUNNER_IMAGE_LOOPER_URL: where COMMIT/runner/startup.sh is read (https://raw.githubusercontent.com/tacplus-dev/looper).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
settings=$here/modules/settings/main.tf
startup=$here/modules/projects/ci/files/runner-startup.sh
url=${RUNNER_IMAGE_LOOPER_URL:-https://raw.githubusercontent.com/tacplus-dev/looper}
die() { echo "runner-image.sh: $*" >&2; exit 1; }

[ $# = 2 ] || die "usage: ci/runner-image.sh NAME COMMIT"
name=$1 commit=$2
[[ $name =~ ^runner-arm64-docker-[0-9]{8}-[0-9]{6}$ ]] ||
  die "[$name] is not an image's name, runner-arm64-docker-<date>-<time> (never a family, nor a path)"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "[$commit] is not a full looper commit hash"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --proto '=https,file' -o "$work/startup.sh" "$url/$commit/runner/startup.sh" ||
  die "no runner/startup.sh at looper $commit ($url)"
sha=$(sha256sum < "$work/startup.sh" | cut -d' ' -f1)

# The three values, each written once in runner_image's block.
block='/^output "runner_image"/,/^}/'
for key in image looper_commit startup_sha256; do
  [ "$(sed -n "${block}{/^    $key *= /p}" "$settings" | wc -l)" = 1 ] || die "$settings: runner_image.$key is not one line"
done
sed -e "${block}s|^\\(    image *= *\\).*\$|\\1\"$name\"|" \
  -e "${block}s|^\\(    looper_commit *= *\\).*\$|\\1\"$commit\"|" \
  -e "${block}s|^\\(    startup_sha256 *= *\\).*\$|\\1\"$sha\"|" "$settings" > "$work/main.tf"
cp "$work/main.tf" "$settings"
cp "$work/startup.sh" "$startup"
echo "runner-image.sh: the pools boot $name, with looper $commit's runner/startup.sh ($sha): commit modules/settings and $(basename "$startup")"
