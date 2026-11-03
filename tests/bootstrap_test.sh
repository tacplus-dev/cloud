#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests bootstrap/bootstrap.sh against a stub gcloud over a directory of state (tests/stub/gcloud): shellcheck
# passes; it runs in the parent folder it is given, and refuses one it cannot see, or no folder at all, before it
# changes anything; its dry run changes nothing and lists what a run would create, every command scoped to the
# parent folder, the bootstrap project or the billing account; a run creates the folder bootstrap under the parent
# folder, the project in it, the bucket (versioned), cloud-admin-pipeline, its rights (none on the parent folder
# or above it: those are the host's grants, which it reports), the pool, the provider (tacplus-dev/cloud's
# protected main only) and the secrets; a second run is a no-op that changes nothing; a run after a partial one
# creates only the rest; and it refuses, before changing anything, a bucket without versioning, a provider with
# another condition, a project in another folder or a bucket of no project.
# Needs bash and jq.
#
#   tests/bootstrap_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/bootstrap/bootstrap.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export PATH=$here/tests/stub:$PATH STUB_LOG=$work/log
BILLING=012345-6789AB-CDEF01
PARENT=111111111111
mutating='(create|create-oidc|update|link|enable|add-iam-policy-binding) '

fresh() { # fresh: a new state: the account, the billing account and the parent folder the host handed over
  export STUB_STATE=$work/state-$RANDOM$RANDOM
  mkdir -p "$STUB_STATE" && echo jody@tacplus.dev > "$STUB_STATE/account" && touch "$STUB_STATE/billing-open"
  echo "$PARENT" > "$STUB_STATE/parent"
}
boot() { : > "$STUB_LOG"; rc=0; "$script" "$@" > "$work/out" 2>&1 || rc=$?; }
changes() { grep -E "^gcloud .*$mutating" "$STUB_LOG" | sed -E 's/ --.*//'; }
none_changed() { [ -z "$(changes)" ] || { fail "$1: it ran $(changes | tr '\n' ';')"; return 1; }; }

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" && ok "shellcheck" || fail "shellcheck"
else fail "no shellcheck (ci/tools.sh)"; fi

fresh
boot --billing-account "$BILLING"
[ "$rc" = 1 ] && grep -q usage "$work/out" && none_changed "no folder" && ok "no --folder: refused, nothing changed" || fail "no folder: rc $rc: $(cat "$work/out")"
boot --folder "folders/$PARENT" --billing-account "$BILLING"
[ "$rc" = 1 ] && grep -q usage "$work/out" && none_changed "folders/ID" && ok "a folder given other than by its numeric ID is refused" || fail "--folder folders/ID: rc $rc"
boot --folder 999 --billing-account "$BILLING"
[ "$rc" = 1 ] && grep -q 'the folder 999 does not exist, or jody@tacplus.dev cannot see it' "$work/out" && none_changed "a folder it cannot see" &&
  ok "a parent folder it cannot see is refused, nothing changed" || fail "folder 999: rc $rc: $(cat "$work/out")"

boot --folder "$PARENT" --billing-account "$BILLING" --dry-run
[ "$rc" = 0 ] && none_changed "dry run" && grep -q 'dry run: [0-9]* step(s) would run' "$work/out" &&
  grep -q 'would run: gcloud iam workload-identity-pools providers create-oidc tacplus-dev-cloud' "$work/out" &&
  ok "the dry run changes nothing, and shows every step" || fail "dry run: rc $rc: $(cat "$work/out")"
grep -qx "would run: gcloud resource-manager folders create --display-name=bootstrap --folder=$PARENT --format=none " "$work/out" &&
  ok "the dry run creates the folder bootstrap under the parent folder" || fail "the folder's creation: $(grep 'folders create' "$work/out")"
# Every command it would run is scoped to the parent folder, what it creates there, or the billing account.
unscoped=$(grep '^would run: ' "$work/out" | grep -vE -- "--folder=$PARENT |--project=tacplus-bootstrap |^would run: gcloud (projects (create|add-iam-policy-binding)|billing projects link) tacplus-bootstrap |^would run: gcloud billing accounts add-iam-policy-binding $BILLING |gs://tacplus-bootstrap-tofu-state ")
[ -z "$unscoped" ] && ok "every command of the dry run is folder-scoped" || fail "commands not scoped to the folder: $unscoped"
grep -iE 'organi[z]ation' "$STUB_LOG" && fail "it looked at or asked for an organi""zation" || ok "it neither reads nor asks for anything above the parent folder"
n_dry=$(grep -c '^would run: ' "$work/out")

