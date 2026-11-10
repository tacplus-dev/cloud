#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/gitlab-project.gitlab-ci.yml and ci/pin.sh: the file parses; every job runs on the project's runner (tag
# cloud), in the pinned image (by digest). The pipelines GitLab makes of it, by its workflow and its jobs' rules
# (`extends` resolved): fmt, validate, tflint, shellcheck, policy and test in every pipeline, so every push and
# merge request, with security on the nightly schedule too; plan and apply of each stack on main only, never from a merge request or a schedule; no job is
# manual (production is not built: nothing waits for Jody); the nightly schedule has drift and no plan or apply.
# Each apply needs its own plan and applies its saved plan, in its stack's environment, one at a time; the stacks
# run in order (folder, then ci and dev, then gitlab); the jobs that reach GCP have their id_token, and no other job
# does; drift never applies. ci/pin.sh sets CLOUD_COMMIT and nothing else, --check accepts its output and refuses
# any other change, and the jobs refuse an empty CLOUD_COMMIT; ci/lib.sh gives the stacks the parent folder from
# GCP_PARENT_FOLDER, and refuses a job without a valid one, and the dev stack the runners' token adders from
# GCP_RUNNER_TOKEN_ADDERS (#18), refusing one that is not a member. Needs bash and yq.
#
#   tests/ci_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/ci/gitlab-project.gitlab-ci.yml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

yq -e '.' "$src" >/dev/null 2>&1 && ok "the CI file parses" || { echo "FAIL the CI file does not parse"; exit 1; }
# The file with every `extends` resolved as GitLab does (a deep merge, the job's own keys winning), two levels.
ci=$work/resolved.yml
yq '. as $r | with(.[] | select(tag == "!!map" and has("extends")); . = ($r[.extends] * .))' "$src" |
  yq '. as $r | with(.[] | select(tag == "!!map" and has("extends")); . = ($r[.extends] * .))' > "$ci"
q() { yq -r "$1" "$ci"; }

