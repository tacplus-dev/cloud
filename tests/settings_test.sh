#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests that the names agree wherever they are written: modules/settings (what the stacks read), the stacks'
# backends (state in the bootstrap bucket, one prefix per stack), bootstrap/bootstrap.sh (what it creates), the
# GitLab CI file (the account the jobs become) and ci/lib.sh (the GitLab token's secret, by version). Needs bash.
#
#   tests/settings_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
settings=$here/modules/settings/main.tf
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
# setting NAME: the string value of `NAME = "..."` in modules/settings, which must be written once.
setting() {
  local v
  v=$(sed -n "s|^ *$1 *= *\"\\([^\"]*\\)\"\$|\\1|p" "$settings")
  [ "$(printf '%s\n' "$v" | grep -c .)" = 1 ] || { echo "settings: $1 is not one string: [$v]" >&2; return 1; }
  echo "$v"
}
# script NAME: the value of NAME=... in bootstrap.sh.
script() { sed -n "s|^$1=\\(.*\\)\$|\\1|p" "$here/bootstrap/bootstrap.sh"; }
same() { # same WHAT A B
  [ "$2" = "$3" ] && [ -n "$2" ] && ok "$1: $2" || fail "$1: [$2] and [$3]"
}

same "the folder" "$(setting folder)" "$(script FOLDER)"
same "the bootstrap project" "$(setting project)" "$(script PROJECT)"
same "the state bucket" "$(setting state_bucket)" "$(script BUCKET)"
same "the pipeline's account" "$(setting pipeline_sa)" "$(script SA_ID)@$(script PROJECT).iam.gserviceaccount.com"
same "the pool" "$(setting wif_pool)" "$(script POOL)"
same "the provider" "$(setting wif_provider)" "$(script PROVIDER)"
same "the domain" "$(sed -n '/output "domain"/,/^}/s/^ *value *= *"\(.*\)"$/\1/p' "$settings")" "$(script DOMAIN)"
same "the region" "$(sed -n '/output "region"/,/^}/s/^ *value *= *"\(.*\)"$/\1/p' "$settings")" "$(script REGION)"
same "the GitLab project" "$(sed -n '/output "gitlab_project"/,/^}/s/^ *value *= *"\(.*\)"$/\1/p' "$settings")" "$(script GITLAB_PROJECT)"
same "the jobs' account" "$(setting pipeline_sa)" "$(sed -n 's/^  GCP_DEPLOY_SA: //p' "$here/ci/gitlab-project.gitlab-ci.yml")"

gitlab_secret=$(setting gitlab_token_secret)
[[ $gitlab_secret == "projects/$(script PROJECT)/secrets/gitlab-token/versions/"[0-9]* ]] &&
  ok "the GitLab token is bootstrap's secret gitlab-token, by version" || fail "gitlab_token_secret: $gitlab_secret"
# shellcheck source=ci/lib.sh
same "ci/lib.sh reads that version" "$(source "$here/ci/lib.sh" && ci_gitlab_secret)" "$gitlab_secret"

for s in "$here"/stacks/*/; do
  name=$(basename "$s")
  b=$(sed -n '/backend "gcs"/,/}/s/^ *bucket *= *"\(.*\)"$/\1/p' "$s/versions.tf")
  p=$(sed -n '/backend "gcs"/,/}/s/^ *prefix *= *"\(.*\)"$/\1/p' "$s/versions.tf")
  [ "$b" = "$(setting state_bucket)" ] && [ "$p" = "$name" ] || fail "stacks/$name: state in gs://$b/$p"
  [ -f "$s/.terraform.lock.hcl" ] || fail "stacks/$name has no lock file"
  grep -q '^  required_version = "= [0-9.]*"$' "$s/versions.tf" || fail "stacks/$name does not pin OpenTofu exactly"
  [ -z "$(grep -E '^ +version += ' "$s/versions.tf" | grep -vE '"[0-9]+\.[0-9]+\.[0-9]+"$')" ] || fail "stacks/$name does not pin a provider exactly"
done
ok "each stack: its state in the bootstrap bucket under its name, OpenTofu and its providers pinned, a lock file"
grep -q "required_version = \"= $(sed -n 's/^tofu_version=//p' "$here/ci/tools.sh")\"" "$here/stacks/org/versions.tf" &&
  ok "the stacks pin the OpenTofu that ci/tools.sh installs" || fail "the stacks' OpenTofu is not ci/tools.sh's"
[ "$(sed -n 's/^tflint_google_version=\([0-9.]*\).*/\1/p' "$here/ci/tools.sh")" = "$(sed -n 's/^ *version *= *"\(.*\)"$/\1/p' "$here/.tflint.hcl")" ] &&
  ok ".tflint.hcl names the google ruleset ci/tools.sh installs" || fail ".tflint.hcl and ci/tools.sh disagree on the google ruleset"
exit "$failed"
