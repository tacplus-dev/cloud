#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Writes each stack's .terraform.lock.hcl: the pinned version of each provider (stacks/*/versions.tf) and its
# hashes for every platform the pipeline and its people run on. Run it after changing a provider's version, and
# commit the lock files; the pipeline never writes them (ci/tofu.sh inits with -lockfile=readonly). gitlabhq/gitlab,
# hashicorp/kubernetes, hashicorp/google and ippontech/anthropic are our own builds (ci/gitlab-provider.sh,
# ci/kubernetes-provider.sh, ci/google-provider.sh, ci/anthropic-provider.sh): their hashes are those of the builds,
# for every platform, and none of upstream's; every other provider's are its registry's.
#
#   ci/lock.sh        # needs bin/tofu (ci/tools.sh), the OpenTofu registry, and git and go (our providers)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH
source "$here/ci/tofurc.sh"
platforms=(linux_arm64 linux_amd64 darwin_arm64 darwin_amd64)
flags=("${platforms[@]/#/-platform=}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$here/ci/gitlab-provider.sh" "$tmp/mirror" "${platforms[@]}"
"$here/ci/kubernetes-provider.sh" "$tmp/mirror" "${platforms[@]}"
"$here/ci/google-provider.sh" "$tmp/mirror" "${platforms[@]}"
"$here/ci/anthropic-provider.sh" "$tmp/mirror" "${platforms[@]}"
for s in "$here"/stacks/*/; do
  mapfile -t sources < <(sed -n 's/^ *source *= *"\(.*\)"$/\1/p' "$s/versions.tf")
  registry=() own=()
  for p in "${sources[@]}"; do if [[ $p = gitlabhq/gitlab || $p = hashicorp/kubernetes || $p = hashicorp/google || $p = ippontech/anthropic ]]; then own+=("$p"); else registry+=("$p"); fi; done
  # From nothing, so that no hash of an earlier build or of upstream's stays.
  rm -f "$s/.terraform.lock.hcl"
  (cd "$s" && tofu get >/dev/null && { [ ${#registry[@]} = 0 ] || tofu providers lock "${flags[@]}" "${registry[@]}" >/dev/null; } &&
    { [ ${#own[@]} = 0 ] || tofu providers lock -fs-mirror="$tmp/mirror" "${flags[@]}" "${own[@]}" >/dev/null; })
  echo "lock.sh: ${s#"$here"/}.terraform.lock.hcl"
done
