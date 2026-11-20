#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests that the names agree wherever they are written: modules/settings (what the stacks read), the stacks'
# backends (state in the bootstrap bucket, one prefix per stack), bootstrap/bootstrap.sh (what it creates), the
# GitLab CI file (the account the jobs become), ci/lib.sh (the GitLab token's secret, by version, and whether the
# audit reads the cluster autoscaler's log, #85) and the README (the host's grants to the pipeline, neither owner nor
# editor, #78); and that the parent folder is the stacks' input, written nowhere. Needs bash.
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
same "the region" "$(sed -n '/output "region"/,/^}/s/^ *value *= *"\(.*\)"$/\1/p' "$settings")" "$(script REGION)"
same "the GitLab project" "$(sed -n '/output "gitlab_project"/,/^}/s/^ *value *= *"\(.*\)"$/\1/p' "$settings")" "$(script GITLAB_PROJECT)"
same "the jobs' account" "$(setting pipeline_sa)" "$(sed -n 's/^  GCP_DEPLOY_SA: //p' "$here/ci/gitlab-project.gitlab-ci.yml")"
# The host's grants to the pipeline (#78): the README's list is the bootstrap's HOST_ROLES, and neither is owner or editor.
host_roles=$(sed -n '/^HOST_ROLES=(/,/^)/s/^  \(roles\/[^ ]*\).*/\1/p' "$here/bootstrap/bootstrap.sh" | sort | tr '\n' ' ')
readme_roles=$(sed -n '/^- \*\*For `cloud-admin-pipeline`\*\*/,/^- \*\*The org policies/s/^  - `\(roles\/[^`]*\)`:.*/\1/p' "$here/README.md" | sort | tr '\n' ' ')
same "the host's grants to the pipeline" "$host_roles" "$readme_roles"
grep -qE 'roles/(owner|editor) ' <<< "$host_roles " && fail "the host's grants include owner or editor: $host_roles" ||
  ok "the host's grants are neither owner nor editor"

gitlab_secret=$(setting gitlab_token_secret)
[[ $gitlab_secret == "projects/$(script PROJECT)/secrets/gitlab-token/versions/"[0-9]* ]] &&
  ok "the GitLab token is bootstrap's secret gitlab-token, by version" || fail "gitlab_token_secret: $gitlab_secret"
# shellcheck source=ci/lib.sh
same "ci/lib.sh reads that version" "$(source "$here/ci/lib.sh" && ci_gitlab_secret)" "$gitlab_secret"
# The cluster autoscaler's log (#85): ci/lib.sh's ci_autoscaler_log says modules/settings' autoscaler_log, true or
# false, and fails on anything else (a copy of the two files, the setting rewritten).
autoscaler_log=$(sed -n '/^output "autoscaler_log"/,/^}/s/^ *value *= *\([a-z]*\)$/\1/p' "$settings")
same "ci/lib.sh reads autoscaler_log" "$(source "$here/ci/lib.sh" && ci_autoscaler_log)" "$autoscaler_log"
work=$(mktemp -d)
mkdir -p "$work/ci" "$work/modules/settings" "$work/tmp"
cp "$here/ci/lib.sh" "$work/ci/"
for v in true false '"true"' 'var.autoscaler_log' ''; do
  sed "/^output \"autoscaler_log\"/,/^}/s/^\( *value *= *\).*\$/\1$v/" "$settings" > "$work/modules/settings/main.tf"
  got=$(ci_tmp=$work/tmp && source "$work/ci/lib.sh" && ci_autoscaler_log 2>&1) && rc=0 || rc=$?
  case $v in
    true | false) [ "$rc" = 0 ] && [ "$got" = "$v" ] && ok "ci_autoscaler_log says $v" || fail "ci_autoscaler_log, the setting $v: rc $rc, [$got]" ;;
    *) [ "$rc" != 0 ] && [[ $got == *"neither true nor false"* ]] && ok "ci_autoscaler_log fails on [$v]" || fail "ci_autoscaler_log, the setting [$v]: rc $rc, [$got]" ;;
  esac
done
rm -rf "$work"

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
# The parent folder is an input, never written here (#8): settings take it, with no default but null, and each stack
# that builds under it takes it as its variable, with no default, passed to the settings.
[ "$(sed -n '/^variable "parent_folder"/,/^}/s/^ *default *= *//p' "$settings")" = null ] &&
  ok "settings take the parent folder, with no default but null" || fail "settings' parent_folder has a default"
for s in "$here"/stacks/*/; do
  name=$(basename "$s")
  grep -q 'module.settings.parent_folder' "$s"/*.tf || continue
  v=$(sed -n '/^variable "parent_folder"/,/^}/p' "$s/main.tf")
  [ -n "$v" ] && ! grep -q 'default' <<< "$v" && grep -q '^  parent_folder = var.parent_folder$' "$s/main.tf" ||
    fail "stacks/$name does not take the parent folder as its variable, with no default, for the settings"
done
ok "the stacks under the parent folder take it as their variable parent_folder"
grep -q "required_version = \"= $(sed -n 's/^tofu_version=//p' "$here/ci/tools.sh")\"" "$here/stacks/folder/versions.tf" &&
  ok "the stacks pin the OpenTofu that ci/tools.sh installs" || fail "the stacks' OpenTofu is not ci/tools.sh's"
[ "$(sed -n 's/^tflint_google_version=\([0-9.]*\).*/\1/p' "$here/ci/tools.sh")" = "$(sed -n 's/^ *version *= *"\(.*\)"$/\1/p' "$here/.tflint.hcl")" ] &&
  ok ".tflint.hcl names the google ruleset ci/tools.sh installs" || fail ".tflint.hcl and ci/tools.sh disagree on the google ruleset"
exit "$failed"
