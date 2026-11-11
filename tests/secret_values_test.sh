#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests that the project modules and their stacks make their secrets with no version (#28, #37): a value added by a
# pipeline or by hand (the fleet secrets, the runners' tokens, the Google sign-in client's secret, which Jody adds in the
# Console) is never in this repository, a plan or the state. Only the gitlab stack writes versions: the runners'
# registration tokens it is given by GitLab (modules/gitlab). Needs bash and git.
#
#   tests/secret_values_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

mapfile -t files < <(git -C "$here" ls-files -co --exclude-standard -- 'modules/projects/*.tf' 'stacks/folder/*.tf' 'stacks/ci/*.tf' 'stacks/dev/*.tf')
[ "${#files[@]}" -gt 0 ] || { echo "FAIL no files"; exit 1; }
found=$(cd "$here" && grep -nE '^(resource|ephemeral) "google_secret_manager_(regional_)?secret_version"' "${files[@]}")
[ -z "$found" ] && ok "the project modules and stacks make no secret version (${#files[@]} files)" ||
  fail "a project module or stack writes a secret's value: $found"
exit "$failed"
