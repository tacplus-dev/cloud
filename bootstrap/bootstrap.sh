#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The one manual step of tacplus-dev/cloud (tacplus-dev/roadmap decisions/cloud-pipeline-2026-11-02.md): what the
# pipeline needs before it can run, which Jody runs once with his own account. Everything after it is the pipeline.
#
#   1. tacplus.dev verified for Cloud Identity Free: the sign-up's TXT record in the Cloud DNS zone tacplus-dev
#      (project jody1-328023), then the organization, which Google creates once the domain is verified;
#   2. the folder bootstrap, the project tacplus-bootstrap in it (billing linked, the APIs the pipeline calls), and
#      the state bucket (us-central1, versioned, uniform access, no public access);
#   3. cloud-admin-pipeline, its rights (the organization, the billing account, the state bucket, the bootstrap
#      project's secrets), and its Workload Identity Federation from gitlab.com: the pool gitlab-com and the provider
#      tacplus-dev-cloud, which admits only the GitLab project tacplus-dev/cloud's protected main;
#   4. the empty secrets the pipeline reads (gitlab-token, tacplus-reader-app-id, tacplus-reader-installation-id):
#      their values are Jody's to add (README, Bootstrap), never in this repository.
#
# It first looks at everything (reading only), and refuses, before it changes anything, when something exists but
# is not what it would create (a bucket without versioning, a provider with another condition, the project in
# another folder): it never changes or deletes what exists. Then it creates only what is missing, printing each
# command and what it created. Run again once everything exists, it is a no-op ("nothing to do"); run after a
# partial run, it creates the rest. With --dry-run it does the looking and prints the commands it would run,
# changing nothing.
#
#   bootstrap/bootstrap.sh --billing-account XXXXXX-XXXXXX-XXXXXX [--verification-token TOKEN] [--dry-run]
#
# TOKEN is the TXT value the Cloud Identity Free sign-up shows (google-site-verification=...), needed only until the
# organization exists. Needs gcloud, signed in as the account that runs it (gcloud config get account), and jq.
# Exit status: 0 done (or, with --dry-run, would be done); 1 refused or failed; 3 waiting for the organization
# (the TXT record is in place: finish the sign-up's verification, then run it again).
set -euo pipefail

# The names: modules/settings holds the same (tests/settings_test.sh checks they agree).
DOMAIN=tacplus.dev
REGION=us-central1
DNS_PROJECT=jody1-328023
DNS_ZONE=tacplus-dev
FOLDER=bootstrap
PROJECT=tacplus-bootstrap
BUCKET=tacplus-bootstrap-tofu-state
SA_ID=cloud-admin-pipeline
SA=$SA_ID@$PROJECT.iam.gserviceaccount.com
POOL=gitlab-com
PROVIDER=tacplus-dev-cloud
GITLAB_PROJECT=tacplus-dev/cloud
ISSUER=https://gitlab.com
CONDITION="assertion.project_path == '$GITLAB_PROJECT' && assertion.ref_type == 'branch' && assertion.ref == 'main' && assertion.ref_protected == 'true'"
MAPPING=google.subject=assertion.sub,attribute.project_path=assertion.project_path,attribute.ref=assertion.ref,attribute.ref_type=assertion.ref_type,attribute.ref_protected=assertion.ref_protected
SERVICES=(cloudbilling.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com
  orgpolicy.googleapis.com secretmanager.googleapis.com serviceusage.googleapis.com storage.googleapis.com sts.googleapis.com)
SECRETS=(gitlab-token tacplus-reader-app-id tacplus-reader-installation-id)
# cloud-admin-pipeline on the organization: folders and their IAM, projects, org policies, the organization's IAM
# (its readers), and reading what it looks up.
SA_ORG_ROLES=(roles/resourcemanager.folderAdmin roles/resourcemanager.projectCreator roles/orgpolicy.policyAdmin
  roles/iam.securityAdmin roles/resourcemanager.organizationViewer roles/browser)
