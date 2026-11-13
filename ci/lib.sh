# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by the pipeline's jobs (ci/gitlab-project.gitlab-ci.yml), each run from this repository's checkout at
# the pinned commit: the job's credentials, each from the job's own GitLab id_token through Workload Identity
# Federation. No key file is stored anywhere, and no GitLab or GitHub token in GitLab. Every credential lives in
# the job's temporary directory and goes with the job (the runner's VMs are used once). Nothing here prints one;
# never run these jobs with `set -x`. (tacplus-dev/cluster ci/lib.sh is the pattern; github_app_token is its.)
ci_tmp=${ci_tmp:-$(mktemp -d)}
ci_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ci_gcp: gcloud and OpenTofu's google provider as the pipeline's service account (GCP_DEPLOY_SA,
# cloud-admin-pipeline), through GitLab OIDC and Workload Identity Federation: the job's ID token (id_tokens
# GCP_ID_TOKEN) is exchanged for a short-lived Google token. The provider admits only this project's protected
# main (bootstrap/bootstrap.sh made it so). It also gives the stacks the parent folder they build under, their
# variable parent_folder, from the protected GitLab project variable GCP_PARENT_FOLDER: the folder's numeric ID,
# which this repository never writes (README, What the host organization provides); and the dev stack its
# runner_token_adders (#18), from the protected variable GCP_RUNNER_TOKEN_ADDERS: who adds the runners' token versions,
# members comma-separated (user:, group:, serviceAccount: and an email), accounts of the host's directory, which this
# repository never names either; unset or empty, nobody (README, The cluster pipeline); and the ci stack its
# kms_key_importers (#19), from the protected variable GCP_KMS_KEY_IMPORTERS, alike: who imports the GitHub Apps' keys,
# for the one run that imports them (README, The GitHub Apps' keys); and the dev stack its google_signin_adders (#37),
# from the protected variable GCP_GOOGLE_SIGNIN_ADDERS, alike: who adds the Google sign-in clients' secrets, in the
# Console (README, The Google sign-in client).
ci_gcp() {
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (README, Before the first pipeline)}"
  : "${GCP_DEPLOY_SA:?GCP_DEPLOY_SA is not set}"
  [[ ${GCP_PARENT_FOLDER:-} =~ ^[0-9]+$ ]] ||
    { echo "gcp: the GitLab project variable GCP_PARENT_FOLDER is not the parent folder's numeric ID: [${GCP_PARENT_FOLDER:-}] (README, Before the first pipeline)" >&2
      return 1; }
  export TF_VAR_parent_folder=$GCP_PARENT_FOLDER
  TF_VAR_runner_token_adders=$(ci_members GCP_RUNNER_TOKEN_ADDERS "The cluster pipeline") || return 1
  TF_VAR_kms_key_importers=$(ci_members GCP_KMS_KEY_IMPORTERS "The GitHub Apps' keys") || return 1
  TF_VAR_google_signin_adders=$(ci_members GCP_GOOGLE_SIGNIN_ADDERS "The Google sign-in client") || return 1
  export TF_VAR_runner_token_adders TF_VAR_kms_key_importers TF_VAR_google_signin_adders
  export CLOUDSDK_CONFIG=$ci_tmp/gcloud CLOUDSDK_CORE_DISABLE_PROMPTS=1
  ( umask 077
    printf '%s' "$GCP_ID_TOKEN" > "$ci_tmp/oidc-token"
    gcloud iam workload-identity-pools create-cred-config "$GCP_WIF_PROVIDER" \
      --service-account="$GCP_DEPLOY_SA" --credential-source-file="$ci_tmp/oidc-token" \
      --output-file="$ci_tmp/gcp-federation.json" >/dev/null ) || return 1
  gcloud auth login --cred-file="$ci_tmp/gcp-federation.json" --quiet >/dev/null 2>"$ci_tmp/gcloud-err" ||
    { echo "gcp: Workload Identity Federation refused this job ($GCP_WIF_PROVIDER): $(grep -m1 '^ERROR' "$ci_tmp/gcloud-err" || head -c 300 "$ci_tmp/gcloud-err")" >&2
      return 1; }
  export GOOGLE_APPLICATION_CREDENTIALS=$ci_tmp/gcp-federation.json
  echo "gcp: $(gcloud config get account 2>/dev/null) through workload identity federation"
}

