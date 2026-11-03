# cloud

The pipeline that owns tacplus-dev's cloud accounts. Every change to GCP and GitLab configuration is a commit here, applied
by a pipeline. People, the hub included, have read-only access.

Design: tacplus-dev/roadmap#2 and `tacplus-dev/roadmap:decisions/cloud-pipeline-2026-11-02.md` (approved by Jody, 2026-11-02);
the rule that every deployment is deterministic, `decisions/deterministic-deployments-2026-11-02.md`, whose addendum
"approval only for production" makes `ci` and `dev` apply without waiting for Jody. The list of what must be done before
production is `tacplus-dev/roadmap:PRODUCTION.md`.

Work arrives as issues; see github.com/tacplus-dev/looper.

## What it manages
- **A GCP organization** on tacplus.dev (Cloud Identity Free, admins' Google accounts only; we are not an IdP), with its org
  policies: no service-account keys (created or uploaded), Workload Identity Federation from gitlab.com only, us-central1
  only, uniform bucket access, no public buckets, domain-restricted sharing, no default network.
- **Folders and projects:**
  - `bootstrap` / `tacplus-bootstrap`: this pipeline's state bucket, its identity and the secrets it reads (made by the
    bootstrap script, below);
  - `ci` / `tacplus-ci`: the GitLab runner manager VM and its pools (arm64 VMs, each used for one job, accounts with no
    role or no account at all), the identity that bakes the pools' image (below, The runners' image), the build
    bucket, and the tacplus-reader app's KMS key (import-only, empty until the reader moves);
  - `dev` / `tacplus-dev`: the dev GKE cluster (zonal, arm64 Axion C4A nodes, private nodes), the DNS zone
    `dev.tacplus.dev`, and `cluster-admin-pipeline`, federated from tacplus-dev/cluster's protected main;
  - `prod` is designed but **not built**: see PRODUCTION.md.
- **GitLab settings:** this project's protected `main` and environments, its protected project variables (values from
  Secret Manager by version, never in this repository), and the runner registrations of the `ci` pools (registered
  **paused**: moving the runners off jody1-328023 is a later issue).

## Layout

| Path | What |
|---|---|
| `bootstrap/bootstrap.sh` | Jody's one-time script (below). |
| `modules/settings` | The names every stack shares: domain, region, project IDs, the pipeline's identity, the runner pools. |
| `modules/org`, `modules/projects/ci`, `modules/projects/dev`, `modules/gitlab` | The modules. |
| `stacks/<org\|ci\|dev\|gitlab>` | The four roots, each its own state (`gs://tacplus-bootstrap-tofu-state/<stack>`), OpenTofu and providers pinned exactly, `.terraform.lock.hcl` with every provider's hashes, `tests/` (its plan against mock providers). |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLOUD_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | `tools` (pinned tools, by checksum), `gitlab-provider` (the gitlab provider, built from source), `tofurc` (OpenTofu installs that build only), `lint`, `checks`, `policy`, `tofu` (plan, apply, drift), `drift`, `lib` (credentials), `lock`, `pin`, `runner-image` (the pools' image bump). |
| `security-exceptions.yaml` | The known vulnerabilities accepted until a fixed release exists, each with its reason and expiry (below). |
| `tests/` | The tests (`ci/checks.sh` runs them all), their fixtures and stubs. |

## How it runs

The code lives here. CI runs on GitLab, in the project `tacplus-dev/cloud`, the cluster pattern: the project carries only
its `.gitlab-ci.yml`, which is `ci/gitlab-project.gitlab-ci.yml` from here with `CLOUD_COMMIT` set to the commit of this
repository it plans and applies. Every job fetches this repository at that commit (it is public: no credential).

- **Identity:** `cloud-admin-pipeline@tacplus-bootstrap.iam.gserviceaccount.com`, through Workload Identity Federation
  (pool `gitlab-com`, provider `tacplus-dev-cloud` in `tacplus-bootstrap`, condition: `tacplus-dev/cloud`, a protected
  branch `main`). No keys anywhere. The gitlab stack's GitLab token is read from Secret Manager, by the version
  `modules/settings` names.
- **Runner:** a project runner locked to the GitLab project, tag `cloud`, a fresh VM per job with no Google account. Every
  job is tagged for it.
