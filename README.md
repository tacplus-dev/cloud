# cloud

The pipeline that owns tacplus-dev's cloud accounts. Every change to GCP and GitLab configuration is a commit here, applied
by a pipeline. People, the hub included, have read-only access.

Design: tacplus-dev/roadmap#2 and `tacplus-dev/roadmap:decisions/cloud-pipeline-2026-11-02.md` (approved by Jody, 2026-11-02);
the rule that every deployment is deterministic, `decisions/deterministic-deployments-2026-11-02.md`, whose addendum
"approval only for production" makes `ci` and `dev` apply without waiting for Jody. The list of what must be done before
production is `tacplus-dev/roadmap:PRODUCTION.md`.

Work arrives as issues; see github.com/tacplus-dev/looper.

## What it manages
- **A folder handed to it, not an organization of its own:** it runs in a parent folder that some organization (the host)
  hands over, and names no organization, so that anyone can run it in a folder of their own (below, What the host
  organization provides). The org policies it relies on are the host organization's job.
- **Folders and projects,** all under the parent folder:
  - `bootstrap` / `tacplus-bootstrap`: this pipeline's state bucket, its identity and the secrets it reads (made by the
    bootstrap script, below);
  - `ci` / `tacplus-ci`: the GitLab runner manager VM and its pools (arm64 Container-Optimized OS VMs shared by job
    containers, one always on: below, The runners' image), the build cache (below, The build cache), and the
    tacplus-reader app's KMS key (import-only, empty until the reader moves);
  - `dev` / `tacplus-dev`: the dev GKE cluster (zonal, arm64 Axion C4A nodes, private nodes), the DNS zone
    `dev.tacplus.dev`, `cluster-admin-pipeline`, federated from tacplus-dev/cluster's protected main, and each
    deployment's certificate secrets and `_acme-challenge` zone, which only its pipeline writes (below, Certificates);
  - `prod` is designed but **not built**: see PRODUCTION.md.
- **GitLab settings:** this project's protected `main` and environments, its protected project variables (values from
  Secret Manager by version, never in this repository), and the runner registrations of the `ci` pools (registered
  **paused**: moving the runners off jody1-328023 is a later issue).

## Layout

| Path | What |
|---|---|
| `bootstrap/bootstrap.sh` | Jody's one-time script (below). |
| `modules/settings` | The names every stack shares: the parent folder (an input, never written here), region, project IDs, the pipeline's identity, the runner pools. |
| `modules/folder`, `modules/projects/ci`, `modules/projects/dev`, `modules/gitlab` | The modules. |
| `stacks/<folder\|ci\|dev\|gitlab>` | The four roots, each its own state (`gs://tacplus-bootstrap-tofu-state/<stack>`), OpenTofu and providers pinned exactly, `.terraform.lock.hcl` with every provider's hashes, `tests/` (its plan against mock providers). |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLOUD_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | `tools` (pinned tools, by checksum), `security` (the security job), `gitlab-provider` (the gitlab provider, built from source), `tofurc` (OpenTofu installs that build only), `lint`, `checks`, `policy`, `tofu` (plan, apply, drift), `drift`, `lib` (credentials), `lock`, `pin`. |
| `security-exceptions.yaml` | The known vulnerabilities accepted until a fixed release exists, each with its reason and expiry; the `security` job enforces them (below). |
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
- **The parent folder:** the protected project variable `GCP_PARENT_FOLDER`, its numeric ID; `ci/lib.sh` gives it to the
  stacks as their variable `parent_folder`, and refuses a job without one. No file here holds it.