# ci_members VARIABLE SECTION: the members a protected GitLab variable lists, comma-separated (user:, group:,
# serviceAccount: and an email), as an HCL list, [] when it is unset or empty; refused, naming the README's SECTION,
# unless each is a member.
ci_members() {
  local m entries members=()
  IFS=, read -ra entries <<< "${!1:-}"
  for m in "${entries[@]}"; do
    m=${m//[[:space:]]/}
    [ -n "$m" ] || continue
    [[ $m =~ ^(user|group|serviceAccount):[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] ||
      { echo "gcp: the GitLab project variable $1 holds [$m], not a member (user:, group: or serviceAccount: and an email) (README, $2)" >&2
        return 1; }
    members+=("\"$m\"")
  done
  echo "[$(IFS=,; echo "${members[*]}")]"
}

# ci_gitlab: GITLAB_TOKEN for the gitlab stack's provider, read as the pipeline's account from Secret Manager, the
# version modules/settings names (gitlab_token_secret): a new token is a new version and a commit. Call it after
# ci_gcp.
ci_gitlab() {
  local secret
  secret=$(ci_gitlab_secret) || return 1
  GITLAB_TOKEN=$(gcloud secrets versions access "$secret" 2>"$ci_tmp/gcloud-err") && [ -n "$GITLAB_TOKEN" ] ||
    { echo "gitlab: no GitLab token from $secret: $(grep -m1 '^ERROR' "$ci_tmp/gcloud-err" || head -c 300 "$ci_tmp/gcloud-err") (README, Before the first pipeline)" >&2
      return 1; }
  export GITLAB_TOKEN
  echo "gitlab: the token of $secret"
}

# ci_anthropic: the anthropic stack's credential (#34): no key. Its provider exchanges the job's GitLab ID tokens for
# Anthropic (id_tokens ANTHROPIC_ID_TOKEN_<n>, aud https://api.anthropic.com), one per exchange
# (ci/anthropic-token.sh), through the bootstrap org:admin rule made by hand in the Console (README, The Anthropic
# organization), for a short-lived org:admin token. The rule, its account and the organization are
# ANTHROPIC_FEDERATION_RULE_ID, ANTHROPIC_SERVICE_ACCOUNT_ID and ANTHROPIC_ORGANIZATION_ID (the CI file's variables,
# IDs, none secret), which the provider reads as they are, and the stack as its variable admin, to check the rule.
ci_anthropic() {
  : "${ANTHROPIC_ID_TOKEN_1:?the job has no id_tokens ANTHROPIC_ID_TOKEN_1}"
  [[ ${ANTHROPIC_ORGANIZATION_ID:-} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] &&
    [[ ${ANTHROPIC_FEDERATION_RULE_ID:-} =~ ^fdrl_[A-Za-z0-9]+$ ]] && [[ ${ANTHROPIC_SERVICE_ACCOUNT_ID:-} =~ ^svac_[A-Za-z0-9]+$ ]] ||
    { echo "anthropic: ANTHROPIC_ORGANIZATION_ID, ANTHROPIC_FEDERATION_RULE_ID and ANTHROPIC_SERVICE_ACCOUNT_ID are not an organization's UUID, an fdrl_ and an svac_: [${ANTHROPIC_ORGANIZATION_ID:-}] [${ANTHROPIC_FEDERATION_RULE_ID:-}] [${ANTHROPIC_SERVICE_ACCOUNT_ID:-}] (README, The Anthropic organization)" >&2
      return 1; }
  export ANTHROPIC_ORGANIZATION_ID ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_SERVICE_ACCOUNT_ID
  export ANTHROPIC_ID_TOKENS_DIR=$ci_tmp/anthropic-tokens
  mkdir -p "$ANTHROPIC_ID_TOKENS_DIR"
  export TF_VAR_admin="{organization_id = \"$ANTHROPIC_ORGANIZATION_ID\", federation_rule_id = \"$ANTHROPIC_FEDERATION_RULE_ID\", service_account_id = \"$ANTHROPIC_SERVICE_ACCOUNT_ID\"}"
  echo "anthropic: the org:admin rule $ANTHROPIC_FEDERATION_RULE_ID of $ANTHROPIC_ORGANIZATION_ID, through workload identity federation"
}

# ci_projects: the projects the pipeline builds, one ID a line, as modules/settings names them (projects).
ci_projects() {
  local p
  p=$(sed -n 's|^ *[a-z][a-z0-9]* *= *{ *folder *= *"[^"]*", *project *= *"\([a-z][a-z0-9-]*\)",.*|\1|p' "$ci_here/../modules/settings/main.tf")
  [ -n "$p" ] || { echo "projects: modules/settings/main.tf names no project" >&2; return 1; }
  echo "$p"
}

# ci_zone: the dev project and the zone of the domain it holds (ci/dns.sh's PROJECT ZONE), as modules/settings names
# them (projects, zone).
ci_zone() {
  local p z
  p=$(sed -n 's|^ *dev *= *{ *folder *= *"[^"]*", *project *= *"\([a-z][a-z0-9-]*\)",.*|\1|p' "$ci_here/../modules/settings/main.tf")
  z=$(sed -n 's|^ *zone *= *"\([a-z][a-z0-9-]*\)"$|\1|p' "$ci_here/../modules/settings/main.tf")
  [ -n "$p" ] && [ -n "$z" ] && [ "$(printf '%s\n' "$z" | wc -l)" = 1 ] ||
    { echo "dns: modules/settings/main.tf names no dev project or no single zone" >&2; return 1; }
  echo "$p $z"
}

# ci_pools: the ci project and the region its runner pools are in (ci/pools.sh's PROJECT REGION), as modules/settings
# names them (projects, region).
ci_pools() {
  local p r
  p=$(sed -n 's|^ *ci *= *{ *folder *= *"[^"]*", *project *= *"\([a-z][a-z0-9-]*\)",.*|\1|p' "$ci_here/../modules/settings/main.tf")
  r=$(sed -n '/^output "region"/,/^}/s|^ *value *= *"\([a-z][a-z0-9-]*\)"$|\1|p' "$ci_here/../modules/settings/main.tf")
  [ -n "$p" ] && [ -n "$r" ] || { echo "pools: modules/settings/main.tf names no ci project or no region" >&2; return 1; }
  echo "$p $r"
}

# ci_gitlab_secret: the GitLab token's secret version, as modules/settings names it.
ci_gitlab_secret() {
  local s
  s=$(sed -n 's|^ *gitlab_token_secret *= *"\(projects/[^/"]*/secrets/[^/"]*/versions/[0-9][0-9]*\)"$|\1|p' "$ci_here/../modules/settings/main.tf")
  [ -n "$s" ] && [ "$(printf '%s\n' "$s" | wc -l)" = 1 ] ||
    { echo "gitlab: modules/settings/main.tf names no single gitlab_token_secret by version" >&2; return 1; }
  echo "$s"
}

# github_app_token REPO PERMISSIONS: a one-hour installation token of the keyless tacplus-reader GitHub App for
# tacplus-dev/REPO alone, with PERMISSIONS (JSON, as {"issues":"write"}), on stdout (tacplus-dev/looper README,
# Credentials; fleet-seatrials' .github-reader). The job's id_token is exchanged through Workload Identity
# Federation, as the job itself; Cloud KMS signs the app's JWT with the app's key (TACPLUS_READER_KMS_KEY), which
# never leaves KMS. If KMS refuses the federated principal, the job signs as TACPLUS_READER_SA, which it may
# impersonate, when that is set. A refusal says KMS's or GitHub's HTTP status and error, never a token.
github_app_token() (
  set -uo pipefail
  repo=$1 permissions=$2
  say() { echo "github_app_token: $*" >&2; }
  die() { say "$@"; exit 1; }
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (README, Before the first pipeline)}"
  : "${TACPLUS_READER_KMS_KEY:?TACPLUS_READER_KMS_KEY is not set}"
  : "${TACPLUS_READER_APP_ID:?the GitLab project variable TACPLUS_READER_APP_ID is not set (README, Before the first pipeline)}"
  : "${TACPLUS_READER_INSTALLATION_ID:?the GitLab project variable TACPLUS_READER_INSTALLATION_ID is not set (README, Before the first pipeline)}"
  t=$(mktemp -d) && trap 'rm -rf "$t"' EXIT || die "no temporary directory"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  # error FILE: the error in an answer, its status and message, never a request.
  error() { jq -er '(.error // .) | select(.message) | [(.status | strings | select(test("^[A-Z_]+$"))), .message] | join(": ")' "$1" 2>/dev/null ||
    head -c 300 "$1" | tr '\n' ' '; }
  ( umask 077; printf '%s' "$GCP_ID_TOKEN" > "$t/oidc-token" ) || die "no temporary directory"
  now=$(date +%s)
  jwt=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$TACPLUS_READER_APP_ID" | b64url)
  # kms_sign AS WHO [create-cred-config FLAG...]: KMS's signature of the JWT's digest in $t/jwt-sig, as WHO;
  # 3 when KMS refused the caller (401, 403).
  kms_sign() {
    local as=$1 who=$2 token code=; shift 2
    export CLOUDSDK_CONFIG=$t/gcloud-$as
    gcloud iam workload-identity-pools create-cred-config "$GCP_WIF_PROVIDER" "$@" \
        --credential-source-file="$t/oidc-token" --output-file="$t/federation-$as.json" >/dev/null &&
      gcloud auth login --cred-file="$t/federation-$as.json" --quiet >/dev/null 2>"$t/gcloud-err" &&
      token=$(gcloud auth print-access-token 2>"$t/gcloud-err") ||
      { say "Workload Identity Federation refused this job ($GCP_WIF_PROVIDER) as $who: $(grep -m1 '^ERROR' "$t/gcloud-err" || head -c 300 "$t/gcloud-err")"; return 1; }
    ( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$t/kms-auth" ) || return 1
    code=$(curl -sS -o "$t/kms" -w '%{http_code}' -X POST -H @"$t/kms-auth" -H 'Content-Type: application/json' \
      -d "{\"digest\":{\"sha256\":\"$(printf '%s' "$jwt" | openssl dgst -sha256 -binary | openssl base64 -A)\"}}" \
      "${KMS_API:-https://cloudkms.googleapis.com}/v1/$TACPLUS_READER_KMS_KEY/cryptoKeyVersions/1:asymmetricSign")
    rm -f "$t/kms-auth"
    [ "$code" = 200 ] && jq -er '.signature' "$t/kms" | openssl base64 -d -A > "$t/jwt-sig" && [ -s "$t/jwt-sig" ] && return 0
    say "Cloud KMS refused to sign with $TACPLUS_READER_KMS_KEY as $who: HTTP ${code:-none} $(error "$t/kms")"
    case $code in 401|403) return 3 ;; *) return 1 ;; esac
  }
  rc=0
  kms_sign direct "the job itself" || rc=$?
  if [ "$rc" = 3 ] && [ -n "${TACPLUS_READER_SA:-}" ]; then
    say "signing as the service account $TACPLUS_READER_SA instead"
    rc=0
    kms_sign sa "$TACPLUS_READER_SA" --service-account="$TACPLUS_READER_SA" || rc=$?
  fi
  [ "$rc" = 0 ] || die "no signature from Cloud KMS, so no token (README, Before the first pipeline)"
  ( umask 077; printf 'Authorization: Bearer %s.%s\n' "$jwt" "$(b64url < "$t/jwt-sig")" > "$t/github-auth" ) || die "no temporary directory"
  code=$(curl -sS -o "$t/answer" -w '%{http_code}' -X POST -H @"$t/github-auth" -H 'Accept: application/vnd.github+json' \
      -d "{\"permissions\":$permissions,\"repositories\":[\"$repo\"]}" \
      "${GITHUB_API:-https://api.github.com}/app/installations/$TACPLUS_READER_INSTALLATION_ID/access_tokens")
  [[ $code == 2?? ]] && jq -er '.token // empty' "$t/answer" ||
    die "GitHub refused the tacplus-reader app a token for $repo with $permissions: HTTP ${code:-none} $(error "$t/answer")"
)