# The account that runs this, on the organization: to create the folder and the project.
SELF_ORG_ROLES=(roles/resourcemanager.folderCreator roles/resourcemanager.projectCreator)

say() { echo "bootstrap: $*"; }
die() { echo "bootstrap: $*" >&2; exit 1; }
usage() { die "usage: bootstrap/bootstrap.sh --billing-account XXXXXX-XXXXXX-XXXXXX [--verification-token TOKEN] [--dry-run]"; }

billing='' token='' dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --billing-account) billing=${2:-}; shift 2 || usage ;;
    --verification-token) token=${2:-}; shift 2 || usage ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[[ $billing =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] || usage
[ -z "$token" ] || [[ $token =~ ^google-site-verification=[A-Za-z0-9_-]+$ ]] ||
  die "--verification-token is the sign-up's TXT value, google-site-verification=..."
command -v gcloud >/dev/null || die "needs gcloud"
command -v jq >/dev/null || die "needs jq"

# look CMD...: a reading gcloud command's output, or nothing when it fails (absent, or not visible).
look() { gcloud "$@" 2>/dev/null || true; }
# has_binding POLICY-JSON ROLE MEMBER
has_binding() { [ -n "$1" ] && jq -e --arg r "$2" --arg m "$3" '[.bindings[]? | select(.role == $r) | .members[]] | index($m)' <<< "$1" >/dev/null 2>&1; }

created=() todo=()
# run WHAT CMD...: creates WHAT with gcloud CMD..., printing the command (or, with --dry-run, only printing it).
run() {
  local what=$1; shift
  todo+=("$what")
  if [ "$dry" = 1 ]; then echo "would run: gcloud $(printf '%q ' "$@")"; return; fi
  echo "+ gcloud $(printf '%q ' "$@")"
  gcloud "$@" || die "failed to create $what: nothing after it was run (run this again once it is fixed)"
  created+=("$what")
  say "created: $what"
}

account=$(look config get account)
[ -n "$account" ] || die "gcloud has no account: gcloud auth login"
case $account in *.gserviceaccount.com) member=serviceAccount:$account ;; *) member=user:$account ;; esac
say "as $account$([ "$dry" = 1 ] && echo ', dry run: nothing is changed')"
[ "$(look billing accounts describe "$billing" --format='value(open)')" = True ] ||
  die "the billing account $billing is not open, or $account cannot see it (it must be its billing administrator)"

## 1. The domain and the organization.
org=$(look organizations list --filter="displayName=$DOMAIN" --format='value(name)')
if [ -n "$org" ]; then
  [[ $org =~ ^organizations/[0-9]+$ ]] || die "more than one organization, or an unexpected one, for $DOMAIN: $org"
  say "1. the organization $org of $DOMAIN exists"
else
  txt=$(look dns record-sets describe "$DOMAIN." --type=TXT --zone="$DNS_ZONE" --project="$DNS_PROJECT" --format=json)
  values=
  [ -z "$txt" ] || values=$(jq -r '.rrdatas[]?' <<< "$txt")
  [ -n "$token" ] || die "no organization for $DOMAIN yet: sign up for Cloud Identity Free with $DOMAIN (README, Bootstrap), and run this with --verification-token <its TXT value>"
  if grep -qxF "\"$token\"" <<< "$values"; then
    say "1. the TXT record $token is in the zone $DNS_ZONE"
  elif [ -z "$txt" ]; then
    run "the TXT record $token on $DOMAIN" dns record-sets create "$DOMAIN." --type=TXT --ttl=300 \
      --zone="$DNS_ZONE" --project="$DNS_PROJECT" --rrdatas="\"$token\""
  else
    # Another TXT record set exists (SPF, say): the token is added to it, nothing removed.
    grep -q , <<< "$values" && die "the TXT record set of $DOMAIN has a value with a comma; add $token to it by hand"
    run "the TXT record $token on $DOMAIN (beside its other TXT values)" dns record-sets update "$DOMAIN." --type=TXT \
      --ttl="$(jq -r '.ttl // 300' <<< "$txt")" --zone="$DNS_ZONE" --project="$DNS_PROJECT" \
      --rrdatas="$( (printf '%s\n' "$values"; echo "\"$token\"") | paste -sd, -)"
  fi
  if [ "$dry" = 0 ]; then
    say "waiting for the organization: finish the sign-up's verification of $DOMAIN (the TXT record is in place), then run this again"
    exit 3
  fi
  say "dry run: the organization does not exist yet; what follows is what a run after it would do"
  org="organizations/<the organization of $DOMAIN>"