- **Order:** the checks, then `org` (policies, folders), then `ci` and `dev` (the projects), then `gitlab` (whose runner
  tokens go to the `ci` project's secrets). Each stage's plan is made after the stage before it is applied.

| Job | When | What |
|---|---|---|
| `tools` | every push and merge request | OpenTofu, tflint (and its google ruleset), shellcheck and yq, pinned by version and SHA-256, and the gitlab provider built from source (`ci/tools.sh`); checks the project's `.gitlab-ci.yml` is this repository's with only `CLOUD_COMMIT` set (`ci/pin.sh --check`). |
| `fmt`, `validate`, `tflint`, `shellcheck`, `policy` | every push and merge request | `ci/lint.sh <job>`: no credential, no cloud. `policy` refuses a service-account key, `allUsers`/`allAuthenticatedUsers`, and what a commit does not fix (`timestamp()`, `uuid()`, an image at `:latest`, an image family). |
| `test` | every push and merge request | `ci/checks.sh`: the shell tests, and `tofu test` of each stack: its plan against a stub organization and empty projects (mock providers). |
| `plan:<stack>` | main (push, web, API) | `ci/tofu.sh plan`: the plan, saved as the artifact `plans/<stack>.tfplan` with its `.txt` (to read), `.json` and `.sha256`; refused, and so never applied, if `ci/policy.sh` refuses the plan. The artifacts are for project members only (a plan can hold secret values). |
| `apply:<stack>` | main, **automatically** once its plan succeeds | `ci/tofu.sh apply`: applies **exactly that saved plan** (its SHA-256 checked; OpenTofu refuses it if the state changed since). Environment `<stack>`, one at a time. |
| `drift` | the nightly schedule | A plan of every stack, saved nowhere, no lock; if anything differs, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cloud jobs run only on main, because Workload Identity Federation admits only this project's protected main: a merge
request gets the checks, and its plan runs once it is merged. Only `apply-prod` (not built) will be a protected manual job
that Jody plays, on a commit already applied to dev.

### Determinism

- Every tool, provider and image is pinned by version and digest: OpenTofu 1.13.2, tflint 0.65.0 and its google ruleset
  0.41.0, shellcheck 0.11.0 (each by SHA-256, `ci/tools.sh`); yq by module version (the Go checksum database); the
  `google` 8.9.0 and `gitlab` 19.5.0 providers, by hash in each lock file (`ci/lock.sh` writes them; jobs init with
  `-lockfile=readonly`), the `gitlab` one our own reproducible build (below), by its commit and its SHA-256; the CI image by digest; the VMs' Ubuntu image by name, their packages from one Ubuntu archive
  snapshot; the pools' baked image by name and their startup-script by SHA-256 (below, The runners' image); GitLab Runner and its fleeting plugin by SHA-256; the runners' default image by digest.
- The same commit produces the same plan: nothing in the source resolves at plan time what a commit does not fix
  (`ci/policy.sh`), and the only inputs are the commit, the pins, and the cloud's state.
- Nothing is applied that isn't in a reviewed commit: `apply` applies only the plan its pipeline saved, of `CLOUD_COMMIT`,
  a commit of main. Anything changed by hand shows up in the nightly drift.

### Known vulnerabilities