mapfile -t jobs < <(q 'keys | .[] | select(test("^(stages|variables|workflow|default)$|^\\.") | not)')
want="tools,fmt,validate,tflint,shellcheck,policy,test,security,plan:folder,apply:folder,plan:ci,apply:ci,plan:dev,apply:dev,plan:gitlab,apply:gitlab,drift,"
[ "$(printf '%s,' "${jobs[@]}")" = "$want" ] && ok "the jobs: ${jobs[*]}" || fail "the jobs are: ${jobs[*]}"
stages=" $(q '.stages | join(" ")') "
for j in "${jobs[@]}"; do
  [[ $stages == *" $(q ".[\"$j\"].stage") "* ]] || fail "$j: its stage $(q ".[\"$j\"].stage") is not in stages"
  [ "$(q ".[\"$j\"].tags // \"\"")" = "" ] || fail "$j: sets its own tags"
  [ "$(q ".[\"$j\"].image // \"\"")" = "" ] || fail "$j: sets its own image"
done
[ "$(q '.default.tags | join(",")')" = cloud ] && ok "every job runs on the runner tagged cloud" || fail "default tags: $(q '.default.tags')"
[[ $(q '.default.image') =~ ^[^@]+:[0-9.]+@sha256:[0-9a-f]{64}$ ]] && ok "the image is pinned by digest" || fail "the image: $(q '.default.image')"
# build.lock pins tacplus-dev/build's builds to that same image (#25), read as its plan reads it, and gates.yaml
# gives them the gates to run in it: its full set, the local gate's command.
lock=$(sed -n 's/^build_image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$here/build.lock" 2>/dev/null | head -1)
[ "$lock" = "$(q '.default.image')" ] && ok "build.lock pins the CI image" || fail "build.lock's build_image [$lock] is not the CI image $(q '.default.image')"
[ "$(yq -r '.full.run // ""' "$here/gates.yaml" 2>/dev/null)" = "ci/tools.sh && ci/lint.sh all && ci/checks.sh" ] &&
  ok "gates.yaml's full runs the tools, the lint and the checks" || fail "gates.yaml's full: [$(yq -r '.full.run' "$here/gates.yaml" 2>&1)]"

# cond EXPR: whether the rules:if expression EXPR holds under the variables set: clauses joined by &&, each $VAR
# (set and not empty), $VAR == "string", $VAR == $VAR or $VAR =~ /regex/, the forms the file uses. Any other
# form fails the test, so that one the file starts using is added here first. (tacplus-dev/cluster's ci_test.sh.)
cond() {
  local rest=$1 c re_var='^\$([A-Z_]+)$' re_str='^\$([A-Z_]+) == "([^"]*)"$' re_eq='^\$([A-Z_]+) == \$([A-Z_]+)$' re_m='^\$([A-Z_]+) =~ /(.*)/$'
  while [ -n "$rest" ]; do
    c=${rest%% && *}
    [ "$c" = "$rest" ] && rest= || rest=${rest#* && }
    if [[ $c =~ $re_var ]]; then [ -n "${!BASH_REMATCH[1]:-}" ] || return 1
    elif [[ $c =~ $re_str ]]; then [ "${!BASH_REMATCH[1]:-}" = "${BASH_REMATCH[2]}" ] || return 1
    elif [[ $c =~ $re_eq ]]; then [ "${!BASH_REMATCH[1]:-}" = "${!BASH_REMATCH[2]:-}" ] || return 1
    elif [[ $c =~ $re_m ]]; then [[ ${!BASH_REMATCH[1]:-} =~ ${BASH_REMATCH[2]} ]] || return 1
    else echo "cond: an expression this test cannot evaluate: [$c]" >&2; return 2; fi
  done
}
# when PATH: the when of the first of PATH's rules that holds ("never" if none does), on_success if it has no rules.
when() {
  local n i r
  n=$(q "$1.rules | length")
  [ "$n" = 0 ] && { echo on_success; return; }
  for ((i = 0; i < n; i++)); do
    r=0
    [ "$(q "$1.rules[$i].if // \"\"")" = "" ] || { cond "$(q "$1.rules[$i].if")"; r=$?; }
    [ "$r" = 2 ] && return 2
    [ "$r" = 0 ] && { q "$1.rules[$i].when // \"on_success\""; return; }
  done
  echo never
}
# pipeline SOURCE BRANCH [VAR=VALUE...]: the jobs of the pipeline GitLab makes for SOURCE on BRANCH with those
# variables, "JOB:WHEN" each, comma-separated; "none" when the workflow makes no pipeline.
pipeline() {
  (
    unset CI_OPEN_MERGE_REQUESTS
    export CI_PIPELINE_SOURCE=$1 CI_COMMIT_BRANCH=$2; shift 2
    [ "$CI_PIPELINE_SOURCE" = merge_request_event ] && CI_COMMIT_BRANCH=
    # shellcheck disable=SC2163 # each is VAR=VALUE
    for v in "$@"; do export "$v"; done
    [ "$(when .workflow)" = never ] && { echo none; exit; }
    out=
    for j in "${jobs[@]}"; do
      w=$(when ".[\"$j\"]") || exit 1
      [ "$w" = never ] || out+="$j:$w,"
    done
    echo "$out"
  )
}

lint="tools:on_success,fmt:on_success,validate:on_success,tflint:on_success,shellcheck:on_success,policy:on_success,test:on_success,security:on_success,"
stacks="plan:folder:on_success,apply:folder:on_success,plan:ci:on_success,apply:ci:on_success,plan:dev:on_success,apply:dev:on_success,plan:gitlab:on_success,apply:gitlab:on_success,"
check() { # check WHAT WANT SOURCE BRANCH [VAR=VALUE...]
  local what=$1 want=$2 got; shift 2
  got=$(pipeline "$@")
  [ "$got" = "$want" ] && ok "$what" || { fail "$what"; echo "     want $want"; echo "     got  $got"; }
}
check "a push to main: the checks, then plan and apply of every stack, none manual" "$lint$stacks" push main
check "a run from the web on main: the same" "$lint$stacks" web main
check "an API run on main: the same" "$lint$stacks" api main
check "a merge request: the checks only" "$lint" merge_request_event ""
check "a push to a branch: the checks only" "$lint" push some-branch
check "a push to a branch with a merge request open: no pipeline (the merge request's runs)" none push some-branch CI_OPEN_MERGE_REQUESTS=1
check "the nightly schedule on main: the checks and drift, no plan or apply" "${lint}drift:on_success," schedule main
check "a schedule on a branch: the checks only" "$lint" schedule some-branch
check "a trigger: no pipeline" none trigger main

for s in folder ci dev gitlab; do
  p="plan:$s" a="apply:$s"
  [ "$(q ".[\"$a\"].needs | join(\",\")")" = "tools,$p" ] || fail "$a needs $(q ".[\"$a\"].needs | join(\",\")"), not tools and $p"
  [ "$(q ".[\"$a\"].variables.STACK")" = "$s" ] && [ "$(q ".[\"$p\"].variables.STACK")" = "$s" ] || fail "$p or $a is not for the stack $s"
  [[ $(q ".[\"$a\"].script | join(\" \")") == *'ci/tofu.sh apply "$STACK"' ]] || fail "$a does not apply the saved plan: $(q ".[\"$a\"].script")"
  [[ $(q ".[\"$p\"].script | join(\" \")") == *'ci/tofu.sh plan "$STACK"' ]] || fail "$p does not save its plan: $(q ".[\"$p\"].script")"
  [ "$(q ".[\"$p\"].artifacts.paths | join(\",\")")" = "src/plans/" ] && [ "$(q ".[\"$p\"].artifacts.access")" = developer ] ||
    fail "$p: its plan is not an artifact for project members only"
  [ "$(q ".[\"$a\"].environment.name")" = '$STACK' ] && [ "$(q ".[\"$a\"].resource_group")" = 'cloud-$STACK' ] ||
    fail "$a: not in its stack's environment, one at a time"
done
ok "each apply needs its own plan and applies that saved plan, in its environment, one at a time"
# ci after dev (#30): the ci stack reads the dev project's number, for the reader's account's federation.
[ "$(q '.["plan:ci"].needs | join(",")')" = "tools,apply:dev" ] && [ "$(q '.["plan:dev"].needs | join(",")')" = "tools,apply:folder" ] &&
  [ "$(q '.["plan:gitlab"].needs | join(",")')" = "tools,apply:ci" ] && [[ $(q '.["plan:folder"].needs | join(",")') == tools,fmt,validate,tflint,shellcheck,policy,test,security ]] &&
  ok "the order: the checks, folder, dev, ci, then gitlab" || fail "the order: plan:folder $(q '.["plan:folder"].needs') plan:ci $(q '.["plan:ci"].needs') plan:dev $(q '.["plan:dev"].needs') plan:gitlab $(q '.["plan:gitlab"].needs')"
# The drift issue's reader key is tacplus-ci's (#30), and nothing here signs with jody1-328023's.
[ "$(q '.variables.TACPLUS_READER_KMS_KEY')" = projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-reader ] &&
  ! grep -rn 'jody1-328023/locations/[a-z0-9-]*/keyRings' "$here/ci" "$here/stacks" "$here/modules" &&
  ok "the reader's key is tacplus-ci's tacplus-reader, never jody1-328023's" || fail "the reader's key: $(q '.variables.TACPLUS_READER_KMS_KEY')"

for j in "${jobs[@]}"; do
  case $j in plan:*|apply:*|drift) want=yes ;; *) want=no ;; esac
  has=$([ "$(q ".[\"$j\"].id_tokens.GCP_ID_TOKEN.aud // \"\"")" = 'https://iam.googleapis.com/$GCP_WIF_PROVIDER' ] && echo yes || echo no)
  [ "$has" = "$want" ] || fail "$j: id_token $has"
done
ok "only the plan, apply and drift jobs have an id_token"
[[ $(q '.drift.script | join(" ")') == *'ci/drift.sh folder ci dev gitlab' ]] && [[ $(q '.drift.script | join(" ")') != *"tofu.sh apply"* ]] &&
  ok "drift plans every stack and never applies" || fail "drift: $(q '.drift.script')"
[[ $(q '.security.script | join(" ")') == *'--unshallow'*'ci/tools.sh security && ci/security.sh' ]] &&
  [ "$(q '.security.artifacts.paths | join(",")')" = src/security/ ] && [ "$(q '.security.artifacts.when')" = always ] &&
  ok "security scans the full history with the pinned scanners, its report an artifact even when it fails" ||
  fail "security: $(q '.security')"
[ "$(q '[.[] | select(tag == "!!map") | .rules[]? | select(.when == "manual")] | length')" = 0 ] &&
  ok "no job is manual: production is not built, nothing waits for Jody" || fail "a job is manual"

commit=0123456789abcdef0123456789abcdef01234567
"$here/ci/pin.sh" "$commit" > "$work/pinned.yml" || fail "pin.sh $commit failed"
diff <(sed "s/^  CLOUD_COMMIT: \"$commit\"\$/  CLOUD_COMMIT: \"\"/" "$work/pinned.yml") "$src" >/dev/null &&
  ok "pin.sh sets CLOUD_COMMIT and nothing else" || fail "pin.sh changed more than CLOUD_COMMIT"
"$here/ci/pin.sh" --check "$work/pinned.yml" >/dev/null 2>&1 && ok "pin.sh --check accepts its output" || fail "pin.sh --check refused its own output"
sed 's/^  tags: \[cloud\]$/  tags: [other]/' "$work/pinned.yml" > "$work/changed.yml"
"$here/ci/pin.sh" --check "$work/changed.yml" >/dev/null 2>&1 && fail "pin.sh --check accepted a changed file" || ok "pin.sh --check refuses any other change"
"$here/ci/pin.sh" --check "$src" >/dev/null 2>&1 && fail "pin.sh --check accepted an empty CLOUD_COMMIT" || ok "pin.sh --check refuses an empty CLOUD_COMMIT"
"$here/ci/pin.sh" main >/dev/null 2>&1 && fail "pin.sh accepted a branch name" || ok "pin.sh refuses what is not a full commit hash"
(CLOUD_COMMIT="" bash -c "$(q '.default.before_script[0]')" >/dev/null 2>&1) && fail "the jobs ran with an empty CLOUD_COMMIT" ||
  ok "the jobs refuse an empty CLOUD_COMMIT"

# ci/lib.sh's ci_gcp gives the stacks the parent folder from the protected variable GCP_PARENT_FOLDER (never written
# in this repository), and refuses a job without one, or with one that is not a folder's numeric ID, before any
# gcloud runs (a function stands in for gcloud: it is never reached when refused).
gcp() { # gcp [GCP_PARENT_FOLDER]: ci_gcp's TF_VAR_parent_folder, or its refusal
  (
    unset GCP_PARENT_FOLDER TF_VAR_parent_folder
    [ $# = 0 ] || export GCP_PARENT_FOLDER=$1
    export GCP_ID_TOKEN=x GCP_WIF_PROVIDER=y GCP_DEPLOY_SA=z ci_tmp=$work/lib
    mkdir -p "$ci_tmp"
    # shellcheck source=ci/lib.sh
    source "$here/ci/lib.sh"
    gcloud() { echo "gcloud ran" >&2; }
    ci_gcp >/dev/null 2>"$work/gcp-err" && echo "${TF_VAR_parent_folder:-}"
  )
}
[ "$(gcp 111111111111)" = 111111111111 ] && ok "ci_gcp gives the stacks GCP_PARENT_FOLDER as parent_folder" || fail "ci_gcp's parent_folder: [$(gcp 111111111111)] $(cat "$work/gcp-err")"
[ -z "$(gcp)" ] && grep -q GCP_PARENT_FOLDER "$work/gcp-err" && ! grep -q 'gcloud ran' "$work/gcp-err" &&
  ok "ci_gcp refuses a job without GCP_PARENT_FOLDER" || fail "ci_gcp without GCP_PARENT_FOLDER: $(cat "$work/gcp-err")"
[ -z "$(gcp folders/111111111111)" ] && grep -q GCP_PARENT_FOLDER "$work/gcp-err" && ! grep -q 'gcloud ran' "$work/gcp-err" &&
  ok "ci_gcp refuses a GCP_PARENT_FOLDER that is not a numeric ID" || fail "ci_gcp with folders/...: $(cat "$work/gcp-err")"

# ci_gcp gives the dev stack the runners' token adders (#18) from the protected variable GCP_RUNNER_TOKEN_ADDERS
# (members, comma-separated: their accounts are of the host's directory, which this repository never names), as an
# HCL list; none when it is unset or empty; and refuses one that is not a member before any gcloud runs.
adders() { # adders [GCP_RUNNER_TOKEN_ADDERS]: ci_gcp's TF_VAR_runner_token_adders, or its refusal
  (
    unset GCP_RUNNER_TOKEN_ADDERS TF_VAR_runner_token_adders
    [ $# = 0 ] || export GCP_RUNNER_TOKEN_ADDERS=$1
    export GCP_ID_TOKEN=x GCP_WIF_PROVIDER=y GCP_DEPLOY_SA=z GCP_PARENT_FOLDER=111111111111 ci_tmp=$work/lib
    mkdir -p "$ci_tmp"
    # shellcheck source=ci/lib.sh
    source "$here/ci/lib.sh"
    gcloud() { echo "gcloud ran" >&2; }
    ci_gcp >/dev/null 2>"$work/gcp-err" && echo "${TF_VAR_runner_token_adders-unset}"
  )
}
[ "$(adders user:a@example.com)" = '["user:a@example.com"]' ] && [ "$(adders 'user:a@example.com, group:b@example.com')" = '["user:a@example.com","group:b@example.com"]' ] &&
  ok "ci_gcp gives the dev stack GCP_RUNNER_TOKEN_ADDERS as runner_token_adders" || fail "ci_gcp's runner_token_adders: [$(adders 'user:a@example.com, group:b@example.com')] $(cat "$work/gcp-err")"
[ "$(adders)" = '[]' ] && [ "$(adders '')" = '[]' ] && ok "ci_gcp gives no adder without GCP_RUNNER_TOKEN_ADDERS" || fail "ci_gcp without GCP_RUNNER_TOKEN_ADDERS: [$(adders)]"
[ -z "$(adders a@example.com)" ] && grep -q GCP_RUNNER_TOKEN_ADDERS "$work/gcp-err" && ! grep -q 'gcloud ran' "$work/gcp-err" &&
  [ -z "$(adders 'user:a@example.com"]')" ] && ok "ci_gcp refuses a GCP_RUNNER_TOKEN_ADDERS entry that is not a member" || fail "ci_gcp with a bad adder: $(cat "$work/gcp-err")"

# ci_gcp gives the ci stack the apps' key importers (#19) from the protected variable GCP_KMS_KEY_IMPORTERS alone, as
# the adders: an HCL list, none when it is unset or empty, a refusal of one that is not a member before any gcloud.
importers() { # importers [GCP_KMS_KEY_IMPORTERS]: ci_gcp's TF_VAR_kms_key_importers, or its refusal
  (
    unset GCP_KMS_KEY_IMPORTERS TF_VAR_kms_key_importers GCP_RUNNER_TOKEN_ADDERS
    [ $# = 0 ] || export GCP_KMS_KEY_IMPORTERS=$1
    export GCP_ID_TOKEN=x GCP_WIF_PROVIDER=y GCP_DEPLOY_SA=z GCP_PARENT_FOLDER=111111111111 ci_tmp=$work/lib
    mkdir -p "$ci_tmp"
    # shellcheck source=ci/lib.sh
    source "$here/ci/lib.sh"
    gcloud() { echo "gcloud ran" >&2; }
    ci_gcp >/dev/null 2>"$work/gcp-err" && echo "${TF_VAR_kms_key_importers-unset} ${TF_VAR_runner_token_adders-unset}"
  )
}
[ "$(importers user:a@example.com)" = '["user:a@example.com"] []' ] && [ "$(importers 'user:a@example.com, group:b@example.com')" = '["user:a@example.com","group:b@example.com"] []' ] &&
  ok "ci_gcp gives the ci stack GCP_KMS_KEY_IMPORTERS as kms_key_importers, and nobody else" || fail "ci_gcp's kms_key_importers: [$(importers 'user:a@example.com, group:b@example.com')] $(cat "$work/gcp-err")"
[ "$(importers)" = '[] []' ] && [ "$(importers '')" = '[] []' ] && ok "ci_gcp gives no importer without GCP_KMS_KEY_IMPORTERS" || fail "ci_gcp without GCP_KMS_KEY_IMPORTERS: [$(importers)]"
[ -z "$(importers a@example.com)" ] && grep -q GCP_KMS_KEY_IMPORTERS "$work/gcp-err" && ! grep -q 'gcloud ran' "$work/gcp-err" &&
  ok "ci_gcp refuses a GCP_KMS_KEY_IMPORTERS entry that is not a member" || fail "ci_gcp with a bad importer: $(cat "$work/gcp-err")"
exit "$failed"
