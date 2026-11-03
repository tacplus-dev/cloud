#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The repository's tests: every tests/*_test.sh, then `tofu test` of each stack (its plan against a stub
# organization and empty projects: mock providers, no credentials). The test job's, and the local gate. Need bin/
# (ci/tools.sh), bash, git, jq, sha256sum.
#
#   ci/checks.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0
source "$here/ci/tofurc.sh"
failed=0
for t in "$here"/tests/*_test.sh; do
  echo "== ${t#"$here"/}"
  "$t" || failed=1
done
for s in "$here"/stacks/*/; do
  echo "== tofu test ${s#"$here"/}"
  (cd "$s" && tofu init -backend=false -input=false -lockfile=readonly -no-color >/dev/null && tofu test -no-color) || failed=1
done
[ "$failed" = 0 ] && echo "all checks passed" || { echo "checks failed"; exit 1; }