boot --folder "$PARENT" --billing-account "$BILLING"
[ "$rc" = 0 ] && ok "the first run" || fail "the first run: rc $rc: $(cat "$work/out")"
[ "$(changes | wc -l)" = "$n_dry" ] && ok "it ran what the dry run said ($n_dry steps)" || fail "it ran $(changes | wc -l) steps, the dry run said $n_dry"
grep -q '^+ gcloud ' "$work/out" && grep -q '^bootstrap: created: ' "$work/out" && ok "it prints each command and what it created" || fail "no command or creation printed"
s=$STUB_STATE
[ "$(cat "$s/folder")" = folders/456 ] && [ "$(cat "$s/folder-parent")" = "folders/$PARENT" ] && jq -e '.parent == {type: "folder", id: "456"}' "$s/project" >/dev/null &&
  ok "the folder bootstrap is under the parent folder, the project in it" || fail "the project: $(cat "$s/project")"
[ "$(cat "$s/billing-link")" = "billingAccounts/$BILLING" ] && ok "the project is billed" || fail "billing: $(cat "$s/billing-link")"
jq -e '.versioning_enabled and .uniform_bucket_level_access and .public_access_prevention == "enforced" and .location == "US-CENTRAL1"' "$s/bucket" >/dev/null &&
  ok "the state bucket is versioned, uniform, private, in us-central1" || fail "the bucket: $(cat "$s/bucket")"
grep -q 'buckets create gs://tacplus-bootstrap-tofu-state ' "$STUB_LOG" && ok "the bucket is gs://tacplus-bootstrap-tofu-state" || fail "the bucket's name"
for svc in iam.googleapis.com sts.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com; do
  grep -qx "$svc" "$s/services" || fail "the API $svc is not enabled"
done
sa=serviceAccount:cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com
grep -qx "roles/billing.user $sa" "$s/iam-billing" && grep -qx "roles/storage.objectAdmin $sa" "$s/iam-bucket" &&
  grep -qx "roles/secretmanager.secretAccessor $sa" "$s/iam-project" && ok "cloud-admin-pipeline's rights: billing, state bucket, secrets" ||
  fail "cloud-admin-pipeline's rights"
[ "$(cat "$s"/iam-* | grep -c "$sa")" = 3 ] && [ ! -f "$s/iam-parent" ] &&
  ok "no other right: nothing on the parent folder (the host's grants)" || fail "other rights: $(grep -l "$sa" "$s"/iam-*)"
host_roles="roles/resourcemanager.folderAdmin roles/resourcemanager.projectCreator roles/owner"
grep -qF "the host organization grants cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com $host_roles on folders/$PARENT" "$work/out" &&
  ok "it says what the host still grants, on the parent folder" || fail "the host's grants are not reported: $(cat "$work/out")"
grep -qx "roles/iam.workloadIdentityUser principalSet://iam.googleapis.com/projects/789/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cloud" "$s/iam-sa" &&
  [ "$(wc -l < "$s/iam-sa")" = 1 ] && ok "only tacplus-dev/cloud's jobs may become cloud-admin-pipeline" || fail "the account's IAM: $(cat "$s/iam-sa")"
jq -e '.attributeCondition == "assertion.project_path == '"'tacplus-dev/cloud'"' && assertion.ref_type == '"'branch'"' && assertion.ref == '"'main'"' && assertion.ref_protected == '"'true'"'" and .oidc.issuerUri == "https://gitlab.com" and .attributeMapping["attribute.project_path"] == "assertion.project_path"' "$s/provider" >/dev/null &&
  ok "the provider admits gitlab.com's tacplus-dev/cloud, protected main, only" || fail "the provider: $(cat "$s/provider")"
for sec in gitlab-token tacplus-reader-app-id tacplus-reader-installation-id; do [ -f "$s/secret-$sec" ] || fail "no secret $sec"; done
grep -q 'secrets create gitlab-token .*--replication-policy=user-managed --locations=us-central1' "$STUB_LOG" &&
  ok "the secrets, in us-central1" || fail "the secrets' replication"
grep -q 'projects/789/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-cloud' "$work/out" &&
  ok "it prints GCP_WIF_PROVIDER" || fail "no GCP_WIF_PROVIDER printed"
grep -q 'sa_key\|service-accounts keys' "$STUB_LOG" && fail "it made a key" || ok "no key anywhere"