- **Order:** the checks, then `folder` (the folders), then `ci` and `dev` (the projects), then `gitlab` (whose runner
  tokens go to the `ci` project's secrets). Each stage's plan is made after the stage before it is applied.

| Job | When | What |
|---|---|---|
| `tools` | every push and merge request | OpenTofu, tflint (and its google ruleset), shellcheck, yq and gitleaks, pinned by version and SHA-256, and the gitlab provider built from source (`ci/tools.sh`); checks the project's `.gitlab-ci.yml` is this repository's with only `CLOUD_COMMIT` set (`ci/pin.sh --check`). |
| `fmt`, `validate`, `tflint`, `shellcheck`, `policy` | every push and merge request | `ci/lint.sh <job>`: no credential, no cloud. `policy` refuses a service-account key, `allUsers`/`allAuthenticatedUsers`, and what a commit does not fix (`timestamp()`, `uuid()`, an image at `:latest`, an image family). |
| `test` | every push and merge request | `ci/checks.sh`: the shell tests, and `tofu test` of each stack: its plan under a stub parent folder, with empty projects (mock providers). |
| `security` | every push and merge request, and the nightly schedule | `ci/tools.sh security && ci/security.sh`: OSV-Scanner, govulncheck, gitleaks and Trivy, the policy and `security-exceptions.yaml` (below, Security checks); its report the artifact `src/security/`. `plan:folder` needs it: no plan, so no apply, unless it passes. |
| `plan:<stack>` | main (push, web, API) | `ci/tofu.sh plan`: the plan, saved as the artifact `plans/<stack>.tfplan` with its `.txt` (to read), `.json` and `.sha256`; refused, and so never applied, if `ci/policy.sh` refuses the plan. The artifacts are for project members only (a plan can hold secret values). |
| `apply:<stack>` | main, **automatically** once its plan succeeds | `ci/tofu.sh apply`: applies **exactly that saved plan** (its SHA-256 checked; OpenTofu refuses it if the state changed since). Environment `<stack>`, one at a time. |
| `drift` | the nightly schedule | A plan of every stack, saved nowhere, no lock; if anything differs, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cloud jobs run only on main, because Workload Identity Federation admits only this project's protected main: a merge
request gets the checks, and its plan runs once it is merged. Only `apply-prod` (not built) will be a protected manual job
that Jody plays, on a commit already applied to dev.

### Determinism

- Every tool, provider and image is pinned by version and digest: OpenTofu 1.13.2, tflint 0.65.0 and its google ruleset
  0.41.0, shellcheck 0.11.0, Trivy 0.76.1 (each by SHA-256, `ci/tools.sh`); yq by module version (the Go checksum
  database); gitleaks v8.30.1, OSV-Scanner v2.7.0 and govulncheck v1.1.4 by module version and hash, built with Go 1.27.3; the
  `google` 8.9.0 and `gitlab` 19.5.0 providers, by hash in each lock file (`ci/lock.sh` writes them; jobs init with
  `-lockfile=readonly`), the `gitlab` one our own reproducible build (below), by its commit and its SHA-256; the CI image by digest; the manager's Ubuntu image by name, its packages from one Ubuntu
  archive snapshot; the pools' Container-Optimized OS image by name (below, The runners' image); GitLab Runner and its
  fleeting plugin by SHA-256; the runners' default image by digest.
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

- **Accepted until 2026-12-04** (#10): gitleaks v8.30.1's xz (GO-2025-3922), with no gitleaks release past it yet.

The `security` job enforces it (below), on every pipeline.

### Security checks

tacplus-dev/looper#49's floor, in this pipeline (#10): tacplus-dev/build's checks, which run it elsewhere, never reach
this one, which applies with the strongest credentials we have. `ci/security.sh`, the `security` job, on every push, merge
request and nightly schedule:

- **OSV-Scanner** on the tree's dependency manifests and lock files (the commit's tree; today it reads none of them:
  the providers' lock files are OpenTofu's, and their binaries are scanned below);
- **`govulncheck -mode=binary`** on every pinned binary the pipeline runs or installs, symbols present: OpenTofu, tflint
  and its google ruleset, yq, gitleaks, OSV-Scanner, Trivy and govulncheck, the `gitlab` provider (`bin/`), the `google`
  provider (from the lock files' hashes) and GitLab Runner and its fleeting plugin (from `stacks/ci/main.tf`'s pins)
  (`bin/scan/`, `ci/tools.sh security`). shellcheck is not Go;
- **gitleaks** on the tree and its whole history (the job fetches it: a shallow clone fails);
- **Trivy** on the CI image the jobs run in, by its digest (`default.image`).

**The policy** is looper-scan's: it fails on any secret, and on any HIGH or CRITICAL finding that has a fixed version,
unless an unexpired entry of `security-exceptions.yaml` names it (its ID or an alias); an entry that has expired, or
whose fields are not exactly `id`, `reason`, `decided_by` and `expires` (YYYY-MM-DD), fails it too, and so does a tool
that cannot run or a pinned binary missing. A failing `security` job stops the pipeline before `plan:folder`. The report:
`security/report.json` (every finding: blocking, accepted or neither; the problems; the verdict), with each tool's own
report in `security/raw/`; the job's artifact, kept 30 days. The vulnerability databases are the day's, so a commit
that passed can fail the next night: fix the pin, or accept the finding with a reason and an expiry, at most 30 days.
`tests/security_test.sh` tests it (a planted secret, an expired exception, a clean tree, the policy) with stubs for
the scanners that need a database.

