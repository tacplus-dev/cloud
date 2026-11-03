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
# main (bootstrap/bootstrap.sh made it so).
ci_gcp() {
  : "${GCP_ID_TOKEN:?the job has no id_tokens GCP_ID_TOKEN}"
  : "${GCP_WIF_PROVIDER:?the GitLab project variable GCP_WIF_PROVIDER is not set (README, Before the first pipeline)}"
  : "${GCP_DEPLOY_SA:?GCP_DEPLOY_SA is not set}"
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
