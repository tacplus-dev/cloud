#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The IAM readiness gate of a new project (#16), run by each project module's terraform_data.iam_ready during
# apply:<stack>, after the project and its APIs and before everything else in it. IAM, the pipeline's folder-owner
# role included, reaches a project created seconds before only after a minute or two: until then its first
# IAM-dependent create is refused (apply:dev, iam.workloadIdentityPools.create). It asks Resource Manager's
# testIamPermissions, as the pipeline (gcloud's account, ci/lib.sh's ci_gcp), whether it holds each PERMISSION on
# the project, and is ready once all of them are granted on IAM_READY_STREAK checks in a row (default 3), one
# IAM_READY_INTERVAL seconds after another (default 10), so that one frontend's answer is not taken for all; a
# missing permission, or the project not visible yet (403, 404), starts the count again. It gives up after
# IAM_READY_ATTEMPTS checks (default 60: ten minutes), naming what is missing, and at once on any other answer (a
# malformed permission is no propagation). An existing project passes in IAM_READY_STREAK checks. Needs gcloud,
# curl and jq.
#
#   ci/iam-ready.sh PROJECT PERMISSION...
set -uo pipefail
say() { echo "iam-ready: $*"; }
die() { echo "iam-ready: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: ci/iam-ready.sh PROJECT PERMISSION..."
project=$1; shift
interval=${IAM_READY_INTERVAL:-10} attempts=${IAM_READY_ATTEMPTS:-60} streak=${IAM_READY_STREAK:-3}
t=$(mktemp -d) || die "no temporary directory"
trap 'rm -rf "$t"' EXIT
body=$(jq -cn '{permissions: $ARGS.positional}' --args "$@") || die "jq"
error() { jq -er '.error | [.status, .message] | join(": ")' "$1" 2>/dev/null || head -c 300 "$1" | tr '\n' ' '; }

held=0
for ((n = 1; n <= attempts; n++)); do
  [ "$n" = 1 ] || sleep "$interval"
  token=$(gcloud auth print-access-token 2>"$t/err") || die "no access token: $(head -c 300 "$t/err")"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$t/auth" ) || die "no temporary directory"
  code=$(curl -sS -o "$t/answer" -w '%{http_code}' -X POST -H @"$t/auth" -H 'Content-Type: application/json' \
    -d "$body" "${CRM_API:-https://cloudresourcemanager.googleapis.com}/v3/projects/$project:testIamPermissions")
  rm -f "$t/auth"
  case $code in
    200)
      missing=$(jq -r --argjson want "$body" '$want.permissions - (.permissions // []) | join(" ")' "$t/answer") ||
        die "check $n: an answer that is not JSON: $(head -c 300 "$t/answer")"
      if [ -z "$missing" ]; then
        held=$((held + 1))
        [ "$held" -ge "$streak" ] && { say "$project: the pipeline holds its $# permissions ($held checks in a row)"; exit 0; }
        continue
      fi
      why="missing $missing" ;;
    403|404) why="the project is not visible yet: HTTP $code $(error "$t/answer")"; missing="all of $*" ;;
    *) die "$project: testIamPermissions answered HTTP ${code:-none}: $(error "$t/answer")" ;;
  esac
  held=0
  say "$project: check $n of $attempts: $why"
done
die "$project: IAM did not reach it within $attempts checks: missing ${missing:-none, but not on $streak checks in a row}"