`govulncheck -mode=binary` of every pinned binary is clean, or each finding left is accepted in
`security-exceptions.yaml` (the form looper-scan reads, tacplus-dev/looper#49) with its reason and an expiry, and its pin
moves to the first upstream release with the fix (#3):

- **The `gitlab` provider is built from source** (`ci/gitlab-provider.sh`), because upstream's 19.5.0 is built with
  go1.26.5 and x/net v0.58.0, without Go's crypto/x509, crypto/tls and net/http fixes, and it holds the GitLab token. Its
  tag v19.5.0 at the pinned commit, with go1.26.10 and x/net v0.62.0, every module checked against the Go checksum
  database, built as upstream builds it and reproducibly: each build is refused unless its SHA-256 is the pinned one.
  `ci/tools.sh` puts this platform's build in `bin/providers`; OpenTofu installs `gitlabhq/gitlab` from there and never
  from the registry (`ci/tofurc.sh`, which every script running tofu sources), and the lock file holds only this build's
  hashes, for the four platforms (`ci/lock.sh` builds them all). It goes when an upstream release is built on a fixed Go.
- **Accepted until 2026-12-03:** OpenTofu 1.13.2, the `google` provider 8.9.0, tflint 0.65.0 and its ruleset 0.41.0,
  GitLab Runner v19.5.2 and the fleeting plugin v1.3.1: x/net HTTP/2 and html, x/crypto/openpgp, x/mod's sumdb and a gRPC
  server panic. They run on trusted, pinned inputs (lock-file hashes, this repository, Google APIs and gitlab.com over
  TLS), and none of them has a fixed release yet.

No job here runs the scan yet (PROPOSALS.md, deterministic security checks): the nightly agent scan does.

### How a change flows

1. A pull request here; the tests run as its gates (the looper's land, or `ci/lint.sh all && ci/checks.sh`).
2. Merged, a merge request in the GitLab project setting `.gitlab-ci.yml` to `ci/pin.sh <commit>`'s output, for that commit
   of main: the checks run on it.
3. Merged there, the pipeline on main: checks → `plan:org` → `apply:org` → `plan:ci`, `plan:dev` → `apply:ci`, `apply:dev` →
   `plan:gitlab` → `apply:gitlab`. Each plan is in its job's log and its artifact; each apply applies that plan. Nothing
   waits for Jody (not production).

To review a plan: the `plan:<stack>` job's log, or its artifact `src/plans/<stack>.txt`.

## Bootstrap

`bootstrap/bootstrap.sh` is the one manual step. Jody runs it once, with his own account. It:

1. puts the Cloud Identity Free sign-up's TXT record for tacplus.dev in the Cloud DNS zone `tacplus-dev` (jody1-328023),
   beside any other TXT value, and waits for the organization, which Google creates once the domain is verified;
2. creates the folder `bootstrap`, the project `tacplus-bootstrap` in it (billing linked, the APIs the pipeline calls) and
   the state bucket `gs://tacplus-bootstrap-tofu-state` (us-central1, versioned, uniform access, public access prevented);
3. creates `cloud-admin-pipeline`, gives it its rights (on the organization: folderAdmin, projectCreator,
   orgpolicy.policyAdmin, iam.securityAdmin, organizationViewer, browser; billing.user on the billing account;
   storage.objectAdmin on the state bucket; secretAccessor on the bootstrap project), and its WIF pool `gitlab-com` and
   provider `tacplus-dev-cloud` for gitlab.com, conditioned on `tacplus-dev/cloud`'s protected `main`;
4. creates the empty secrets `gitlab-token`, `tacplus-reader-app-id` and `tacplus-reader-installation-id`.

It looks at everything first and **refuses, before changing anything,** when something exists but is not what it would
create; it never changes or deletes what exists. It prints every command and what it created. Run again, it is a no-op
("nothing to do"); after a partial run, it creates the rest. `--dry-run` changes nothing and prints the commands a run
would run. To also give the running account the rights to make the folder and the project, it grants it
`folderCreator` and `projectCreator` on the organization.

### What Jody runs, in order

Needs `gcloud` and `jq`, signed in (`gcloud auth login`) as an account that can write the Cloud DNS zone `tacplus-dev` in
jody1-328023 and is a billing administrator of the billing account (`gcloud billing accounts list` shows its ID).

1. **Sign up** for Cloud Identity Free with the domain tacplus.dev (https://workspace.google.com/gcpidentity/signup). When
   it asks to verify the domain, copy its TXT value, `google-site-verification=...`; do not click Verify yet.
2. **The TXT record:**

   ```sh
   bootstrap/bootstrap.sh --billing-account <ID> --verification-token google-site-verification=<...> --dry-run
   bootstrap/bootstrap.sh --billing-account <ID> --verification-token google-site-verification=<...>
   ```

   It adds the record and stops (exit 3, "waiting for the organization").
3. **Verify** in the sign-up, and sign in once to console.cloud.google.com as its super admin: the organization appears.
   If the account that runs the script is not that super admin, give it Organization Administrator on the organization
   (IAM, at the organization).
4. **The rest:**

   ```sh
   bootstrap/bootstrap.sh --billing-account <ID> --dry-run     # read what it would create
   bootstrap/bootstrap.sh --billing-account <ID>               # create it
   ```

   It ends with the value of `GCP_WIF_PROVIDER`.
5. **The secrets' values**, version 1 each, typed or pasted without echoing (`--data-file=-` reads standard input, then
   Ctrl-D):

   ```sh
   gcloud secrets versions add gitlab-token --project=tacplus-bootstrap --data-file=-
   gcloud secrets versions add tacplus-reader-app-id --project=tacplus-bootstrap --data-file=-
   gcloud secrets versions add tacplus-reader-installation-id --project=tacplus-bootstrap --data-file=-
   ```

   `gitlab-token`: a group access token of tacplus-dev, role Owner, scope `api` (it registers group runners and sets
   protected environments). The reader's two IDs: the same as tacplus-dev/cluster's `TACPLUS_READER_APP_ID` and
   `TACPLUS_READER_INSTALLATION_ID`.
6. `bootstrap/bootstrap.sh --billing-account <ID>` once more: "nothing to do".

Then the hub's steps below, then the first pipeline. The first real apply is that pipeline's, after Jody's bootstrap.

### Before the first pipeline (the hub)

1. **The GitLab project** `tacplus-dev/cloud`: `main` protected (Maintainers push and merge, no force push); group and
   shared runners off; pipeline variables allowed to the Owner role only.
2. **The runner:** a project runner registered to `tacplus-dev/cloud` only, tag `cloud`, VMs used once, with no Google
   account (as tacplus-dev/cluster's, on `gitlab-runner-mgr`, until runners move).
3. **Its variable** `GCP_WIF_PROVIDER` (protected), the value the bootstrap printed. The gitlab stack adopts it and `main`'s
   protection (its import blocks), and sets the reader's two variables from Secret Manager.
4. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cloud` with Issues read and write, and this
   project's federated principal
   (`principalSet://iam.googleapis.com/projects/<tacplus-bootstrap's number>/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cloud`)
   allowed to sign with the KMS key `tacplus-reader` in jody1-328023 (`roles/cloudkms.signer`).
5. **`.gitlab-ci.yml`** from `ci/pin.sh <commit of main>`, and a nightly schedule on main.

The first pipeline on main then creates the org policies and folders, the `ci` and `dev` projects, and the GitLab
settings, each from its saved plan. After `apply:dev`, the dev zone's delegation (its name servers are `apply:dev`'s output
`dns_name_servers`) goes into tacplus.dev's zone, which is still in jody1-328023:
`gcloud dns record-sets create dev.tacplus.dev. --type=NS --ttl=300 --zone=tacplus-dev --project=jody1-328023 --rrdatas=<the four name servers>`.

## Break-glass

When the pipeline itself is broken (its identity refused, its state locked, a bad apply it cannot undo), and only then:

1. Jody signs in with his own account (the organization's super admin, or the account the bootstrap ran as); nobody else
   holds write access. Every action is in the organization's Admin Activity audit logs.
2. An issue here says what is broken, why break-glass, and what was done, command by command.
3. The fix is made as narrow as it can be: a stuck state lock is released with
   `tofu force-unlock <id>` in the stack (from a checkout at main, `ci/tools.sh`, `tofu init -lockfile=readonly`); an
   identity is restored with `bootstrap/bootstrap.sh` (it creates only what is missing); anything else with `gcloud`.
4. Then it is made deterministic: the change is captured as a commit here and applied by the pipeline, or reverted. The
   next drift check must show no difference.

## Rotating the GitLab token

Add the new token as the next version of `gitlab-token` (`gcloud secrets versions add ...`), change the version in
`modules/settings` (`gitlab_token_secret`) in a commit, and let the pipeline run; then disable the old version.

## The runners' image

The pools' VMs boot an image with Docker already in it, and no job is placed on a VM before it is ready (#4;
tacplus-dev/looper#43, its README "A fresh VM is ready before its job"); each VM takes one job and is deleted
(`capacity_per_instance = 1`, `max_use_count = 1`, looper#42).

- **The readiness gate.** Every pool's `instance_ready_command` waits, at most ten minutes, for the startup-script's
  `/var/run/runner-ready` and an active Docker (`files/config.toml.tftpl`); a VM not ready by then is removed.
- **The image** is baked by looper's `runner-image build` (tacplus-dev/build's job `runner-image`, from the web on main
  or its monthly schedule) in `tacplus-ci`: a stock Ubuntu arm64 VM in the `runners` subnet, with no external address
  (its NAT), no account and no scopes, installs Docker and the user `fleeting`, its disk is imaged, a VM of the
  candidate must boot ready with nothing to install, and it is published as `runner-arm64-docker-<date>-<time>`, its
  job's last line. Its identity is `runner-image@tacplus-ci` (`modules/projects/ci/runner-image.tf`): keyless, through
  the pool `gitlab-com` and provider `tacplus-dev-build` of `tacplus-ci`, which admit only tacplus-dev/build's protected
  `main` in its environment `runner-image`, from the web or a schedule; its role may manage only the bake's instances
  and disks (`runner-image-*`) and images (`runner-arm64-docker-*`), and it may use only the `runners` subnet.
- **The pin.** The pools boot the image `modules/settings` names (`runner_image.image`), **by name, never its family**
  (`decisions/deterministic-deployments-2026-11-02.md`: a family resolves the newest image at each VM's creation, so a
  bake would change every worker without a commit; `ci/policy.sh` refuses an image family). Their startup-script is
  looper's `runner/startup.sh` at the commit the image was baked from (`runner_image.looper_commit`), kept as
  `modules/projects/ci/files/runner-startup.sh` and pinned by its SHA-256 (the plan refuses another), with guest
  attributes on, and the manager connects as `fleeting`. While `image` is `null` (no bake yet), they boot the pinned
  Ubuntu and install Docker from its archive snapshot at boot (`files/worker-startup.sh`), the manager connecting as
  `runner`; the gate holds each job until that is done.
- **The bump**, after each bake: its job's last line names the image (tacplus-dev/looper#67), and an issue here, or a
  merge request of the pin, asks for it (the hub's, until the job opens it: PROPOSALS.md). The change is one command
  and a commit:

  ```sh
  ci/runner-image.sh runner-arm64-docker-<date>-<time> <the looper commit the bake ran>
  git commit -am "runner pools: boot runner-arm64-docker-<date>-<time>"   # modules/settings, files/runner-startup.sh
  ```

  It pins the name, and writes that commit's `runner/startup.sh` with its commit and SHA-256; it refuses a family, a
  path, or another name. Merged, the pipeline's `plan:ci` shows the templates replaced and `apply:ci` applies them: new
  VMs boot the new image, a VM already up finishes its one job on the old one.
- **Rollback** is a revert of the bump, through the same plan and apply, as long as the bake still keeps the old
  image: it keeps the newest `RUNNER_IMAGE_KEEP` (3) of the family and deletes the rest, so bump before the fourth bake
  after the pinned one, or the pools' template names an image that no longer exists (PROPOSALS.md).

**Not yet:** the bake cannot run in `tacplus-ci` until `runner-image build` can use a subnet with no external address
(tacplus-dev/looper#67, `RUNNER_IMAGE_SUBNET`, and a pinned Docker). Then tacplus-dev/build's job gets its variables,
scoped to its environment `runner-image` so its other jobs keep theirs: `GCP_WIF_PROVIDER`, `GCP_RUNNER_IMAGE_SA` and
`RUNNER_IMAGE_SUBNET` (the ci stack's output `runner_image_bake`), `RUNNER_IMAGE_PROJECT=tacplus-ci`,
`RUNNER_IMAGE_ZONE=us-central1-b`; the first bake; its bump; and, once the runners have moved here and twenty jobs ran
on fresh VMs, `runner-image measure 20` shows no first-job image-pull failure (#4's acceptance).

## People

Readers get `viewer` and `iam.securityReviewer` on the organization and nothing that writes: their tacplus.dev accounts,
listed in `stacks/org/main.tf` (`readers`) by a commit. Domain-restricted sharing admits only the organization's own
directory.

## Locally

```sh
ci/tools.sh                      # bin/: tofu, tflint (and the google ruleset), shellcheck, yq, the gitlab provider
                                 # (needs go, git, curl, unzip, xz)
ci/lint.sh all                   # fmt, validate, tflint, shellcheck, policy
ci/checks.sh                     # the tests, and tofu test of every stack against mock providers
bootstrap/bootstrap.sh --billing-account <ID> --dry-run    # with your gcloud: changes nothing
ci/lock.sh                       # after changing a provider's version, or ci/gitlab-provider.sh: the lock files
```

## Never

- Applies anything not in a plan saved by its own pipeline, of a commit of main.
- Creates a service-account key, or grants anything to `allUsers` or `allAuthenticatedUsers`.
- Deletes a project, a folder, the cluster or the reader's key: projects are `deletion_policy = PREVENT`, folders and the
  cluster deletion-protected, the key `prevent_destroy`. Deleting one is Jody's, on purpose.
- Builds `prod`.