fi
org_id=${org#organizations/}

## The survey: everything else as it is, read only, and refused now if anything differs from what would be made.
refused=()
refuse() { refused+=("$*"); }

org_policy='' folder='' project='' linked='' enabled='' bucket='' bucket_policy='' sa='' sa_policy='' project_policy='' pool='' provider='' number=''
if [[ $org_id != "<"* ]]; then
  org_policy=$(look organizations get-iam-policy "$org_id" --format=json)
  folder=$(look resource-manager folders list --organization="$org_id" --filter="displayName=$FOLDER" --format='value(name)')
  [ "$(grep -c . <<< "$folder")" -le 1 ] || refuse "more than one folder $FOLDER in $org: $folder"
fi
project=$(look projects describe "$PROJECT" --format=json)
if [ -n "$project" ]; then
  state=$(jq -r '.lifecycleState' <<< "$project")
  parent=$(jq -r '"\(.parent.type)s/\(.parent.id)"' <<< "$project")
  [ "$state" = ACTIVE ] || refuse "the project $PROJECT is $state"
  [ -n "$folder" ] && [ "$parent" = "$folder" ] || refuse "the project $PROJECT is in $parent, not in the folder $FOLDER (${folder:-none yet})"
  linked=$(look billing projects describe "$PROJECT" --format='value(billingAccountName)')
  [ -z "$linked" ] || [ "$linked" = "billingAccounts/$billing" ] || refuse "the project $PROJECT is billed to $linked, not $billing"
  enabled=$(look services list --enabled --project="$PROJECT" --format='value(config.name)')
fi
# Bucket names are global: one that exists already is refused unless it is the project's, as this would make it.
bucket=$(look storage buckets describe "gs://$BUCKET" --format=json)
if [ -n "$bucket" ]; then
  if [ -z "$project" ]; then
    refuse "the bucket gs://$BUCKET exists, but the project $PROJECT does not"
  else
    jq -e --arg loc "${REGION^^}" '.location == $loc and .versioning_enabled == true and .uniform_bucket_level_access == true and .public_access_prevention == "enforced"' <<< "$bucket" >/dev/null ||
      refuse "the bucket gs://$BUCKET is not in $REGION, versioned, with uniform access and public access prevented: $(jq -c '{location, versioning_enabled, uniform_bucket_level_access, public_access_prevention}' <<< "$bucket")"
    [ "$(jq -r '.project_number // empty' <<< "$bucket")" = "" ] ||
      [ "$(jq -r '.project_number' <<< "$bucket")" = "$(jq -r '.projectNumber' <<< "$project")" ] || refuse "the bucket gs://$BUCKET is not the project $PROJECT's"
    bucket_policy=$(look storage buckets get-iam-policy "gs://$BUCKET" --format=json)
  fi
fi
if [ -n "$project" ]; then
  sa=$(look iam service-accounts describe "$SA" --project="$PROJECT" --format='value(email)')
  [ -z "$sa" ] || sa_policy=$(look iam service-accounts get-iam-policy "$SA" --project="$PROJECT" --format=json)
  project_policy=$(look projects get-iam-policy "$PROJECT" --format=json)
  pool=$(look iam workload-identity-pools describe "$POOL" --location=global --project="$PROJECT" --format=json)
  [ -z "$pool" ] || [ "$(jq -r '.state' <<< "$pool")" = ACTIVE ] || refuse "the pool $POOL is $(jq -r '.state' <<< "$pool")"
  provider=$(look iam workload-identity-pools providers describe "$PROVIDER" --workload-identity-pool="$POOL" --location=global --project="$PROJECT" --format=json)
  if [ -n "$provider" ]; then
    want_mapping=$(tr , '\n' <<< "$MAPPING" | jq -R 'split("=") | {(.[0]): .[1]}' | jq -s 'add')
    jq -e --arg c "$CONDITION" --arg i "$ISSUER" --argjson m "$want_mapping" \
        '.state == "ACTIVE" and .attributeCondition == $c and .oidc.issuerUri == $i and .attributeMapping == $m and ((.oidc.allowedAudiences // []) | length == 0)' <<< "$provider" >/dev/null ||
      refuse "the provider $PROVIDER is not the one this makes (issuer $ISSUER, the default audience, condition [$CONDITION]): $(jq -c '{state, attributeCondition, issuer: .oidc.issuerUri, audiences: .oidc.allowedAudiences}' <<< "$provider")"
  fi
  number=$(jq -r '.projectNumber' <<< "$project")
fi
billing_policy=$(look billing accounts get-iam-policy "$billing" --format=json)

if [ ${#refused[@]} -gt 0 ]; then
  for r in "${refused[@]}"; do echo "bootstrap: refused: $r" >&2; done
  die "nothing was changed: what exists is not what this would create, and it never changes or deletes what exists (README, Bootstrap)"
fi

## 2. The folder, the project and the state bucket.
for role in "${SELF_ORG_ROLES[@]}"; do
  has_binding "$org_policy" "$role" "$member" ||
    run "$role on $org for $account" organizations add-iam-policy-binding "$org_id" --member="$member" --role="$role" --condition=None --format=none
done
if [ -z "$folder" ]; then
  run "the folder $FOLDER" resource-manager folders create --display-name="$FOLDER" --organization="$org_id" --format=none
  if [ "$dry" = 0 ]; then
    folder=$(look resource-manager folders list --organization="$org_id" --filter="displayName=$FOLDER" --format='value(name)')
    [[ $folder =~ ^folders/[0-9]+$ ]] || die "the folder $FOLDER was created, but is not listed: run this again"
  else
    folder="folders/<the folder $FOLDER>"
  fi
else
  say "2. the folder $FOLDER exists: $folder"
fi
if [ -z "$project" ]; then
  run "the project $PROJECT" projects create "$PROJECT" --folder="${folder#folders/}" --name="tacplus bootstrap" --labels=managed-by=tacplus-dev-cloud-bootstrap
  if [ "$dry" = 0 ]; then
    number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  else
    number="<the project number of $PROJECT>"
  fi
else
  say "2. the project $PROJECT exists, in $folder"
fi
if [ -n "$linked" ]; then say "2. $PROJECT is billed to $billing"
else run "the billing of $PROJECT to $billing" billing projects link "$PROJECT" --billing-account="$billing"; fi
missing=()
for s in "${SERVICES[@]}"; do grep -qxF "$s" <<< "$enabled" || missing+=("$s"); done
if [ ${#missing[@]} = 0 ]; then say "2. the APIs are enabled in $PROJECT"
else run "the APIs ${missing[*]} in $PROJECT" services enable "${missing[@]}" --project="$PROJECT"; fi
if [ -z "$bucket" ]; then
  run "the state bucket gs://$BUCKET" storage buckets create "gs://$BUCKET" --project="$PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention --default-storage-class=STANDARD
  run "versioning on gs://$BUCKET" storage buckets update "gs://$BUCKET" --versioning
  bucket_policy=
else
  say "2. the state bucket gs://$BUCKET exists: $REGION, versioned, uniform access"
fi

## 3. cloud-admin-pipeline, its rights and its federation.
if [ -z "$sa" ]; then
  run "the service account $SA" iam service-accounts create "$SA_ID" --project="$PROJECT" \
    --display-name="tacplus-dev/cloud pipeline, protected main (bootstrap/bootstrap.sh)"
  sa_policy=
else
  say "3. the service account $SA exists"
fi
for role in "${SA_ORG_ROLES[@]}"; do
  has_binding "$org_policy" "$role" "serviceAccount:$SA" ||
    run "$role on $org for $SA_ID" organizations add-iam-policy-binding "$org_id" --member="serviceAccount:$SA" --role="$role" --condition=None --format=none
done
has_binding "$billing_policy" roles/billing.user "serviceAccount:$SA" ||
  run "roles/billing.user on $billing for $SA_ID" billing accounts add-iam-policy-binding "$billing" --member="serviceAccount:$SA" --role=roles/billing.user --format=none
has_binding "$bucket_policy" roles/storage.objectAdmin "serviceAccount:$SA" ||
  run "roles/storage.objectAdmin on gs://$BUCKET for $SA_ID" storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA" --role=roles/storage.objectAdmin --format=none
has_binding "$project_policy" roles/secretmanager.secretAccessor "serviceAccount:$SA" ||
  run "roles/secretmanager.secretAccessor on $PROJECT for $SA_ID" projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role=roles/secretmanager.secretAccessor --condition=None --format=none
if [ -n "$pool" ]; then say "3. the pool $POOL exists"
else run "the workload identity pool $POOL" iam workload-identity-pools create "$POOL" --location=global --project="$PROJECT" \
    --display-name=gitlab.com --description="GitLab CI jobs of tacplus-dev (bootstrap/bootstrap.sh)"; fi
if [ -n "$provider" ]; then say "3. the provider $PROVIDER exists, admitting $GITLAB_PROJECT's protected main only"
else run "the provider $PROVIDER ($GITLAB_PROJECT, protected main)" iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --workload-identity-pool="$POOL" --location=global --project="$PROJECT" --display-name="$GITLAB_PROJECT" \
    --issuer-uri="$ISSUER" --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION"; fi
principal="principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$POOL/attribute.project_path/$GITLAB_PROJECT"
has_binding "$sa_policy" roles/iam.workloadIdentityUser "$principal" ||
  run "roles/iam.workloadIdentityUser on $SA_ID for $GITLAB_PROJECT's jobs" iam service-accounts add-iam-policy-binding "$SA" \
    --project="$PROJECT" --member="$principal" --role=roles/iam.workloadIdentityUser --format=none

## 4. The secrets the pipeline reads, empty.
for s in "${SECRETS[@]}"; do
  [ -n "$project" ] && [ -n "$(look secrets describe "$s" --project="$PROJECT" --format='value(name)')" ] && { say "4. the secret $s exists"; continue; }
  run "the secret $s (empty)" secrets create "$s" --project="$PROJECT" --replication-policy=user-managed --locations="$REGION"
done

echo
if [ ${#todo[@]} = 0 ]; then
  say "nothing to do: everything exists as this would create it"
elif [ "$dry" = 1 ]; then
  say "dry run: ${#todo[@]} step(s) would run (above); nothing was changed"
else
  say "created ${#created[@]}:"
  printf '  - %s\n' "${created[@]}"
fi
cat <<EOF
bootstrap: the GitLab project $GITLAB_PROJECT's variable GCP_WIF_PROVIDER (protected):
  projects/$number/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER
bootstrap: next (README, Bootstrap): add each secret's version 1, without echoing it:
  gcloud secrets versions add gitlab-token --project=$PROJECT --data-file=-
  gcloud secrets versions add tacplus-reader-app-id --project=$PROJECT --data-file=-
  gcloud secrets versions add tacplus-reader-installation-id --project=$PROJECT --data-file=-
EOF
