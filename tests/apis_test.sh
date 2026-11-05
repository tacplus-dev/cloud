#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The audit of the APIs the stacks call (#16): every google resource and data source type in modules/ and stacks/ is
# named below with the API it calls, and each API with the project its calls count against: the caller's, the
# pipeline's own tacplus-bootstrap (the quota project of the federated cloud-admin-pipeline), whose APIs
# bootstrap/bootstrap.sh enables (SERVICES); or the resource's, the project the stack changes, whose APIs the
# module enables (google_project_service). A type not named here fails the test, so a new API is audited before
# its first apply, not by it. Needs bash.
#
#   tests/apis_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The API of each type, by the longest prefix that matches it.
declare -A api_of=(
  [google_active_folder]=cloudresourcemanager
  [google_folder]=cloudresourcemanager
  [google_project_iam]=cloudresourcemanager
  [google_project_service]=serviceusage
  [google_service_account]=iam
  [google_iam_workload_identity_pool]=iam
  [google_secret_manager]=secretmanager
  [google_storage]=storage
  [google_artifact_registry]=artifactregistry
  [google_compute]=compute
  [google_container]=container
  [google_dns]=dns
  [google_kms]=cloudkms
)
# google_project, the resource and the data source: the project (Resource Manager) and its billing (Cloud Billing).
project_apis="cloudresourcemanager cloudbilling"

# Where each API's calls count. caller: tacplus-bootstrap must enable it. resource: the project it changes must.
# Both, where Google documents neither and no apply has shown which, or where it is seen as the caller's but the
# project needs it too: enabling it in both costs nothing.
declare -A counts=(
  # Resource Manager, Cloud Billing and Service Usage count against the caller (the project they change may not
  # exist yet, or its APIs not be enabled yet).
  [cloudresourcemanager]=caller
  [cloudbilling]=caller
  [serviceusage]=caller
  # Cloud KMS: the caller's (#16: apply:ci's key ring was refused, KMS off in tacplus-bootstrap).
  [cloudkms]="caller resource"
  # Neither documented nor shown by an apply: both.
  [iam]="caller resource"
  [secretmanager]="caller resource"
  [storage]="caller resource"
  [artifactregistry]="caller resource"
  # The resource's: Cloud DNS (#16: apply:dev created its zones and records, DNS off in tacplus-bootstrap), Compute
  # Engine and GKE (quotas per project). Enabling Compute in tacplus-bootstrap would make its default service account,
  # an Editor, there: never.
  [dns]=resource
  [compute]=resource
  [container]=resource
)

api() { # api TYPE: the API(s) of a type, or nothing when the type is not audited
  local t=$1 p best=
  [ "$t" = google_project ] && { echo "$project_apis"; return; }
  for p in "${!api_of[@]}"; do
    [[ $t == "$p" || $t == "$p"_* ]] && [ ${#p} -gt ${#best} ] && best=$p
  done
  [ -n "$best" ] && echo "${api_of[$best]}"
}
types() { # types FILE...: the google types the files declare, one a line
  sed -nE 's/^(resource|data) "(google_[a-z0-9_]+)".*/\2/p' "$@" | sort -u
}
enabled() { # enabled MODULE: the APIs the module enables in its project
  sed -n '/^resource "google_project_service"/,/^}/s/^ *"\([a-z]*\)\.googleapis\.com",$/\1/p' "$1"/*.tf | sort -u
}

bootstrap_services=$(sed -n '/^SERVICES=(/,/)/p' "$here/bootstrap/bootstrap.sh" | grep -oE '[a-z]+\.googleapis\.com' | sed 's/\.googleapis\.com$//' | sort -u)
[ -n "$bootstrap_services" ] || fail "bootstrap/bootstrap.sh has no SERVICES"

caller_apis=()
mapfile -t files < <(find "$here/modules" "$here/stacks" -name '*.tf' | sort)
for t in $(types "${files[@]}"); do
  a=$(api "$t")
  if [ -z "$a" ]; then fail "$t: not audited (name its API in tests/apis_test.sh)"; continue; fi
  for x in $a; do
    [ -n "${counts[$x]:-}" ] || { fail "$t: the API $x is not classified (tests/apis_test.sh)"; continue; }
    [[ " ${counts[$x]} " == *" caller "* ]] && caller_apis+=("$x")
  done
done
for x in $(printf '%s\n' "${caller_apis[@]}" | sort -u); do
  grep -qx "$x" <<< "$bootstrap_services" && ok "$x.googleapis.com, the caller's, is enabled in tacplus-bootstrap" ||
    fail "$x.googleapis.com counts against the caller, but bootstrap/bootstrap.sh's SERVICES does not enable it in tacplus-bootstrap"
done

# Each project module enables, in its project, every API its resources call there that counts against the resource.
for m in "$here"/modules/projects/*/; do
  m=${m%/} name=modules/projects/$(basename "$m")
  on=$(enabled "$m")
  [ -n "$on" ] || { fail "$name enables no API"; continue; }
  for t in $(types "$m"/*.tf); do
    for x in $(api "$t"); do
      [[ " ${counts[$x]:-} " == *" resource "* ]] || continue
      grep -qx "$x" <<< "$on" || fail "$name: $t calls $x.googleapis.com in its project, which the module does not enable"
    done
  done
  ok "$name enables the APIs its resources call in its project"
done

# Compute is never enabled in tacplus-bootstrap (its default service account), nor GKE, which needs it.
for x in compute container; do
  grep -qx "$x" <<< "$bootstrap_services" && fail "bootstrap/bootstrap.sh enables $x.googleapis.com in tacplus-bootstrap"
done

[ "$failed" = 0 ] && echo "apis: all passed" || { echo "apis: FAILED"; exit 1; }