### How a change flows

1. A pull request here; the tests run as its gates (the looper's land, or `ci/lint.sh all && ci/checks.sh`).
2. Merged, a merge request in the GitLab project setting `.gitlab-ci.yml` to `ci/pin.sh <commit>`'s output, for that commit
   of main: the checks run on it.
3. Merged there, the pipeline on main: checks → `plan:folder` → `apply:folder` → `plan:ci`, `plan:dev` → `apply:ci`, `apply:dev` →
   `plan:gitlab` → `apply:gitlab`. Each plan is in its job's log and its artifact; each apply applies that plan. Nothing
   waits for Jody (not production).

To review a plan: the `plan:<stack>` job's log, or its artifact `src/plans/<stack>.txt`.

## Bootstrap

`bootstrap/bootstrap.sh` is the one manual step. Jody runs it once, with his own account, in the parent folder the host
organization handed over (`--folder`, its numeric ID). It:

1. creates the folder `bootstrap` under the parent folder, the project `tacplus-bootstrap` in it (billing linked, the APIs
   the pipeline calls) and the state bucket `gs://tacplus-bootstrap-tofu-state` (us-central1, versioned, uniform access,
   public access prevented);
2. creates `cloud-admin-pipeline`, gives it its rights (billing.user on the billing account; storage.objectAdmin on the
   state bucket; secretAccessor on the bootstrap project), and its WIF pool `gitlab-com` and provider `tacplus-dev-cloud`
   for gitlab.com, conditioned on `tacplus-dev/cloud`'s protected `main`;
3. creates the empty secrets `gitlab-token`, `tacplus-reader-app-id` and `tacplus-reader-installation-id`.

It reads and asks for nothing above the parent folder, for itself or for the account that runs it: its commands are
scoped to the parent folder, what it creates there, and the billing account. `cloud-admin-pipeline`'s rights on the
parent folder are the host's grants (below), not the script's: it reads them, and says which are still to be granted.
It looks at everything first and **refuses, before changing anything,** when something exists but is not what it would
create; it never changes or deletes what exists. It prints every command and what it created. Run again, it is a no-op
("nothing to do"); after a partial run, it creates the rest. `--dry-run` changes nothing and prints the commands a run
would run.

### What the host organization provides

The host organization's admin (its own pipeline, outside this repository) provides:

- **The parent folder**, handed to this repository. Its numeric ID is an input: `--folder` here, and the protected
  GitLab variable `GCP_PARENT_FOLDER` (below, Before the first pipeline). It is written in no file of this repository.
- **For the account that runs the bootstrap**, for that one run: `roles/resourcemanager.folderAdmin` and
  `roles/resourcemanager.projectCreator` on the parent folder; and Billing Account Administrator on the billing account,
  to link the project and grant `billing.user` to `cloud-admin-pipeline`.
- **For `cloud-admin-pipeline`**, once the bootstrap has made it: `roles/resourcemanager.folderAdmin`,
  `roles/resourcemanager.projectCreator` and `roles/owner` on the parent folder. Nothing beyond these, and nothing at
  the organization's level: this repository holds no right over the host's organization.
- **The org policies, the host organization's job.** It enforces them for everything under it, the parent folder
  included, and checks them for drift; this repository relies on them and sets none (`roles/orgpolicy.policyAdmin` can be
  granted only at an organization's level). The set it relies on:
  - `iam.disableServiceAccountKeyCreation` and `iam.disableServiceAccountKeyUpload`, enforced: no service-account key;
  - `iam.workloadIdentityPoolProviders`: `https://gitlab.com` only;
  - `gcp.resourceLocations`: `in:us-central1-locations` (the region `modules/settings` names);
  - `storage.uniformBucketLevelAccess` and `storage.publicAccessPrevention`, enforced: no object ACL, no public bucket;
  - `compute.skipDefaultNetworkCreation`, enforced: no default network;
  - `iam.allowedPolicyMemberDomains`: the host's own directories (the readers below are of one of them).
- **Who signs in as a person:** the accounts, the readers' and the break-glass account (below, Break-glass), are the
  host's directory's.

<!-- hosting note -->
Today the host is seabeam.net's organization: the parent folder is its folder `tacplus-dev`, and its admin is the closed
pipeline seabeam/cloud (GitLab), `tacplus-dev/roadmap:decisions/cloud-org-seabeam-2026-11-03.md`. Nothing here depends on
it: another host is another folder ID.
<!-- /hosting note -->

### What Jody runs, in order

Needs `gcloud` and `jq`, signed in (`gcloud auth login`) as an account holding the host's grants above, and the parent
folder's ID and the billing account's (`gcloud billing accounts list` shows it).

1. **The bootstrap:**

   ```sh
   bootstrap/bootstrap.sh --folder <FOLDER_ID> --billing-account <ID> --dry-run     # read what it would create
   bootstrap/bootstrap.sh --folder <FOLDER_ID> --billing-account <ID>               # create it
   ```

   It ends with the values of `GCP_PARENT_FOLDER` and `GCP_WIF_PROVIDER`, and the host's grants to
   `cloud-admin-pipeline` still to be made.
2. **The host's grants** to `cloud-admin-pipeline` on the parent folder (above), made by the host organization's admin.
3. **The secrets' values**, version 1 each, typed or pasted without echoing (`--data-file=-` reads standard input, then
   Ctrl-D):

   ```sh
   gcloud secrets versions add gitlab-token --project=tacplus-bootstrap --data-file=-
   gcloud secrets versions add tacplus-reader-app-id --project=tacplus-bootstrap --data-file=-
   gcloud secrets versions add tacplus-reader-installation-id --project=tacplus-bootstrap --data-file=-
   ```

   `gitlab-token`: a group access token of tacplus-dev, role Owner, scope `api` (it registers group runners and sets
   protected environments). The reader's two IDs: the same as tacplus-dev/cluster's `TACPLUS_READER_APP_ID` and
   `TACPLUS_READER_INSTALLATION_ID`.
4. `bootstrap/bootstrap.sh --folder <FOLDER_ID> --billing-account <ID>` once more: "nothing to do", and the host's
   grants in place.

Then the hub's steps below, then the first pipeline. The first real apply is that pipeline's, after Jody's bootstrap.

### Before the first pipeline (the hub)

1. **The GitLab project** `tacplus-dev/cloud`: `main` protected (Maintainers push and merge, no force push); group and
   shared runners off; pipeline variables allowed to the Owner role only.
2. **The runner:** a project runner registered to `tacplus-dev/cloud` only, tag `cloud`, VMs used once, with no Google
   account (as tacplus-dev/cluster's, on `gitlab-runner-mgr`, until runners move).
3. **Its variables** `GCP_PARENT_FOLDER` and `GCP_WIF_PROVIDER` (protected), the values the bootstrap printed. The gitlab stack adopts it and `main`'s
   protection (its import blocks), and sets the reader's two variables from Secret Manager.
4. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cloud` with Issues read and write, and this
   project's federated principal
   (`principalSet://iam.googleapis.com/projects/<tacplus-bootstrap's number>/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/cloud`)
   allowed to sign with the KMS key `tacplus-reader` in jody1-328023 (`roles/cloudkms.signer`).
5. **`.gitlab-ci.yml`** from `ci/pin.sh <commit of main>`, and a nightly schedule on main.

The first pipeline on main then creates the folders, the `ci` and `dev` projects, and the GitLab
settings, each from its saved plan. After `apply:dev`, the dev zone's delegation (its name servers are `apply:dev`'s output
`dns_name_servers`) goes into tacplus.dev's zone, which is still in jody1-328023:
`gcloud dns record-sets create dev.tacplus.dev. --type=NS --ttl=300 --zone=tacplus-dev --project=jody1-328023 --rrdatas=<the four name servers>`.
The challenge zone's delegation is the hub's too, once seatrials' pipeline moves to its identity here (below,
Certificates).