boot --folder "$PARENT" --billing-account "$BILLING"
[ "$rc" = 0 ] && none_changed "the second run" && grep -q 'nothing to do' "$work/out" &&
  ok "a second run is a no-op" || fail "second run: rc $rc: $(cat "$work/out")"
boot --folder "$PARENT" --billing-account "$BILLING" --dry-run
[ "$rc" = 0 ] && ! grep -q '^would run' "$work/out" && ok "and its dry run has nothing to run" || fail "dry run after: $(grep '^would run' "$work/out")"

fresh
"$script" --folder "$PARENT" --billing-account "$BILLING" >/dev/null 2>&1
for role in $host_roles; do echo "$role $sa" >> "$STUB_STATE/iam-parent"; done
boot --folder "$PARENT" --billing-account "$BILLING"
[ "$rc" = 0 ] && none_changed "the host's grants in place" && grep -q "the host organization's grants to cloud-admin-pipeline on folders/$PARENT are in place" "$work/out" &&
  ! grep -q 'the host organization grants' "$work/out" && ok "with the host's grants in place it says so" || fail "host's grants: rc $rc: $(cat "$work/out")"

fresh
"$script" --folder "$PARENT" --billing-account "$BILLING" >/dev/null 2>&1
rm "$STUB_STATE/provider" "$STUB_STATE/secret-gitlab-token"
boot --folder "$PARENT" --billing-account "$BILLING"
[ "$rc" = 0 ] && [ "$(changes | tr '\n' ';')" = "gcloud iam workload-identity-pools providers create-oidc tacplus-dev-cloud;gcloud secrets create gitlab-token;" ] &&
  ok "after a partial run it creates only the rest" || fail "partial: rc $rc, ran [$(changes | tr '\n' ';')]"

refusal() { # refusal WHAT EXPECTED SETUP: a finished state changed by SETUP is refused, before any change
  local what=$1 want=$2
  fresh
  "$script" --folder "$PARENT" --billing-account "$BILLING" >/dev/null 2>&1
  rm -f "$STUB_STATE/secret-gitlab-token"   # something left to do: the refusal must come before it
  (cd "$STUB_STATE" && eval "$3")
  boot --folder "$PARENT" --billing-account "$BILLING"
  [ "$rc" = 1 ] && grep -q "$want" "$work/out" && grep -q 'nothing was changed' "$work/out" && none_changed "$what" &&
    ok "refused, nothing changed: $what" || fail "$what: rc $rc, ran [$(changes | tr '\n' ';')]: $(cat "$work/out")"
}
refusal "a bucket without versioning" "is not in us-central1, versioned" 'jq ".versioning_enabled = false" bucket > b && mv b bucket'
refusal "a provider with another condition" "the provider tacplus-dev-cloud is not the one" 'jq ".attributeCondition = \"true\"" provider > p && mv p provider'
refusal "a provider with an audience of its own" "the provider tacplus-dev-cloud is not the one" 'jq ".oidc.allowedAudiences = [\"x\"]" provider > p && mv p provider'
refusal "the project in another folder" "is in folders/999, not in the folder" 'jq ".parent.id = \"999\"" project > p && mv p project'
refusal "the project billed elsewhere" "is billed to billingAccounts/OTHER" 'echo billingAccounts/OTHER > billing-link'
refusal "the project being deleted" "is DELETE_REQUESTED" 'jq ".lifecycleState = \"DELETE_REQUESTED\"" project > p && mv p project'
fresh
echo '{"location":"US-CENTRAL1","versioning_enabled":true,"uniform_bucket_level_access":true,"public_access_prevention":"enforced"}' > "$STUB_STATE/bucket"
boot --folder "$PARENT" --billing-account "$BILLING"
[ "$rc" = 1 ] && grep -q 'exists, but the project tacplus-bootstrap does not' "$work/out" && none_changed "someone else's bucket" &&
  ok "refused, nothing changed: the bucket's name taken while the project does not exist" || fail "a bucket of no project: rc $rc: $(cat "$work/out")"

boot --billing-account nope
[ "$rc" = 1 ] && grep -q usage "$work/out" && ok "a malformed billing account is refused" || fail "billing account nope: rc $rc"
boot --folder "$PARENT" --billing-account "$BILLING" --verification-token x
[ "$rc" = 1 ] && grep -q usage "$work/out" && ok "an unknown option is refused" || fail "--verification-token: rc $rc"
exit "$failed"
