#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The checks of every push and merge request, one per job, none with a credential or the cloud:
#
#   ci/lint.sh fmt          tofu fmt: every .tf and .tftest.hcl formatted
#   ci/lint.sh validate     tofu validate of each stack (init without its backend, the providers the lock file's)
#   ci/lint.sh tflint       tflint of each stack and module (.tflint.hcl)
#   ci/lint.sh shellcheck   every shell script
#   ci/lint.sh policy       ci/policy.sh on the source: no key, nothing public, nothing a commit does not fix
#   ci/lint.sh all          all of them
#
# Needs bin/ (ci/tools.sh).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH TF_IN_AUTOMATION=1 TF_INPUT=0 TFLINT_PLUGIN_DIR=$here/bin/tflint.d
source "$here/ci/tofurc.sh"
cd "$here" || exit 1
stacks=(stacks/*/)
modules=(modules/settings modules/org modules/projects/ci modules/projects/dev modules/gitlab)
failed=0
step() { echo "== $1"; }
bad() { echo "lint: $*" >&2; failed=1; }

fmt() {
  step "tofu fmt"
  tofu fmt -check -recursive -diff . || bad "tofu fmt: the files above are not formatted (tofu fmt -recursive)"
}
validate() {
  local s
  for s in "${stacks[@]}"; do
    step "tofu validate ${s%/}"
    (cd "$s" && tofu init -backend=false -input=false -lockfile=readonly -no-color >/dev/null && tofu validate -no-color) ||
      bad "tofu validate: ${s%/}"
  done
}
tflint_() {
  local d
  for d in "${stacks[@]}" "${modules[@]}"; do
    step "tflint ${d%/}"
    # A stack's modules are installed by its init (validate); init it here too, so that this check stands alone.
    if [[ $d == stacks/* ]]; then (cd "$d" && tofu init -backend=false -input=false -lockfile=readonly -no-color >/dev/null) || { bad "init: $d"; continue; }; fi
    tflint --chdir="$d" --config="$here/.tflint.hcl" --format=compact || bad "tflint: ${d%/}"
  done
}
shellcheck_() {
  step "shellcheck"
  mapfile -t scripts < <(git ls-files -co --exclude-standard '*.sh' 'tests/stub/*' | sort)
  shellcheck -S warning -s bash "${scripts[@]}" || bad "shellcheck"
}
policy() {
  step "policy"
  ci/policy.sh source modules stacks || bad "policy"
}

case ${1:-} in
  fmt) fmt ;;
  validate) validate ;;
  tflint) tflint_ ;;
  shellcheck) shellcheck_ ;;
  policy) policy ;;
  all) fmt; validate; tflint_; shellcheck_; policy ;;
  *) echo "usage: ci/lint.sh fmt|validate|tflint|shellcheck|policy|all" >&2; exit 2 ;;
esac
[ "$failed" = 0 ] && echo "lint: ${1} passed" || { echo "lint: ${1} failed"; exit 1; }