## Break-glass

When the pipeline itself is broken (its identity refused, its state locked, a bad apply it cannot undo), and only then:

1. Jody signs in with his own account (the account the bootstrap ran as, given its grants again by the host, or the host's
   break-glass account); nobody else holds write access. Every action is in the Admin Activity audit logs.
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

The pools' VMs are vanilla: Google's **Container-Optimized OS** for arm64, pinned by image name, with nothing installed
at boot and the OS's own container runtime (#4; `tacplus-dev/roadmap:decisions/builds-in-containers-2026-11-03.md`,
which replaced the baked image of tacplus-dev/looper#43). No job is placed on a VM before that runtime answers. Job
containers share the VMs, which are reused (#5, `decisions/looper-job-per-issue-2026-11-03.md`; below, The pools).

- **The readiness gate.** Every pool's `instance_ready_command` waits, at most ten minutes, until `docker info` answers
  the user the manager connects as (`files/config.toml.tftpl`); a VM not ready by then is removed. That user, `runner`,
  is created by the OS's guest agent from the SSH key the fleeting plugin sets, in the OS's `docker` group.
- **The VM.** No startup-script, and no OS update (`cos-update-strategy = update_disabled`): the image changes only
  with its pin. COS's root is read-only, so a job's builds stay in the executor's own volume (no host `/builds`); the
  jobs still get the host's Docker socket until looper's build jobs replace it (PROPOSALS.md).
- **The pin.** The pools boot the image `modules/settings` names (`cos_arm64_image`), **by name, never its family**
  (`decisions/deterministic-deployments-2026-11-02.md`: a family resolves the newest image at each VM's creation, so
  Google's release would change every worker without a commit). The module refuses anything but a COS arm64 image
  name, and `ci/policy.sh` refuses an image family anywhere in the source.
- **A bump** is a normal pin commit: pick the build (`gcloud compute images list --project cos-cloud
  --no-standard-images --filter="family~^cos-arm64-"`, the release notes at
  cloud.google.com/container-optimized-os/docs/release-notes), change `cos_arm64_image`, and let the pipeline run:
  `plan:ci` shows the templates replaced and `apply:ci` applies them; new VMs boot the new image. A VM already up
  keeps the image it booted until it is replaced, the always-on one included (PROPOSALS.md, replace the always-on VM
  on a bump). **Rollback** is a revert, through the same plan and apply.

### The pools

`modules/settings` (`runner_pools`), decided on #5:

| Pool | Runner | VMs | Jobs per VM, each |
|---|---|---|---|
| `shared` | tacplus-dev group runner, not protected; tags `arm64`, `autoscale`, `autoscale-16`, `build` | **one, always on** (`idle_count = 1`, `max_instances = 1`): t2a-standard-8, 250 GB | 2: 4 CPUs, 14g, no swap, 100 GB of disk |
| `deploy` | tacplus-dev/fleet-seatrials, protected; tag `deploy` | on demand (at most 1, kept 30 minutes idle): t2a-standard-4, 80 GB | 2: 2 CPUs, 6g, 25 GB |
| `cluster` | tacplus-dev/cluster, protected; tag `cluster` | on demand (at most 1, kept 30 minutes idle): t2a-standard-2, 50 GB | 2: 1 CPU, 3g, 10 GB |

- **The shared VM** runs the agent jobs (the loopers'), the build jobs (tacplus-dev/build's) and the control jobs (the
  kicker, the planner, the recap, the drift), under the tags today's jobs carry. One VM is one runner registration
  (GitLab does not share an instance group between `[[runners]]` entries), so these jobs share one set of container
  settings: the build jobs' (`jobs.build` in `modules/settings`, today the same as the agents'). If builds need
  settings agents must not get (rootless BuildKit, tacplus-dev/tacplus#315), the split is a `build` pool of its own.
- **Scaling.** Moving the shared VM to t2a-standard-16, four jobs at once, is one line (`shared_machine_type`), on
  Jody's word; so is raising `max_instances`. Scaling down needs no ask.
- **Deploy and cluster** are protected and on demand: their credentials never share a VM with agents, and they cost
  nothing while no deploy runs.
- **Each job:** its container within its CPU and memory limits, without swap; no privileged mode, no host Docker
  socket (`decisions/builds-in-containers-2026-11-03.md`: agents never build; builds use rootless BuildKit); its
  containers and volumes removed when it ends (`disable_cache`: no cache volume outlives its job). No pool's VM has a
  Google account.
- **Disk is bounded per VM, not per job:** COS has no per-container disk limit (overlay2's needs XFS with project
  quotas, which vanilla COS does not have). A VM's disk is its jobs' shares plus 50 GB (30 for the on-demand pools)
  for the OS and the jobs' images; a job that fills it fails the jobs beside it (PROPOSALS.md, per-job disk limits).

## The build cache

`decisions/builds-in-containers-2026-11-03.md`, #5: caches live outside the VMs, in `tacplus-ci`, keyed by content (a
cache only speeds a build up).

- **Where:** the bucket `gs://tacplus-ci-build-cache` (the compilers' remote caches) and the Artifact Registry Docker
  repository `us-central1-docker.pkg.dev/tacplus-ci/build-cache` (BuildKit's registry cache).
- **Who:** the service account `build-cache@tacplus-ci.iam.gserviceaccount.com` alone holds a role on either:
  `storage.objectUser` on the bucket and `artifactregistry.writer` on the repository (authoritative bindings), which
  read and write. Only tacplus-dev/build's jobs, the build jobs, may become it: Workload Identity Federation from
  gitlab.com, the pool `gitlab-com` and provider `tacplus-dev-build` in `tacplus-ci`, condition
  `assertion.project_path == 'tacplus-dev/build'`. A build job gets it with an `id_tokens` token whose audience is
  `//iam.googleapis.com/projects/<tacplus-ci's number>/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-build`.
  No VM carries it: the agent jobs beside the builds get neither.
- **Lifecycle:** an entry unused for 30 days is deleted. The registry deletes a version pushed 30 days ago (a cache
  BuildKit exports again on every build stays young). GCS records no read time: a bucket object is deleted 30 days
  after it was written, and the next build that misses it writes it again.

**Not yet:** nothing is applied before Jody's bootstrap and the first pipeline, and the runners stay paused until they
move off jody1-328023. Once twenty jobs have run here on fresh VMs, looper's `runner-image measure 20` should show no
first-job image-pull failure (#4's acceptance).

## Certificates

`decisions/certificates-by-pipeline-2026-11-03.md`, #6: a deployment's pipeline owns its TLS certificate. Each run checks
it; when it is missing or due, the pipeline obtains one by ACME DNS-01 (`lego`, apex and wildcard) and adds it as a new
secret version, which the uni-config references. Nothing in a cluster holds it, and nobody but that pipeline writes it.

`modules/settings` (`deployments`) lists the deployments; the dev stack gives each, in `tacplus-dev`:

- **Its identity:** the service account `<account_id>@tacplus-dev.iam.gserviceaccount.com`, keyless, through Workload
  Identity Federation (pool `gitlab-com`, provider `<wif_provider>`), condition: its GitLab project's protected `main`.
  It holds no role on the project.
- **Its secrets:** `tls-<deployment>` (the certificate chain and its key) and `acme-account-<environment>` (its ACME
  account's key; the environment is the deployment's GitLab environment), us-central1. Only its identity holds a role on
  them, `secretVersionAdder` and `secretAccessor` (authoritative bindings): it adds versions and reads them. Their values
  are never in this repository, a plan or the state.
- **Its challenge zone:** `acme-challenge-<domain with dashes>` for `_acme-challenge.<domain>.` (DNSSEC on), where
  DNS-01 for `<domain>` and `*.<domain>` writes its TXT records. Only its identity holds `dns.admin` on it (an
  authoritative zone binding), so it cannot touch `<domain>`'s own zone. The zone is delegated from `<domain>`'s zone by
  NS records.

| Deployment | GitLab project | Secrets | Challenge zone | Identity |
|---|---|---|---|---|
| `seatrials` | tacplus-dev/fleet-seatrials (environment `seatrials`) | `tls-seatrials`, `acme-account-seatrials` | `acme-challenge-tacplus-dev`, `_acme-challenge.tacplus.dev.` | `seatrials-deploy` |

The dev stack's output `deployments` names each one's `GCP_WIF_PROVIDER`, service account, secrets, and the name servers
of its zone.

### Interim: by hand in jody1-328023, until the cloud pipeline runs

Until Jody's bootstrap and the first pipeline, seatrials' pipeline runs as `seatrials-deploy@jody1-328023` (tacplus-dev/
fleet-seatrials, docs/deploy-pipeline.md), and tacplus.dev's zone is `tacplus-dev` in jody1-328023. The hub makes the same
three things there, for tacplus.dev, granted to that account only, with these commands (Jody's account or the hub's, as
for the other grants in jody1-328023). The secrets are made empty: the pipeline adds their first versions.

```sh
project=jody1-328023 sa=serviceAccount:seatrials-deploy@jody1-328023.iam.gserviceaccount.com
# The secrets: us-central1; only the pipeline adds versions and reads them.
for s in tls-seatrials acme-account-seatrials; do
  gcloud secrets create $s --project=$project --replication-policy=user-managed --locations=us-central1 \
    --labels=deployment=seatrials
  for role in roles/secretmanager.secretVersionAdder roles/secretmanager.secretAccessor; do
    gcloud secrets add-iam-policy-binding $s --project=$project --role=$role --member=$sa
  done
done
# The challenge zone; only the pipeline administers it.
gcloud dns managed-zones create acme-challenge-tacplus-dev --project=$project --dns-name=_acme-challenge.tacplus.dev. \
  --visibility=public --dnssec-state=on \
  --description="ACME DNS-01 challenges for tacplus.dev: tacplus-dev/fleet-seatrials's pipeline only"
gcloud dns managed-zones add-iam-policy-binding acme-challenge-tacplus-dev --project=$project --role=roles/dns.admin \
  --member=$sa
# Its delegation from tacplus.dev's zone. The name must hold nothing else first: a stale _acme-challenge TXT record is
# removed (gcloud dns record-sets delete _acme-challenge.tacplus.dev. --type=TXT --zone=tacplus-dev --project=$project).
gcloud dns record-sets list --zone=tacplus-dev --project=$project --name=_acme-challenge.tacplus.dev.
ns=$(gcloud dns managed-zones describe acme-challenge-tacplus-dev --project=$project --format=json | jq -r '.nameServers | join(",")')
gcloud dns record-sets create _acme-challenge.tacplus.dev. --type=NS --ttl=300 --zone=tacplus-dev --project=$project \
  --rrdatas="$ns"
# Check: the delegation answers, and only the pipeline holds a role on each.
dig +short NS _acme-challenge.tacplus.dev.
for s in tls-seatrials acme-account-seatrials; do gcloud secrets get-iam-policy $s --project=$project; done
gcloud dns managed-zones get-iam-policy acme-challenge-tacplus-dev --project=$project
```

In jody1-328023, "nobody else" is the resources' own policies: its project owners keep what their project roles give,
as for everything else there until it is drained. The pipeline's `cert` step points `lego`'s Google Cloud DNS provider at
`GCE_PROJECT=jody1-328023` (and, while it runs there, the secrets in jody1-328023).

**Then the cloud pipeline recreates them** in `tacplus-dev` (a zone and a secret cannot move between projects): `apply:dev`
makes the identity, the empty secrets and the zone above. When seatrials moves off jody1-328023, its pipeline switches to
`seatrials-deploy@tacplus-dev` (`GCP_WIF_PROVIDER` from the dev stack's output), the current versions are copied into the
new secrets (no new order: Let's Encrypt's duplicate-certificate limit), the NS records of `_acme-challenge.tacplus.dev.`
are replaced by the new zone's name servers, and the interim secrets and zone are deleted (PROPOSALS.md, the move of
seatrials' certificates).

## People

Readers get `viewer` and `iam.securityReviewer` on the parent folder and nothing that writes: their accounts, listed in
`stacks/folder/main.tf` (`readers`) by a commit. The host's domain-restricted sharing admits only its own directories'
accounts.

## Locally

```sh
ci/tools.sh                      # bin/: tofu, tflint (and the google ruleset), shellcheck, yq, gitleaks, the gitlab
                                 # provider (needs go, git, curl, unzip, xz, jq)
ci/tools.sh security             # bin/: osv-scanner, trivy, govulncheck; bin/scan/: the binaries to scan (dpkg-deb)
ci/security.sh                   # the security job: security/report.json (needs the full history)
ci/lint.sh all                   # fmt, validate, tflint, shellcheck, policy
ci/checks.sh                     # the tests, and tofu test of every stack against mock providers
bootstrap/bootstrap.sh --folder <FOLDER_ID> --billing-account <ID> --dry-run    # with your gcloud: changes nothing
ci/lock.sh                       # after changing a provider's version, or ci/gitlab-provider.sh: the lock files
```

## Never

- Applies anything not in a plan saved by its own pipeline, of a commit of main.
- Creates a service-account key, or grants anything to `allUsers` or `allAuthenticatedUsers`.
- Deletes a project, a folder, the cluster or the reader's key: projects are `deletion_policy = PREVENT`, folders and the
  cluster deletion-protected, the key `prevent_destroy`. Deleting one is Jody's, on purpose.
- Builds `prod`.
