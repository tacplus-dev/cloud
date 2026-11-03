#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Writes each stack's .terraform.lock.hcl: the pinned version of each provider (stacks/*/versions.tf) and its
# hashes for every platform the pipeline and its people run on. Run it after changing a provider's version, and
# commit the lock files; the pipeline never writes them (ci/tofu.sh inits with -lockfile=readonly).
#
#   ci/lock.sh        # needs bin/tofu (ci/tools.sh) and the OpenTofu registry
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH
for s in "$here"/stacks/*/; do
  (cd "$s" && tofu providers lock -platform=linux_arm64 -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 >/dev/null)
  echo "lock.sh: ${s#"$here"/}.terraform.lock.hcl"
done
