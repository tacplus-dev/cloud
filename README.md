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
    GitHub Apps' KMS keys (`tacplus-manager`, `tacplus-looper` and `tacplus-reader`, import-only), their import jobs,
    the federation that signs with them and the reader's account `fleet-seatrials-reader` (below, The GitHub Apps' keys);
  - `dev` / `tacplus-dev`: the dev GKE cluster (zonal, arm64 Axion C4A, private Container-Optimized OS nodes: a normal
    pool of 3 x c4a-standard-2 on demand, and a spot build pool of c4a-standard-4 from 0 to 3, for build pods only:
    below, The network rules), the DNS zone
    `dev.tacplus.dev`, `cluster-admin-pipeline`, federated from tacplus-dev/cluster's protected main, with its
    cluster-admin in the cluster and the runners' token secrets it reads (below, The cluster pipeline), each
    deployment's certificate secrets and `_acme-challenge` zone, which only its pipeline writes (below, Certificates),
    its `get-credentials` on the cluster, Cloud Build roles, deploy registry, build bucket and environment accounts
    (below, Deployments: images, the cluster and environment accounts), its fleet's CA and crypto file secrets, which
    only its init-secrets job writes (below, The fleet's CA and crypto file), its Google sign-in client's secret,
    which Jody writes in the Console and only its identity reads (below, The Google sign-in client),
    the one public IP, the global address `gateway`, its TCP proxy load balancer passing TLS through to the NEGs of the
    gateway's Service (below, The public entry), and `tacplus.dev`'s own zone, which only this pipeline writes (below,
    The tacplus.dev cutover);
  - `prod` is designed but **not built**: see PRODUCTION.md.
- **The Anthropic organization** (#34): for each deployment that runs llmproxy, its llmproxy's workload identity, the
  federation issuer, the service account, its workspace membership and the rule (below, The Anthropic organization);
  the hand-made seatrials ones adopted by their IDs. Not the one org:admin rule the pipeline itself federates through,
  made by hand and only read here.
- **GitLab settings:** this project's protected `main` and environments, its protected project variables (values from
  Secret Manager by version, never in this repository), the runner registrations of the `ci` pools (registered
  **paused**: moving the runners off jody1-328023 is a later issue), and the read-only memberships of other projects,
  each with an expiry: `tacplus-looper-bot` a Reporter of tacplus-dev/build, for the looper's nightly recap (below,
  Memberships); and tacplus-dev/build's `.gitlab-ci.yml`, its pipeline trigger, whose token is tacplus-dev/looper's
  `BUILD_TRIGGER_TOKEN`, rotated, and its nightly schedules (below, The build pipeline).

## Layout

| Path | What |
|---|---|
| `bootstrap/bootstrap.sh` | Jody's one-time script (below). |
| `modules/settings` | The names every stack shares: the parent folder (an input, never written here), region, project IDs, the pipeline's identity, the runner pools. |
| `modules/folder`, `modules/projects/ci`, `modules/projects/dev`, `modules/gitlab` | The modules. |
| `stacks/<folder\|ci\|dev\|gitlab\|anthropic>` | The five roots, each its own state (`gs://tacplus-bootstrap-tofu-state/<stack>`), OpenTofu and providers pinned exactly, `.terraform.lock.hcl` with every provider's hashes, `tests/` (its plan against mock providers). |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLOUD_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | `tools` (pinned tools, by checksum), `security` (the security job), `gitlab-provider`, `kubernetes-provider` and `anthropic-provider` (those providers, built from source), `anthropic-token` (the anthropic provider's ID tokens, one per exchange), `tofurc` (OpenTofu installs those builds only), `lint`, `checks`, `policy`, `tofu` (plan, apply, drift), `drift`, `audit` (the drift's live audit), `iam-ready` (a new project's IAM gate), `dns` (the drift's DNS check), `expiry` (the drift's expiry check), `build-ci` (tacplus-dev/build's `.gitlab-ci.yml`, checked and linted), `lib` (credentials), `lock`, `pin`. |
| `stacks/gitlab/files/build.gitlab-ci.yml`, `stacks/gitlab/nightly-builds.yaml` | tacplus-dev/build's `.gitlab-ci.yml`, tacplus-dev/looper's copied as is, and its nightly schedules, one per pinned repository (below, The build pipeline). |
| `build.lock`, `gates.yaml` | The build image by digest (the CI image), and the gates run in it (below, How a change flows). |
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
  tokens go to the `ci` project's secrets). Each stage's plan is made after the stage before it is applied. `anthropic`
  runs beside them after the checks, needing none (below, The Anthropic organization).
- **A new project's IAM:** the pipeline's rights in `tacplus-ci` and `tacplus-dev` are its role on the parent folder,
  which reaches a project created seconds before only after a minute or two. In each project module everything after
  the project and its APIs waits for `terraform_data.iam_ready`, which runs `ci/iam-ready.sh`: Resource Manager's
  `testIamPermissions` until the pipeline holds the permissions of the project's first creates on three checks in a
  row, ten seconds apart, bounded to ten minutes. An existing project passes at once.

| Job | When | What |
|---|---|---|
| `tools` | every push and merge request | OpenTofu, tflint (and its google ruleset), shellcheck, yq and gitleaks, pinned by version and SHA-256, and the gitlab, kubernetes and anthropic providers built from source (`ci/tools.sh`); checks the project's `.gitlab-ci.yml` is this repository's with only `CLOUD_COMMIT` set (`ci/pin.sh --check`). |
| `fmt`, `validate`, `tflint`, `shellcheck`, `policy` | every push and merge request | `ci/lint.sh <job>`: no credential, no cloud. `policy` refuses a service-account key, `allUsers`/`allAuthenticatedUsers`, and what a commit does not fix (`timestamp()`, `uuid()`, an image at `:latest`, an image family). |
| `test` | every push and merge request | `ci/checks.sh`: the shell tests, and `tofu test` of each stack: its plan under a stub parent folder, with empty projects (mock providers). The gitlab stack is also planned with its real providers against a stub of gitlab.com's API (`tests/gitlab_plan_test.sh`, #17): gitlab.com is an Enterprise instance to the provider, on Free too; and the anthropic stack against a stub of Anthropic's (`tests/anthropic_plan_test.sh`, #34). |
| `security` | every push and merge request, and the nightly schedule | `ci/tools.sh security && ci/security.sh`: OSV-Scanner, govulncheck, gitleaks and Trivy, the policy and `security-exceptions.yaml` (below, Security checks); its report the artifact `src/security/`. `plan:folder` needs it: no plan, so no apply, unless it passes. |
| `plan:<stack>` | main (push, web, API) | `ci/tofu.sh plan`: the plan, saved as the artifact `plans/<stack>.tfplan` with its `.txt` (to read), `.json` and `.sha256`; refused, and so never applied, if `ci/policy.sh` refuses the plan: a key, a public member, `roles/owner` or `roles/container.admin` to a service account (below, The cluster pipeline), a break of the network rules (below), or an Anthropic identity adopted with a change (below, The Anthropic organization). A failing check is said, not refused. The artifacts are for project members only (a plan can hold secret values). |
| `apply:<stack>` | main, **automatically** once its plan succeeds | `ci/tofu.sh apply`: applies **exactly that saved plan** (its SHA-256 checked; OpenTofu refuses it if the state changed since). Environment `<stack>`, one at a time. |
| `drift` | the nightly schedule | A plan of every stack (`anthropic` once its bootstrap rule is set), saved nowhere, no lock, with its failing checks, then the live audit of the projects against the network rules (`ci/audit.sh`, below), and the expiry check (`ci/expiry.sh`: an expiry within 30 days, below, Memberships); if anything differs, breaks them or expires, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cloud jobs run only on main, because Workload Identity Federation admits only this project's protected main: a merge
request gets the checks, and its plan runs once it is merged. Only `apply-prod` (not built) will be a protected manual job
that Jody plays, on a commit already applied to dev.

### Determinism

- Every tool, provider and image is pinned by version and digest: OpenTofu 1.13.2, tflint 0.65.0 and its google ruleset
  0.41.0, shellcheck 0.11.0, Trivy 0.76.1 (each by SHA-256, `ci/tools.sh`); yq by module version (the Go checksum
  database); gitleaks v8.30.1, OSV-Scanner v2.7.0 and govulncheck v1.1.4 by module version and hash, built with Go 1.27.3; the
  `google` 8.9.0, `kubernetes` 3.4.0 (the dev stack), `gitlab` 19.5.0 and `anthropic` 1.92.0 (ippontech's, the anthropic stack) providers, by hash in each lock file (`ci/lock.sh` writes them; jobs init with
  `-lockfile=readonly`), the `gitlab`, `kubernetes`, `google` and `anthropic` ones our own reproducible builds (below), by its commit and its SHA-256; the CI image by digest; the manager's Ubuntu image by name, with no package installed at boot;
  the pools' Container-Optimized OS image by name (below, The runners' image); GitLab Runner and its fleeting plugin,
  our builds, by commit and SHA-256 (below, The manager's binaries); the runners' helper and default images by digest.
- The same commit produces the same plan: nothing in the source resolves at plan time what a commit does not fix
  (`ci/policy.sh`), and the only inputs are the commit, the pins, and the cloud's state.
- Nothing is applied that isn't in a reviewed commit: `apply` applies only the plan its pipeline saved, of `CLOUD_COMMIT`,
  a commit of main. Anything changed by hand shows up in the nightly drift.

### The network rules

`decisions/network-exposure-2026-11-03.md` and `cluster-node-pools-2026-11-03.md` (tacplus-dev/roadmap), with Jody's
answers on #7 (2026-11-04), are in the stacks, and `ci/policy.sh plan` refuses every saved plan that breaks one, before it
is applied:

- **One public IP:** the dev stack's global address `gateway` (#13), whose TCP proxy load balancer is the only way in
  (below, The public entry). In a plan, any other external address (global or regional) is refused, and so is any
  external forwarding rule but a global external proxy Network Load Balancer's: global, `EXTERNAL_MANAGED`, TCP, on the
  address `gateway` (its name, its IP, or a reference to it when known only after apply), to a target TCP proxy. In the
  source, a global address without `prevent_destroy` is refused, so that no apply takes the IP with it.
- **We terminate TLS, not the cloud** (the decision's addendum, Jody, 2026-11-05; #21): a certificate (Compute's,
  Google-managed, or any Certificate Manager resource), an SSL policy, an HTTP, HTTPS or SSL proxy or a URL map, global or
  regional, is refused in a plan: no L7 load balancer, no TLS on Google's side.
- **Only load balancers are public, and every one is proxy-based.** No instance or instance template has an external
  address: an `access_config` or `ipv6_access_config`, or one known only after apply, is refused. The host organization's
  `compute.vmExternalIpAccess` (below) makes the API refuse one too. Egress is through Cloud NAT, in both projects.
- **No ingress from the internet:** a firewall rule allowing ingress from `0.0.0.0/0` or `::/0`, or from no source at all
  (which is `0.0.0.0/0`), is refused, with no exception list; so is one allowing ingress from any other public range,
  that is, outside the private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and Google's proxy and
  health-check ranges (`35.191.0.0/16`, `130.211.0.0/22`), any IPv6 range included (#21): a proxy-based load balancer
  needs only Google's. The dev stack's one such rule is the load balancer's (below, The public entry). A deny rule is not
  refused.
- **No SSH anywhere, not even IAP:** a firewall rule allowing port 22 in either direction (`tcp` or `all` with no ports,
  `22`, or a range covering it) is refused. The one exception, exactly as it is, is the runners' internal rule
  `runner-manager-to-workers-ssh` (the manager to its workers, by network tag), which goes with the runner VMs (#11).
  Break-glass on a VM is its serial console and its logs.
- **Private nodes, on Container-Optimized OS:** a cluster without `private_cluster_config.enable_private_nodes`, a node pool
  with public nodes, or one whose `image_type` is not `COS_CONTAINERD`, is refused. The control plane's endpoint stays
  public (Jody, 2026-11-04).
- **The pools:** `normal`, 3 x c4a-standard-2, on demand and fixed, runs the platform; `spot`, c4a-standard-4 spot from 0
  to 3, labelled `spot=true` and tainted `spot=true:NoSchedule`, runs build pods only: only they tolerate the taint
  (tacplus-dev/cluster#6). The dev stack's output `cluster` gives the label and the taint.

A drift plan sees only what a stack has in its state, so a rule, a VM or a node pool made by hand is in none. The nightly
**live audit** (`ci/audit.sh`, in the drift job) lists every firewall rule, instance, instance template, address, cluster and node
pool in `tacplus-ci` and `tacplus-dev` and runs the same checks on them; each finding is a `live <project>: ...` line of
the drift issue. GKE's own internal rules (`gke-*` from the network's private ranges, which open every port, 22 among
them, between nodes, pods and the control plane) are not reported for port 22; the address `gateway` is not reported. It
lists no forwarding rule, proxy or certificate yet (PROPOSALS.md). Folder firewall policies, which would
enforce these rules rather than report them, come later (#7).

### Known vulnerabilities

`govulncheck -mode=binary` of every pinned binary is clean, or each finding left is accepted in
`security-exceptions.yaml` (the form looper-scan reads, tacplus-dev/looper#49) with its reason and an expiry, and its pin
moves to the first upstream release with the fix (#3):

- **The `gitlab` provider is built from source** (`ci/gitlab-provider.sh`), because upstream's 19.5.0 is built with
  go1.26.5 and x/net v0.58.0, without Go's crypto/x509, crypto/tls and net/http fixes, and it holds the GitLab token. Its
  tag v19.5.0 at the pinned commit, with go1.27.4 (#39) and x/net v0.62.0, every module checked against the Go checksum
  database, built as upstream builds it and reproducibly: each build is refused unless its SHA-256 is the pinned one.
  `ci/tools.sh` puts this platform's build in `bin/providers`; OpenTofu installs `gitlabhq/gitlab` from there and never
  from the registry (`ci/tofurc.sh`, which every script running tofu sources), and the lock file holds only this build's
  hashes, for the four platforms (`ci/lock.sh` builds them all). It goes when an upstream release is built on a fixed Go.
- **The `kubernetes` provider is built from source too** (`ci/kubernetes-provider.sh`, #18), the same way: upstream's
  3.4.0 is built with go1.26.3, and it holds the pipeline's token to dev's cluster. Its tag v3.4.0 at the pinned commit,
  with go1.27.4, x/net v0.62.0 and kin-openapi v0.152.0, installed and locked as the `gitlab` one is. Upstream's
  kin-openapi v0.111.0 has GO-2025-3533, GO-2026-6095, GO-2026-6112 and GO-2026-6274 (#18) and GO-2026-6783, 6785,
  6789, 6795 and 6804 (#23), the last fixed in v0.149.0, and its fixed releases change the API the provider compiles
  against: `ci/kubernetes-provider.patch` ports the provider's `manifest/openapi` to it (Jody's decision on #23, no
  exception), and that package's tests, with one the patch adds, run before each build. The patch goes when an
  upstream release compiles against kin-openapi v0.149.0 or later; the build, when one is also built on a fixed Go.
- **The `google` provider is built from source too** (`ci/google-provider.sh`, #39), the same way: upstream's 8.9.0, and
  its latest release, are built with go1.26.10, without net/http's GO-2026-6859 fix (go1.26.11, go1.27.4), and it holds
  the pipeline's Google credentials. Its tag v8.9.0 at the pinned commit, with go1.27.4 and x/net v0.62.0, installed and
  locked as the `gitlab` one is.
- **OpenTofu, tflint, its google ruleset and Trivy are built from source with go1.27.4** (#39): upstream's releases are
  built with go1.27.3 or go1.26.10, without GO-2026-6859's fix. `ci/tools.sh` builds each from its release's module
  (pinned by its `h1:` hash, checked against the Go checksum database) as upstream builds it (CGO off, `-trimpath`, its
  ldflags), with no VCS stamp, so reproducibly: each build is refused unless its SHA-256 is the pinned one. yq, gitleaks,
  OSV-Scanner and govulncheck are built with the same Go. Each goes back to upstream's release when one is built on a
  fixed Go (PROPOSALS.md).
- **Accepted until 2026-12-03:** OpenTofu 1.13.2, the `google` provider 8.9.0, tflint 0.65.0 and its ruleset 0.41.0:
  x/net HTTP/2 and html, x/crypto/openpgp, x/mod's sumdb and a gRPC
  server panic. They run on trusted, pinned inputs (lock-file hashes, this repository, Google APIs and gitlab.com over
  TLS), and none of them has a fixed release yet.

- **Accepted until 2026-12-04** (#10): gitleaks v8.30.1's xz (GO-2025-3922), with no gitleaks release past it yet.
- **gitleaks and OSV-Scanner are built with the fixed klauspost/compress and brotli** (#24): `ci/tools.sh` builds each
  from its pinned module in a copy of its source that requires klauspost/compress v1.20.2 (GO-2026-6865, a panic on
  two-block frames) and, for gitleaks, brotli v1.2.7 (GO-2026-6888, excessive allocation decompressing crafted
  streams), checked against the Go checksum database, until their releases require them. **Accepted until
  2026-12-06** (Jody's decision on #24): GO-2026-6865 in the downloaded OpenTofu 1.13.2 and Trivy 0.76.1, which decode only
  pinned, trusted inputs; each pin moves when its upstream ships the fix.
- **GitLab Runner and its fleeting plugin are built here** (#40; below, The manager's binaries): go1.27.4, x/net v0.62.0,
  klauspost/compress v1.20.2 and go-jose v4.1.6 (#44), so neither has an entry; the jobs' helper image, upstream's, is not scanned here.
- **The CI image is build:2.6.10 by digest** (#43): its `gh` has x/net >= v0.62.0 (CVE-2026-78661, #27) and its
  zlib the fix (CVE-2026-85091), so their exceptions are gone, and it has no OpenEXR (tacplus-dev/tacplus#554: 16 CVEs
  in Debian 13's, from buildpack-deps' imagemagick). Its `gh`'s x/crypto/openpgp is GO-2026-5932's, above.

The `security` job enforces it (below), on every pipeline.

### Security checks

tacplus-dev/looper#49's floor, in this pipeline (#10): tacplus-dev/build's checks, which run it elsewhere, never reach
this one, which applies with the strongest credentials we have. `ci/security.sh`, the `security` job, on every push, merge
request and nightly schedule:

- **OSV-Scanner** on the tree's dependency manifests and lock files (the commit's tree; today it reads none of them:
  the providers' lock files are OpenTofu's, and their binaries are scanned below);
- **`govulncheck -mode=binary`** on every pinned binary the pipeline runs or installs, symbols present: OpenTofu, tflint
  and its google ruleset, yq, gitleaks, OSV-Scanner, Trivy and govulncheck, the `gitlab`, `kubernetes` and `google`
  providers (`bin/`), and GitLab Runner and its fleeting plugin (our builds, the very bytes the manager installs, from
  `bin/manager/`) (`bin/scan/`, `ci/tools.sh security`). shellcheck is not Go;
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

1. A pull request here; the tests run as its gates (the looper's land, or `ci/tools.sh && ci/lint.sh all && ci/checks.sh`,
   `gates.yaml`'s `full`). They run in the image `build.lock` pins by digest, the CI image, with no Docker: tacplus-dev/build
   builds a commit only from that pin (looper#71). To move it, change `build.lock` and the CI file's `default.image`
   together (`tests/ci_test.sh` refuses them apart): a new digest is a change like any other, landed on the full gates.
2. Merged, a merge request in the GitLab project setting `.gitlab-ci.yml` to `ci/pin.sh <commit>`'s output, for that commit
   of main: the checks run on it.
3. Merged there, the pipeline on main: checks → `plan:folder` → `apply:folder` → `plan:dev` → `apply:dev` → `plan:ci` →
   `apply:ci` → `plan:gitlab` → `apply:gitlab` (ci after dev: the ci stack reads the dev project's number, #30). Each plan is in its job's log and its artifact; each apply applies that plan. Nothing
   waits for Jody (not production).

To review a plan: the `plan:<stack>` job's log, or its artifact `src/plans/<stack>.txt`.

## Bootstrap

`bootstrap/bootstrap.sh` is the one manual step. Jody runs it once, with his own account, in the parent folder the host
organization handed over (`--folder`, its numeric ID). It:

1. creates the folder `bootstrap` under the parent folder, the project `tacplus-bootstrap` in it (billing linked, the APIs
   the pipeline calls: its own, and those of the stacks' APIs that count against the caller's project, the pipeline's
   own, rather than the project they change, Cloud KMS for one; `tests/apis_test.sh` audits every API the stacks call)
   and the state bucket `gs://tacplus-bootstrap-tofu-state` (us-central1, versioned, uniform access,
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
  - `compute.vmExternalIpAccess`, denied to all, with no exception for nodes or VMs: only load balancers are public
    (above, The network rules);
  - `iam.allowedPolicyMemberDomains`: the host's own directories (the readers below are of one of them).
- **Who signs in as a person:** the accounts, the readers' and the break-glass account (below, Break-glass), are the
  host's directory's.

<!-- hosting note -->
Today the host is seabeam.net's organization: the parent folder is its folder `tacplus-dev`, and its admin is the closed
pipeline seabeam/cloud (GitLab), `tacplus-dev/roadmap:decisions/cloud-org-seabeam-2026-11-03.md`. Nothing here depends on
it: another host is another folder ID. The runners' token adders (`GCP_RUNNER_TOKEN_ADDERS`, below, The cluster
pipeline) are `user:jody@seabeam.net` today (#18), and so are the apps' key importers (`GCP_KMS_KEY_IMPORTERS`, below,
The GitHub Apps' keys), for the one run that imports them (#19), and the Google sign-in client's adders
(`GCP_GOOGLE_SIGNIN_ADDERS`, below, The Google sign-in client, #37).
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

Run it again whenever its APIs change (#16 added Cloud KMS and Artifact Registry): it enables only those missing.

Then the hub's steps below, then the first pipeline. The first real apply is that pipeline's, after Jody's bootstrap.

### Before the first pipeline (the hub)

1. **The GitLab project** `tacplus-dev/cloud`: `main` protected (Maintainers push and merge, no force push); group and
   shared runners off; pipeline variables allowed to the Owner role only.
2. **The runner:** a project runner registered to `tacplus-dev/cloud` only, tag `cloud`, VMs used once, with no Google
   account (as tacplus-dev/cluster's, on `gitlab-runner-mgr`, until runners move).
3. **Its variables** `GCP_PARENT_FOLDER` and `GCP_WIF_PROVIDER` (protected), the values the bootstrap printed, and
   `GCP_RUNNER_TOKEN_ADDERS` (protected): the account that adds the runners' token versions (below, The cluster pipeline);
   `GCP_KMS_KEY_IMPORTERS` (protected), only while the apps' keys are imported (below, The GitHub Apps' keys);
   `GCP_GOOGLE_SIGNIN_ADDERS` (protected): the account that adds the Google sign-in client's secret versions, in the
   Console (below, The Google sign-in client). The gitlab stack adopts it and `main`'s
   protection (its import blocks), and sets the reader's two variables from Secret Manager.
4. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cloud` with Issues read and write. This
   project's jobs sign with the KMS key `tacplus-reader` in `tacplus-ci` (the ci stack's binding, #30) once its version
   is imported (below, The GitHub Apps' keys): until then the drift job files no issue.
5. **`.gitlab-ci.yml`** from `ci/pin.sh <commit of main>`, and a nightly schedule on main.

The first pipeline on main then creates the folders, the `ci` and `dev` projects, and the GitLab
settings, each from its saved plan. tacplus.dev's zone in `tacplus-dev` writes the delegations of the dev zone and the
challenge zones itself; until the registrar names it, the zone in jody1-328023 still answers, and the hub gives it the
same records (below, The tacplus.dev cutover).

## Break-glass

When the pipeline itself is broken (its identity refused, its state locked, a bad apply it cannot undo), and only then:

1. Jody signs in with his own account (the account the bootstrap ran as, given its grants again by the host, or the host's
   break-glass account); nobody else holds write access. Every action is in the Admin Activity audit logs.
2. An issue here says what is broken, why break-glass, and what was done, command by command.
3. The fix is made as narrow as it can be: a stuck state lock is released with
   `tofu force-unlock <id>` in the stack (from a checkout at main, `ci/tools.sh`, `tofu init -lockfile=readonly`); an
   identity is restored with `bootstrap/bootstrap.sh` (it creates only what is missing); anything else with `gcloud`.
   Never over SSH, which no rule admits: a VM is read through its serial console and its logs.
4. Then it is made deterministic: the change is captured as a commit here and applied by the pipeline, or reverted. The
   next drift check must show no difference.

## Rotating the GitLab token

Add the new token as the next version of `gitlab-token` (`gcloud secrets versions add ...`), change the version in
`modules/settings` (`gitlab_token_secret`) in a commit, and let the pipeline run; then disable the old version.

## Memberships

The gitlab stack's `members` (`stacks/gitlab/main.tf`), by `PROJECT:USER`: memberships of projects whose other settings
this repository does not manage, Guest or Reporter only (the module refuses anything higher), each with `expires_at`, a
date in the commit (never computed: the plan is the commit's alone). Today one (#12, Jody's option B):

- `tacplus-dev/build:tacplus-looper-bot`, **Reporter (20)**, until 2027-10-01: the looper's nightly recap reads
  tacplus-dev/build's pipelines as `tacplus-looper-bot`, with the `GITLAB_TOKEN` (its personal access token
  `looper-jobs`, `read_api`) every looper job holds. gitlab.com's Free tier has no project access tokens, and GitLab adds
  no project bot to another project, so the bot is an ordinary member. tacplus-dev/build's code is public and its jobs
  and artifacts hold no secret (its credentials come through WIF), so every looper job reading it adds little; if its
  artifacts ever carry anything sensitive, this becomes a bot account of the recap's own, its token in Secret Manager.
  Its expiry is the token's: renew both together.

**Renewing one:** the drift job's expiry check (`ci/expiry.sh`) reports every `expires_at` of the stacks that is past or
within 30 days, in the drift issue. A commit of a later date renews it; the pipeline applies it.

## The build pipeline

#26 (tacplus-dev/looper#71, #84; tacplus-dev/roadmap
`suggestions/2026-11-06-pin-every-repository-so-the-build-pipeline-and-its-security-checks-run-anywhere.md`, step 2):
the looper's reports and managers get their gates from build jobs in tacplus-dev/build, which this pipeline sets up
(`modules/gitlab/build.tf`, from the gitlab stack's `build`):

- **Its runners** (#35): group runners on, gitlab.com's shared runners off (`gitlab_project.build`, the project adopted
  by its ID, never destroyed, nothing else of it managed). Its jobs are tagged `build`, which only tacplus-dev's group
  runners (the pools) take: with group runners off, every build job waits about 1.5 h and fails
  `stuck_pending_no_matching_runners`. Any project that takes `build`-tagged jobs needs group runners on.
- **Its `.gitlab-ci.yml`** is tacplus-dev/looper's `ci/build.gitlab-ci.yml` at the commit the stack names
  (`build_ci_commit`), copied as is into `stacks/gitlab/files/build.gitlab-ci.yml` and written to tacplus-dev/build's
  main by `apply:gitlab` (the hub's hand copy is adopted, then this stack's). Before every plan, `plan:gitlab` runs
  `ci/build-ci.sh check` (the copy is looper's file at that commit, from GitHub) and `ci/build-ci.sh lint` (GitLab's
  own lint of it in tacplus-dev/build, `POST /projects/:id/ci/lint`): a copy that differs or that GitLab cannot read
  is never applied. **A bump** is `ci/build-ci.sh update <looper commit>` (the copy and `build_ci_commit`) in a commit.
- **`BUILD_TRIGGER_TOKEN`**: a pipeline trigger of tacplus-dev/build, its token the protected, masked variable
  `BUILD_TRIGGER_TOKEN` of tacplus-dev/looper (project 88136765), which its report and manager jobs start build jobs
  with (tacplus-dev/looper README, Build jobs). Nobody sees it: GitLab makes it, the apply writes it
  (`decisions/secrets-by-pipeline-2026-11-05.md`). The trigger is owned by the user of the token this pipeline runs as
  (`gitlab-token`), and a triggered pipeline runs as its owner.
- **Its rotation**, every 90 days: the trigger's `rotate_by` in `stacks/gitlab/main.tf` is a date in the commit, never
  computed (the plan is the commit's alone). The drift job's expiry check (`ci/expiry.sh`) reports it from 30 days
  before; a commit of a date 90 days later replaces the trigger: the new one is made and becomes the variable's
  before the old one is deleted, so a build started in between fails at most once.
- **The nightly schedules**: one per repository of `stacks/gitlab/nightly-builds.yaml`, on tacplus-dev/build's main,
  its cron in UTC and its inputs (`repo`, `nightly: true`: the build scans the repository's main as it is then).
  tacplus-dev/looper first. **A repository's pin issue adds it there** once its `tacplus.lock` or `build.lock` is on its
  main (a nightly of a repository with no pin fails).

**Not yet:** nothing is applied before the first pipeline; the builds need the build runner (tags `arm64`, `build`),
which the hub registers for tacplus-dev/looper#84.

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
| `shared` | tacplus-dev group runner, not protected; tags `arm64`, `autoscale`, `autoscale-16` (loopers and control jobs) | **three, always on** (`idle_count = 3`, `max_instances = 3`): t2a-standard-8, 350 GB pd-standard | no slots (Jody, 2026-11-10): up to 25 jobs a VM, each may use all 8 CPUs and 28g, no swap, 12 GB of disk |
| `build` | tacplus-dev group runner, not protected; tags `arm64`, `build` (tacplus-dev/build's jobs) | **spot, from zero** (`idle_count = 0`, `max_instances = 2`): t2a-standard-8, 450 GB pd-standard, in whichever of us-central1-a, -b and -f has the capacity (#49) | 4 builds a VM (8 at once), each may use 4 CPUs and 14g |
| `deploy` | tacplus-dev/fleet-seatrials, protected; tag `deploy` | on demand (at most 1, kept 30 minutes idle): t2a-standard-4, 80 GB | 2: 2 CPUs, 6g, 25 GB |
| `cluster` | tacplus-dev/cluster, also tacplus-dev/cloud's own pipeline, protected; tags `cluster`, `cloud` | on demand (at most 1, kept 30 minutes idle): t2a-standard-4, 70 GB | 2: 2 CPUs, 7g, 20 GB |

- **The shared VMs** are the three always-on nodes for now (Jody, 2026-11-10): every looper and control job runs on
  them, with no slots; builds run on the spot `build` pool, a few at a time. "If it's a looper and it wants to run, it runs, period": a job is not a reservation of
  CPUs or memory, and the jobs share a VM like processes on a laptop (25 a VM is a ceiling, not a slot count). They
  replace the jody1-328023 pools (whose settings change only over SSH); tacplus-dev/looper#84 moves the same
  arrangement into the cluster. One VM is one runner registration
  (GitLab does not share an instance group between `[[runners]]` entries), so these jobs share one set of container
  settings: the build jobs' (`jobs.build` in `modules/settings`, today the same as the agents'). If builds need
  settings agents must not get (rootless BuildKit, tacplus-dev/tacplus#315), the split is a `build` pool of its own.
- **A zone out of capacity (#49).** On 2026-11-12 spot t2a ran out in us-central1-b: the build pool's VM stayed
  `CREATING` (`ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS`) for hours, and every build waited on it. The build pool is
  therefore spread over the region's three zones with t2a (`zones` in `runner_pools`): its group is a regional one,
  `runner-build-region` (not `runner-build`: a regional group makes a zonal group of its name in each zone, which
  collided with the old zonal one, 409, on the first apply),
  target shape `ANY`, which makes each new VM in a zone that has the capacity and never moves one to even the zones out
  (redistribution off), and the plugin is pointed at the region. Spread, not an on-demand fallback: on-demand t2a in
  us-central1-b was out too that day (the shared pool came back about 18:05Z), and a second, on-demand runner on the
  same tags would take half the builds even while spot has room, and, from zero, take jobs it has no VM for. The other
  pools stay in us-central1-b, the manager's zone. A VM already stuck creating is not moved by its group, which
  retries it in its zone forever, and the autoscaler counts it as coming: the manager's **reaper** (`runner-reap`,
  which the startup script installs beside the watcher) lists every pool's group each minute (`runner-groups` in its
  metadata) and deletes a VM that has been creating on a capacity or quota error for five minutes; the autoscaler then
  asks for another, which a spread pool makes where there is room (a zonal pool, in its zone again, five minutes
  later). It deletes nothing else.
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

### The manager's binaries

#40 (Jody's rule on #39: nothing the VMs run comes from upstream at boot). GitLab Runner and its googlecloud fleeting
plugin are **our builds** of upstream's tags (v19.5.3, v1.3.1), not upstream's releases, which are built with go1.26.10
(GO-2026-6859):

- **The build.** `ci/runner.sh`, in the tools job (`bin/manager/`): each tag at its pinned commit, with go1.27.4,
  x/net v0.62.0, klauspost/compress v1.20.2 and go-jose v4.1.6 (every module checked against the Go checksum database;
  `tests/security_test.sh` checks the builds' modules), as upstream
  builds it (`CGO_ENABLED=0`, its ldflags) with `-trimpath`, no VCS stamp and the commit's date as the build's, for
  linux/arm64; the runner with Go's own crypto, not the frozen FIPS 140 module v1.0.0 its release has (which go1.27
  would also turn on). It is reproducible: a build whose SHA-256 is not the one
  `stacks/ci/main.tf`'s `runner` block pins is refused. A bump changes the version, branch, commit and SHA-256 there
  (the build's SHA-256 is what `ci/runner.sh` prints when it refuses a build). **One release with tacplus-dev/cluster**
  (cluster#21, #44): its runner and helper images are built from the same commit with the same Go and modules, so a
  bump here names the cluster issue that moves its pins, and the other way round.
- **The bucket.** `tacplus-ci-runner-bin` (`modules/projects/ci/runner-bin.tf`): uniform access, public access
  prevention enforced, and `roles/storage.objectViewer` bound authoritatively to the manager's account alone, so no
  VM's or job's account but the manager's reads it (the pipeline, which uploads the builds, and break-glass reach it
  through their project roles). The ci stack uploads `bin/manager/` there, each object named by its SHA-256
  (`gitlab-runner/<sha256>`): a new build is a new object, created before the old one is deleted, and refused unless
  it is the pinned build.
- **The manager** (`files/manager-startup.sh`) fetches both from the bucket with the VM's token (the subnet has Private
  Google Access), by the SHA-256s in its metadata, refusing any object that is not that build, and installs them with
  no package and no apt: `/usr/bin/gitlab-runner`, `/usr/local/bin/fleeting-plugin-googlecloud`, and the service as
  upstream's package's post-install sets it up (the `gitlab-runner` user, `gitlab-runner install`). At boot it asks
  only the metadata server, the bucket and Secret Manager.
- **Never without a manager (#46).** Every runner of the fleet is the manager's, `apply:ci`'s own among them. A **new
  config** (a pool raised, a tag moved: `runner-config`, `runner-pools`, `runner-groups`) is an in-place metadata update of the running
  manager: its watcher (`runner-config-watch`, which the startup script installs) sees the metadata change and runs
  the startup script again, which rewrites `config.toml`; gitlab-runner reloads it by itself, with no restart and no
  job lost. A **new build** (GitLab Runner or the plugin, the startup script, the image, the machine type, the disk or
  the zone) replaces the manager `create_before_destroy`, after its objects are in the bucket: its name is the build's
  hash (`runner-manager-<8 hex>`), so the new one is up before the old one goes.
- **No job lost to a new manager (#48).** A new manager's gitlab-runner removes every pool VM it did not create, jobs
  and all (`no data on pre-existing instance so removing for safety`: it cannot resume another manager's jobs), and
  deleting the old manager kills its jobs anyway; on 2026-11-12 the two together killed every looper job. So the old
  one drains first, and the new one starts on empty groups (rather than the new one taking the old one's instance
  state: with it the VMs would live on, but not their jobs, which only the old process can finish). `apply:ci` never
  deletes a manager (`destroy = false`): it forgets the old one, deposed ones too, and creates the new one. Before its
  gitlab-runner starts, the new one's startup script tells each older manager to retire (its metadata
  `runner-successor`, and the new startup script, which the old one's watcher runs: a manager older than #48 learns
  how), and waits until none is left. A manager told to retire runs `runner-retire`: gitlab-runner stops on SIGQUIT,
  taking no new job and finishing its running ones however long they take (`apply:ci`'s own among them, which runs
  through the old manager: that job now ends well), then the VM deletes itself. The SIGQUIT is gitlab-runner's alone
  (`KillMode=mixed`): its fleeting plugin, which those jobs reach their VMs through, goes only after it (the #49
  apply died with `Plugin did not respond` when its manager went). Then the new one resizes each pool's group
  (`runner-groups`, zonal or regional) to zero and waits until it has no instance, a creation stuck on an error of
  the old fleet's time too (#29: `QUOTA_EXCEEDED`, retried by the group only about every 90 minutes), and starts
  gitlab-runner: the shared pool's idle VMs are created at once, the quota freed (the old fleet's VMs gone first, both
  managers within it). The cost: while the old one drains, no new job starts anywhere; the queue waits for the longest
  running job. `ci/policy.sh` refuses any plan
  that would destroy a manager (first, or at all) and a source without `create_before_destroy` and `destroy = false`;
  `tests/manager_startup_test.sh` pins the handoff and the retirement against a stub Compute API, and the plan tests
  pin the names (a config change keeps it, a new build changes it). Each apply's OpenTofu log (its core at DEBUG, the
  providers at INFO) is in the apply job's artifacts, `plans/<stack>.apply.log`.
- **If an old manager does not retire** (its watcher not running, a job that never ends), the new one waits, and
  says so in its serial log (`waiting for the older managers to finish their jobs and go`): the old one still runs
  its jobs. Delete the old one by hand (`gcloud compute instances delete runner-manager-<old> --zone us-central1-b
  --project tacplus-ci`), which kills its remaining jobs; the new one then goes on by itself.
- **The helper image** each job runs beside (git, artifacts, caches) is upstream's for v19.5.3, pinned by digest in
  `runner.helper_image`; the pools' VMs pull it from registry.gitlab.com when a job starts, as they pull the default
  image, and the manager installs no helper-images package. It is still built with go1.26.10: building it here, into a
  registry only the workers read, is a follow-up (PROPOSALS.md); `runner.helper_image` moves to the helper
  tacplus-dev/cluster builds (cluster#21) once it is published.
- **If a new manager does not come up**, no runner is left to run the pipeline that would revert it (`apply:ci` runs on
  the `cluster` pool, through this manager): revert the commit and apply the ci stack from a workstation (Break-glass).
  #40 landed in two steps for this reason: the builds and the bucket first, the switch second, so the revert of the
  switch returns to pins already applied.

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

## The cluster pipeline

`cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com` is tacplus-dev/cluster's pipeline identity, keyless,
through Workload Identity Federation (pool `gitlab-com`, provider `tacplus-dev-cluster`), condition: tacplus-dev/cluster's
protected `main`. The dev stack gives it, and nobody makes any of it by hand (#18; tacplus-dev/cluster's README, What
the hub does, steps 4 and 7, are this pipeline's):

- **In GCP:** `roles/container.clusterViewer` on `tacplus-dev`, to get the cluster's credentials. No service account
  holds `roles/container.admin` or `roles/owner` (`ci/policy.sh` refuses either in any plan, the pipeline's own owner of
  its folders alone excepted): either could delete the cluster.
- **In the cluster:** the ClusterRoleBinding `cluster-admin-pipeline` of the ClusterRole `cluster-admin` to the User
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`, made through the kubernetes provider as this pipeline
  (its owner of the folder `dev` covers GKE's RBAC), against the cluster's public endpoint. The provider's token is
  ephemeral (`ephemeral "google_client_config"`): the plan and the apply each open their own, and none is in the saved
  plan or the state. On a plan before the cluster exists, or of its replacement, the provider's endpoint is known only
  after apply, and the binding is made once the cluster is; a cluster rebuilt by hand loses it, and the drift plan
  shows it to be made again. The drift job's plan of `dev` reads it from the cluster.
- **The runners' token secrets:** `gitlab-runner-build` and `gitlab-runner-control`, us-central1, created empty. Only
  `cluster-admin-pipeline` reads them (`secretAccessor`); only the dev stack's `runner_token_adders` add versions
  (`secretVersionAdder`, which reads none): authoritative bindings, so a grant added by hand is drift. The adders are
  the protected GitLab variable `GCP_RUNNER_TOKEN_ADDERS`, members comma-separated (`user:`, `group:`,
  `serviceAccount:` and an email), which `ci/lib.sh` gives the stack and refuses unless each is a member; unset or
  empty, nobody adds versions. Their accounts are the host's directory's, which no file here names (Jody's today: the
  hosting note, above). The hub registers each runner through GitLab's API and pipes its token into a new version as
  that account (`gcloud secrets versions add gitlab-runner-build --project=tacplus-dev --data-file=-`); a new token is
  a new version, and a pull request in tacplus-dev/cluster naming it. The dev stack's output `runner_tokens` names both
  secrets.

## The GitHub Apps' keys

#19; tacplus-dev/looper#83 and its README, Only the manager writes main. The private keys of tacplus-dev's GitHub Apps
are Cloud KMS signing keys in `tacplus-ci`, the key ring `looper` (us-central1): a job has KMS sign its app's JWT
through Workload Identity Federation, and never holds the key. The apps, their IDs (none secret) and who signs with
each are `modules/settings` (`github_apps`); the ci module's `github-apps.tf` makes them.

| Key | App ID | Installation ID | Signs for |
|---|---|---|---|
| `tacplus-manager` | 5632100 | 179024536 | tacplus-dev/looper's main, environments `looper-manager` and `looper-scan` (never `looper-report`: the module refuses it) |
| `tacplus-looper` | 5632122 | 179024135 | tacplus-dev/looper's main, environments `looper-report`, `looper-scan`, `looper-plan` and `kicker` |
| `tacplus-reader` | 5531358 | 176655068 | every protected ref of the namespace tacplus-dev (kernel's prepare, once it exchanges its id_token through `gitlab-com` here); tacplus-dev/cloud's jobs (its drift issue), through tacplus-bootstrap's pool, and tacplus-dev/cluster's (its drift issue), through the dev project's; tacplus-dev/fleet-seatrials' jobs as the account `fleet-seatrials-reader` (#30) |

- **The keys:** asymmetric signing, `RSA_SIGN_PKCS1_2048_SHA256`, software, **import-only**, created with no version
  (`prevent_destroy`). Cloud KMS never exports a key's material, so a key leaving jody1-328023 is a new one (#30).
  Each key has an import job, `<key>-import` (`RSA_OAEP_3072_SHA256_AES_256`). An import job expires three days after
  it is made, and is never deleted: a key not imported by then needs a new one, a commit that renames it.
- **Who imports:** the members of the protected GitLab variable `GCP_KMS_KEY_IMPORTERS` (comma-separated, as
  `GCP_RUNNER_TOKEN_ADDERS`; `ci/lib.sh` gives them to the ci stack as `kms_key_importers` and refuses one that is not a
  member), alone: `roles/cloudkms.importer` on the import jobs (a binding on the key ring, conditioned on the import
  jobs' names: the google provider has no import job IAM), and the custom role `kmsKeyVersionImporter`
  (`cloudkms.cryptoKeyVersions.create`, nothing else) on each key with an import job. Unset or empty: no importer
  binding at all. Authoritative bindings: a grant added by hand is drift.
- **Who signs:** each key's own `roles/cloudkms.signer` binding, never the key ring's, authoritative. The pool
  `gitlab-loopers` in `tacplus-ci` is the apps' own, with two providers for gitlab.com, each mapping only its own
  attribute:
  - `gitlab-looper`: tacplus-dev/looper (GitLab project 88136765) alone, its protected refs alone; `attribute.role` is
    `project_id:ref:ref_protected:environment`, GitLab's word for each. A key's member for an environment is
    `principalSet://iam.googleapis.com/projects/<tacplus-ci's number>/locations/global/workloadIdentityPools/gitlab-loopers/attribute.role/88136765:main:true:<environment>`.
  - `gitlab-com`: tacplus-dev's protected refs (namespace 145863835, by ID: a renamed or re-created path does not take
    it over); `attribute.namespace_id`, the reader's member.

  A key's `projects` sign through their own pools, `gitlab-com` in `tacplus-bootstrap` or in `tacplus-dev`
  (`attribute.project_path`): the reader's, tacplus-dev/cloud's jobs, through this pipeline's own provider (its drift
  job's `TACPLUS_READER_KMS_KEY`), and tacplus-dev/cluster's, through the dev project's provider `tacplus-dev-cluster`
  (its `GCP_WIF_PROVIDER`; `github_app_token`'s direct call). A key's `accounts` are service accounts in `tacplus-ci`, each holding nothing but its
  key's `roles/cloudkms.signer`, which only its GitLab project's jobs become (`roles/iam.workloadIdentityUser`,
  authoritative): `fleet-seatrials-reader`, for tacplus-dev/fleet-seatrials, whose jobs federate through the dev
  project's provider `tacplus-dev-fleet-seatrials` (their one `GCP_WIF_PROVIDER`) and sign as it (their
  `.github-reader`'s `TACPLUS_READER_SA`). The ci stack reads the dev project's number, so `plan:ci` comes after
  `apply:dev`.
- **Outputs:** the ci stack's `looper_variables` are the looper project's variables (`GCP_WIF_PROVIDER`, the provider
  `gitlab-looper`; `LOOPER_KMS_KEYRING`; the apps' and installations' IDs), `app_keys` each key, `app_import_jobs`
  each import job and `app_accounts` each account's email.

**The import** (Jody, once `apply:ci` has made the keys, `GCP_KMS_KEY_IMPORTERS` set to his account before that
pipeline): on github.com, each app's page, Generate a private key, then at once:

```sh
for k in tacplus-manager tacplus-looper tacplus-reader; do
  openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER -in $k.private-key.pem -out $k.der
  gcloud kms keys versions import --import-job=$k-import --keyring=looper --location=us-central1 --project=tacplus-ci \
    --key=$k --algorithm=rsa-sign-pkcs1-2048-sha256 --target-key-file=$k.der   # version 1
  shred -u $k.private-key.pem $k.der
done
```

Then `GCP_KMS_KEY_IMPORTERS` is cleared (the hub deletes it), and the next commit's pipeline removes the importers'
bindings.

**The reader's key, off jody1-328023** (#30; Jody, 2026-11-08). Jody's one step, which GitHub has no API for: once
`apply:ci` has made `tacplus-reader-import` (with `GCP_KMS_KEY_IMPORTERS` set before that pipeline, and within the
three days the job lives), on the tacplus-reader app's page (app 5531358, Settings, Private keys), Generate a private
key, and import it at once:

```sh
k=tacplus-reader
openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER -in $k.private-key.pem -out $k.der
gcloud kms keys versions import --import-job=$k-import --keyring=looper --location=us-central1 --project=tacplus-ci \
  --key=$k --algorithm=rsa-sign-pkcs1-2048-sha256 --target-key-file=$k.der   # version 1
shred -u $k.private-key.pem $k.der
```

GitHub keeps every key an app has until one is deleted, so the old key in jody1-328023 still signs, and its signers
still work, until it is revoked. Then, in order:

1. Each signer moves to the new key: this project's pipeline file (`ci/pin.sh` of a commit of main, its
   `TACPLUS_READER_KMS_KEY`); fleet-seatrials' `TACPLUS_READER_KMS_KEY`
   (`projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-reader`) and `TACPLUS_READER_SA`
   (`fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com`, the ci stack's `app_accounts`); tacplus-dev/cluster's
   `TACPLUS_READER_KMS_KEY`; kernel's, if it still signs, its key and provider (`gitlab-com` of `gitlab-loopers`); each
   its own issue.
2. A seatrials job mints a reader token through the new key (its log: `signing as the service account
   fleet-seatrials-reader@tacplus-ci...`, then the fetch).
3. Jody deletes the old key on the app's page (Private keys: the one made before the key just imported), and nothing
   signs with jody1-328023's key any more; `fleet-seatrials-reader@jody1-328023` and the key go with jody1-328023. The looper project's variables, its pipeline file, the ruleset and the probe are
the looper README's steps (Only the manager writes main, Setting it up, 4 to 6), with `P=tacplus-ci` and the values of
`looper_variables`.

## Certificates

`decisions/certificates-by-pipeline-2026-11-03.md`, #6: a deployment's pipeline owns its TLS certificate. Each run checks
it; when it is missing or due, the pipeline obtains one by ACME DNS-01 (`lego`, apex and wildcard) and adds it as a new
secret version, which the uni-config references. Nothing in a cluster holds it, and nobody but that pipeline writes it.

`modules/settings` (`deployments`) lists the deployments; the dev stack gives each, in `tacplus-dev`:

- **Its identity:** the service account `<account_id>@tacplus-dev.iam.gserviceaccount.com`, keyless, through Workload
  Identity Federation (pool `gitlab-com`, provider `<wif_provider>`), condition: its GitLab project's protected `main`.
  Its roles on the project are its deployment's (below, Deployments: images, the cluster and environment accounts).
- **Its secrets:** `tls-<deployment>` (the certificate chain and its key) and `acme-account-<environment>` (its ACME
  account's key; the environment is the deployment's GitLab environment), us-central1. Only its identity holds a role on
  them, `secretVersionAdder` and `secretAccessor` (authoritative bindings): it adds versions and reads them. Their values
  are never in this repository, a plan or the state.
- **Its challenge zone:** `acme-challenge-<domain with dashes>` for `_acme-challenge.<domain>.` (DNSSEC on), where
  DNS-01 for `<domain>` and `*.<domain>` writes its TXT records. Only its identity holds `dns.admin` on it (an
  authoritative zone binding), so it cannot touch `<domain>`'s own zone. The zone is delegated from `<domain>`'s zone by
  NS records.
- **An environment account's certificate** (`environment_certificates`, #32): by environment, a domain of its own, for a
  job of the deployment that serves TLS on a name its certificate does not cover. The same, in that account's name:
  `tls-<environment>` and `acme-account-<environment>`, and the zone `acme-challenge-<domain with dashes>`, delegated
  from tacplus.dev's zone when the domain is in it; only the environment account holds a role on them, the
  deployment's identity none. The module refuses two certificates on one domain and two secrets with one ID.

| Deployment | GitLab project | Secrets | Challenge zone | Identity |
|---|---|---|---|---|
| `seatrials` | tacplus-dev/fleet-seatrials (environment `seatrials`) | `tls-seatrials`, `acme-account-seatrials` | `acme-challenge-tacplus-dev`, `_acme-challenge.tacplus.dev.` | `seatrials-deploy` |
| `seatrials`, the test IdP | tacplus-dev/fleet-seatrials (environment `test-idp`) | `tls-test-idp`, `acme-account-test-idp` | `acme-challenge-idp-test-tacplus-dev`, `_acme-challenge.idp.test.tacplus.dev.` | `test-idp-deploy` |

The test IdP (fleet-seatrials#27) serves `https://idp.test.tacplus.dev:8443` with its own certificate (TLS passed
through, The public entry), which `*.tacplus.dev` does not cover: its job orders it by DNS-01 in its own zone.

The dev stack's output `deployments` names each one's `GCP_WIF_PROVIDER`, service account, secrets, and the name servers
of its zone, and its environment accounts' (`environment_certificates`, by environment: `secrets`, `challenge_zone`,
`name_servers`).

### Deployments: images, the cluster and environment accounts

#20 (fleet-seatrials#39): what a deployment's pipeline needs on `dev` besides its certificate (`modules/projects/dev/deploy.tf`),
from the same `deployments` entry:

- **The cluster's credentials:** its identity, and each of its environment accounts, holds `roles/container.clusterViewer`
  conditioned on `resource.name == "projects/tacplus-dev/locations/us-central1-a/clusters/dev"`: `get-credentials` on
  `dev` and nothing else of GKE. Its rights inside the cluster are tacplus-dev/cluster's (`deployments.yaml`).
- **Its images** (`images`), on Cloud Build, for now (Jody, 2026-11-06: once builds move to the cluster's build pool,
  tacplus-dev/looper#84, these roles and the bucket come out). Its identity holds `roles/cloudbuild.builds.editor` and
  `roles/serviceusage.serviceUsageConsumer` on the project and `roles/iam.serviceAccountUser` on the builds' own account
  `<images.account_id>`, which they run as (`gcloud builds submit --service-account`), and which holds only
  `roles/logging.logWriter` on the project. The **deploy registry** `<region>-docker.pkg.dev/tacplus-dev/<images.registry>`
  (Docker): the builds' account writes it, its identity (the `fp-` tags) and the nodes' `gke-nodes` (to pull) read it
  (authoritative bindings). It has no cleanup policy, so a deployed image is never deleted; it is not tacplus-ci's
  `build-cache`, which only tacplus-dev/build reads and which deletes by age. The **build bucket**
  `gs://tacplus-dev-<images.bucket>` (us-central1, uniform access, public access prevented, objects deleted after
  `images.days`): each submit stages its source and writes its logs there, so gcloud needs no right on the project's
  buckets (fleet-seatrials#32); its identity holds `roles/storage.admin` on it, the builds' account
  `roles/storage.objectAdmin`, nobody else a role.
- **Its environment accounts** (`environment_accounts`): by GitLab environment, a service account only its project's
  jobs in that environment, on protected `main`, may become, with the cluster's credentials and no other role. Its
  provider maps `attribute.project_environment` to the job's project and environment joined by `:` (a GitLab project
  path has no `:`; a job without an environment maps to `<project>:`), and the account's `workloadIdentityUser`
  binding names `attribute.project_environment/<project>:<environment>`: the pool `gitlab-com` is shared by
  tacplus-dev's projects, so the environment alone would admit another project's job in an environment of that name.
  An environment account is never the deployment's identity or its builds' account (the module refuses it). Besides,
  it may own a certificate (above, Certificates) and **secrets of its own** (`environment_secrets`, #32): by environment,
  secret IDs (us-central1, made with no version) whose versions only it adds and reads (`secretVersionAdder` and
  `secretAccessor`, authoritative bindings); reading `latest` tells its job whether one exists yet. They replace GitLab
  variables a job would write with a token: gitlab.com Free has no project access tokens (as #28). Their values are
  never in this repository, a plan or the state.

| Deployment | Registry | Build bucket, builds' account | Environment accounts |
|---|---|---|---|
| `seatrials` | `us-central1-docker.pkg.dev/tacplus-dev/seatrials` | `gs://tacplus-dev-seatrials-build` (7 days), `seatrials-build` | `test-idp`: `test-idp-deploy` (the test IdP, a pod in the cluster), its certificate and its secret `test-idp-seeds` (the seeds its passwords are derived from, replacing `TEST_IDP_GITLAB_TOKEN`) |

The output `deployments` names each one's `registry`, `build` (`bucket`, `sa`), `environment_accounts` (by
environment, the service account's email) and `environment_secrets` (by environment, the secrets' names).

### The fleet's CA and crypto file

#28 (Jody's option D, 2026-11-08; fleet-seatrials#44): a deployment's fleet CA and crypto file are made once by its
project's `init-secrets` job and live in Secret Manager, as its certificate does: no GitLab variable holds them, and no
GitLab token or bot user writes them (gitlab.com Free has no project access tokens; `decisions/secrets-by-pipeline-2026-11-05.md`).
From the `deployments` entry's `init_secrets` (`modules/projects/dev/fleet-secrets.tf`):

- **The secrets** `fleet-ca-<deployment>` and `fleet-crypto-<deployment>`, us-central1, made with no version: the job
  adds the first. Their values are never in this repository, a plan or the state.
- **The job's account** `<init_secrets.account_id>`: only its project's jobs in the GitLab environment
  `<init_secrets.environment>`, on protected `main`, may become it (its provider's condition, and the
  `workloadIdentityUser` binding on `attribute.project_environment/<project>:<environment>`, as an environment
  account's). It holds `secretVersionAdder` (adds a version, reads none) and `viewer` (whether a version exists, so that
  a second run skips; never a value) on the two secrets, and no role on the project. The module refuses it as any other
  of the deployment's accounts, and its environment as any other of the deployment's environments.
- **The reader:** the deployment's identity alone holds `secretAccessor` on them. All three bindings are authoritative:
  a grant added by hand is drift.

Where each of a deployment's secrets lives, and who writes and reads it:

| Secret (tacplus-dev, us-central1) | What | Adds versions | Reads |
|---|---|---|---|
| `tls-seatrials` | the certificate chain and its key | `seatrials-deploy` | `seatrials-deploy` |
| `acme-account-seatrials` | its ACME account's key | `seatrials-deploy` | `seatrials-deploy` |
| `fleet-ca-seatrials` | the fleet's CA | `seatrials-init-secrets` (fleet-seatrials' jobs in `init-secrets`) | `seatrials-deploy` |
| `fleet-crypto-seatrials` | the fleet's crypto file | `seatrials-init-secrets` (fleet-seatrials' jobs in `init-secrets`) | `seatrials-deploy` |
| `google-signin-seatrials` | its Google sign-in (OAuth web) client: the client JSON the Console downloads | Jody, by hand in the Console (`GCP_GOOGLE_SIGNIN_ADDERS`): once when the client is made, the bootstrap step, and at each rotation; Google offers no API that makes a web client or its secret | `seatrials-deploy` (fleet-seatrials' `apply` and `signin-secrets` jobs) |

The output `deployments` names each one's `fleet_secrets` (`ca`, `crypto`, the job's `environment` and its `sa`, the
`GCP_SERVICE_ACCOUNT` its job impersonates through the deployment's `GCP_WIF_PROVIDER`).

### The Google sign-in client

#37 (Jody, 2026-11-09; fleet-seatrials#46): a deployment's Google sign-in (OAuth web) client is in `tacplus-dev`, and its
secret in Secret Manager, which its deploy jobs read through WIF; never a GitLab variable. Google has no public API that
makes a web client or its secret (IAP's OAuth Admin API was shut down on 2026-03-19), so a person adds its versions: no
pipeline identity does. From the `deployments` entry's `google_signin` (`modules/projects/dev/google-signin.tf`):

- **The secret** `google-signin-<deployment>`, us-central1, made with no version. Its value is never in this repository,
  a plan or the state.
- **Who adds versions:** the members of the protected GitLab variable `GCP_GOOGLE_SIGNIN_ADDERS` (comma-separated, as
  `GCP_RUNNER_TOKEN_ADDERS`; `ci/lib.sh` gives them to the dev stack as `google_signin_adders` and refuses one that is
  not a member), Jody's account today (the hosting note, above): `secretVersionAdder` on the secret alone, which adds
  versions and reads none. Unset or empty, nobody adds them.
- **The reader:** the deployment's identity alone holds `secretAccessor` (fleet-seatrials' `apply` and `signin-secrets`
  jobs). Both bindings are authoritative: a grant added by hand is drift.

**Jody's step**, once when the client is made (the bootstrap) and at each rotation: in the Console (APIs & Services,
Credentials) make or rotate the web client, download its JSON, and add it as the secret's next version, in the Console's
Secret Manager page of `google-signin-seatrials` (New version, upload the file) or with gcloud:

```sh
gcloud secrets versions add google-signin-seatrials --project=tacplus-dev --data-file=client_secret.json
shred -u client_secret.json
```

Then fleet-seatrials' pipeline reads it, checks it with Google and installs it (its `docs/deploy-pipeline.md`, The Google
sign-in client); its `signin-secrets` job's log says `google: the client secret from the secret google-signin-seatrials`.
`secretVersionAdder` lists no secret and shows no version: the Console page is reached by its link
(`https://console.cloud.google.com/security/secret-manager/secret/google-signin-seatrials/versions?project=tacplus-dev`)
when the account holds no other role on `tacplus-dev`, and gcloud needs none. The output `deployments` names each one's
`google_signin` (null without it).

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

## The tacplus.dev cutover

#13; `decisions/only-vms-are-k8s-nodes-2026-11-04.md` (its addendum on the new cluster) and
`network-exposure-2026-11-03.md` (tacplus-dev/roadmap).

**The design.** The dev stack (`modules/projects/dev/dns.tf`) holds, in `tacplus-dev`:

- **The global address `gateway`,** external, IPv4, with `prevent_destroy`: the TCP proxy load balancer's (below, The
  public entry), and the only public IP; a rebuilt load balancer keeps it. IPv4 only (PROPOSALS.md, IPv6 on the
  address).
- **The zone `tacplus-dev` for `tacplus.dev.`,** DNSSEC on, written only by this pipeline. It is in the dev project, beside
  the dev zone and the challenge zones it delegates to, rather than in a `dns` project of its own: one project, one
  stack, so the delegations are references, not values copied between stacks. It holds:
  - the records copied from the zone in jody1-328023 (`modules/settings`, `zone`: the site, its verification, DMARC);
  - each deployment's hostnames (`modules/settings`, `deployments`), A to the gateway's address, TTL 300: today
    `seatrials.tacplus.dev` and `idp.test.tacplus.dev`. The test IdP is on a port of its own of the same address
    (below, The public entry), not on a load balancer and address of its own as in jody1-328023
    (tacplus-dev/fleet-seatrials test-idp/README.md): one public IP, and nobody but this pipeline writes the zone
    (PROPOSALS.md);
  - the delegations, NS, TTL 300: `dev.tacplus.dev` to the dev zone, `_acme-challenge.tacplus.dev` to the challenge
    zone (#6).

`apply:dev` prints the values of the steps below in its outputs: `zone` (its `name_servers`, the registrar's values) and
`gateway_address` (the IP the hostnames get), and `dns_name_servers` and `deployments` (the delegations').

**The DNS check.** The drift job's `ci/dns.sh` asks 8.8.8.8 and 1.1.1.1 for each record set of the new zone but its SOA,
its NS among them, and each answer that differs is a `dns tacplus-dev: ...` line of the drift issue, during the cutover
and after it. Until the registrar names the new zone, that is its NS, and any record the two zones do not share.

**The steps, propagation first.** The old zone is `tacplus-dev` in jody1-328023; its NS TTL is 21600 s (6 h), the
`.dev` registry's 10800 s (3 h), and a resolver may keep a delegation up to 48 h.

1. **Lower the TTLs (the hub), at least one old TTL before step 3:** the records that change, the old zone's own NS and
   `seatrials.tacplus.dev` (600 s), to 300 s:
   ```sh
   z="--zone=tacplus-dev --project=jody1-328023"
   gcloud dns record-sets update tacplus.dev. --type=NS --ttl=300 $z \
     --rrdatas="$(gcloud dns record-sets describe tacplus.dev. --type=NS $z --format='value(rrdatas.list(separator=","))')"
   gcloud dns record-sets update seatrials.tacplus.dev. --type=A --ttl=300 $z --rrdatas=146.148.80.132
   ```
2. **The new zone (the pipeline):** `apply:dev` creates it with the same records, plus the hostnames on the new address
   and the delegations. The hub then gives the old zone the same records, so that both zones answer alike whichever a
   resolver asks: `dev.tacplus.dev.` NS, TTL 300, to `dns_name_servers`, and the hostnames A to `gateway_address`
   (`gcloud dns record-sets create` or `update` in the old zone, `--ttl=300`). `_acme-challenge.tacplus.dev.` moves to the
   new challenge zone's name servers (`deployments`) with seatrials' move (Certificates). Then the drift issue lists only
   the NS of `tacplus.dev.`.
3. **The registrar (Jody, only he can),** once seatrials' pipeline writes its challenges in `tacplus-dev` (Certificates,
   the move to its identity there): the new zone delegates `_acme-challenge.tacplus.dev` to that zone only, so an order
   from the interim zone in jody1-328023 would fail. At the registrar of `tacplus.dev`, the name servers become the four of
   `apply:dev`'s output `zone.name_servers`, exactly as printed, without the trailing dot (e.g.
   `ns-cloud-b1.googledomains.com`). No DS record is added (the old zone has none, and the domain is unsigned); signing
   it, with the new zone's DS, is a later step (PROPOSALS.md). Check, the registry's answer:
   `dig +noall +authority +norecurse NS tacplus.dev @"$(dig +short NS dev. | head -1)"` gives the new four.
4. **Both zones serve, unchanged, for 48 h** after step 3 (the old NS TTL and the registry's are within it). A record
   changed meanwhile is changed in both: the new zone's by a commit (`modules/settings`), the old zone's by the hub. The
   DNS check reports nothing once every resolver has the new name servers.
5. **Then the old zone is retired** with the rest of jody1-328023 (`gcloud dns managed-zones delete tacplus-dev
   --project=jody1-328023`, its records deleted first). From then on a record of `tacplus.dev` is a commit here.

## The public entry

#21; `decisions/network-exposure-2026-11-03.md` (tacplus-dev/roadmap), its addendum "we terminate TLS, not the cloud"
(Jody, 2026-11-05). The dev stack (`modules/projects/dev/load-balancer.tf`) makes Google's **global external proxy
Network Load Balancer (TCP proxy)** on the address `gateway`, passing each TCP connection, TLS unopened, to the pods
behind a standalone zonal NEG in the dev cluster. TLS ends there: in the tacplus gateway, with the pipeline's
certificate (Certificates; tacplus-dev/gateway#25). No certificate, no Certificate Manager, no SSL policy, no HTTP(S)
proxy, no L7 Gateway: `ci/policy.sh` refuses them in any plan (above, The network rules).

Each **listener** is a port of the address (`modules/settings`, `load_balancer`): its global forwarding rule
(`EXTERNAL_MANAGED`, TCP, that port), its target TCP proxy (no PROXY header), and its backend service (TCP, idle timeout a
day), whose backend is the listener's NEG in the cluster's zone (`us-central1-a`), balanced by connection, with a TCP
health check on the endpoints' port. Each is named `lb-<listener>`.

**The NEGs' names are a contract** with the Services that expose them, named here: each Service carries
`cloud.google.com/neg: '{"exposed_ports": {"<service port>": {"name": "<NEG>"}}}'`, its targetPort the endpoints'
port; GKE makes the NEG in each zone with the Service's endpoints. A NEG's name is unique in its zone and project, so it
carries the deployment's name (`<deployment>-<what>`).

| Listener | Port on `gateway` | NEG | Endpoints' port | Its Service, rendered by |
|---|---|---|---|---|
| `gateway` | 443 | `seatrials-gateway` | 8443 | tacplus-dev/operator |
| `test-idp` | 8443 | `seatrials-test-idp` | 8443 | tacplus-dev/fleet-seatrials |

- `gateway`: tacplus.dev's gateway, `seatrials.tacplus.dev`. One Service for every gateway replica (port 443, targetPort
  8443), `type: ClusterIP` with the annotation, rendered by tacplus-dev/operator (tacplus-dev/operator#22), so that scaling
  the gateway never changes the backends.
- `test-idp`: the test IdP (tacplus-dev/fleet-seatrials#27), `https://idp.test.tacplus.dev:8443`, Keycloak serving its
  own certificate on its default HTTPS port, its Service rendered by fleet-seatrials' `test-idp/`. A TCP proxy does not
  route by SNI, so the test IdP cannot share 443 with the gateway; of the three ways (#21), a second port of the same
  address keeps one public IP (a second address would be another), needs no change in the gateway (routing by SNI there
  would), and adds no L7 path. Its issuers are `https://idp.test.tacplus.dev:8443/realms/<realm>`.

**`ready`.** A backend service whose backend names a NEG that does not exist is refused by the API, and the NEG exists
only once its Service is rendered in the dev cluster. So a listener starts with `ready = false`: its forwarding rule,
proxy and backend service exist, with no backend (a connection to its port is closed). Once GKE has made the NEG
(`gcloud compute network-endpoint-groups list --project=tacplus-dev`), a commit sets `ready = true` and `apply:dev` adds it.

**The nodes' firewall.** GKE makes no firewall rule for a standalone NEG. The rule `allow-google-proxies` admits the
endpoints' ports (tcp:8443) to the nodes (by their service account, `gke-nodes`) from Google's proxy and health-check
ranges, `35.191.0.0/16` and `130.211.0.0/22`, and from nowhere else; it is the dev module's one firewall rule
(`tests/load_balancer_test.sh`). The connections reach the pods from Google's proxies: the client's address is not
passed (no PROXY header; PROPOSALS.md).

`apply:dev`'s output `load_balancer` gives the address's IP, each listener's NEG, zone and ports, and the source ranges.

## The Anthropic organization

#34 (Jody's option A, 2026-11-10). Each deployment that runs llmproxy reaches the Anthropic API through Workload Identity
Federation: its fleet's kernel signs a token for llmproxy, and an Anthropic federation rule exchanges it for a
short-lived token of a service account (decision: vendors' own APIs, through llmproxy). The stack `anthropic` owns
those identities, from `modules/settings` (`deployments`, `llmproxy`): the federation issuer (the fleet's OIDC issuer,
by discovery), the service account (`developer`) and its membership of the deployment's workspace, and the rule
(`subject_prefix` llmproxy's own subject, exactly; a workspace scope, in that workspace). It makes, changes and archives
them; nobody clicks in the Console. Its output `llmproxy` gives each deployment's pipeline the IDs its llmproxy names.

- **Adopted, not made again:** seatrials' were made by hand on 2026-10-24; `import` blocks adopt them by the IDs its
  llmproxy names (each `adopt` in `modules/settings`). An adoption plans no change: `ci/policy.sh` refuses a plan that
  adopts an identity with a change, so the config is what the Console holds, and a change is a commit of its own after.
  seatrials' rule narrows to `workspace:inference` that way, once adopted (Jody, 2026-11-10: llmproxy calls inference
  only), in place, with the same ID.
- **Never made again under a new ID:** each identity is `prevent_destroy`, and the plan fails if it finds one archived
  (in the Console): a new one would have a new ID and break the deployment's config. One archived by hand is restored by
  hand, or its deployment's config changes in a commit.
- **Drift:** the nightly drift plans it like any stack (a normal plan: the issuer's `poll_status`, which moves on every
  poll, is no change). A Console edit of a managed field is an update in the plan, and the next apply on main puts it
  back. `ci/policy.sh` refuses a rule of any other scope than `workspace:developer` or `workspace:inference`, and an
  account of any other role than `developer`.
- **The provider:** `ippontech/anthropic` 1.92.0 (MPL-2.0), our reproducible build of its tag with go1.27.4 (#39)
  (`ci/anthropic-provider.sh`), installed only from `bin/providers` and locked by its hashes; the security job scans it
  (govulncheck). A new release is a commit of its version, commit and SHA-256s, then `ci/lock.sh`.
- **Tests:** the stack's plan against a mock provider, and against a stub of Anthropic's API with the real provider
  and the pipeline's credential path (`tests/anthropic_plan_test.sh`): the adoption with no change, a Console edit planned
  back, an archived identity refused, a widened bootstrap rule reported.

**The pipeline's credential: no key.** Anthropic's service-account and federation endpoints accept no Admin API key,
only an `org:admin` OAuth token; a person's login is short-lived, so the pipeline federates too. The jobs
`plan:anthropic`, `apply:anthropic` and `drift` have three GitLab ID tokens for `https://api.anthropic.com`
(`ANTHROPIC_ID_TOKEN_<n>`); the provider's `federation` exchanges one through the bootstrap rule for a token of an hour,
and again before it expires. Anthropic accepts each token's `jti` once, so every exchange takes one no exchange has
presented (`ci/anthropic-token.sh`); a plan or an apply exchanges once. `ci/lib.sh`'s `ci_anthropic` gives the provider
the rule, its account and the organization, the CI file's `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_SERVICE_ACCOUNT_ID`
and `ANTHROPIC_ORGANIZATION_ID` (IDs, none secret). Until the rule and the account are set there, the anthropic jobs are
not in the pipeline, and the drift skips the stack.

**The bootstrap, by hand, once (Jody).** An OAuth caller can neither make an `org:admin` rule nor give an account the
`admin` role, so the one rule the pipeline federates through is made in the Console, and stays out of every state.
The stack reads it and checks it is still what `modules/settings` (`anthropic`) says; a check that fails is in the plan
and in the drift issue (`ci/tofu.sh`), and nothing is applied to it.

Done by Jody on 2026-11-11, as follows; a second one, for another project, is the same steps:

1. Workload identity → the issuer `gitlab-com` for `https://gitlab.com` (`fdis_017qDpHredkBHa68QFkT4gcQ`), by
   discovery, JTI replay protection on. There is one issuer per URL: one archived for it is unarchived and reused.
2. The service account `cloud-admin-pipeline` (`svac_011SKzqJqvTtj2LmUFbbDztN`) with the **Admin** organization role.
3. The rule `cloud-admin-pipeline` (`fdrl_01JYRHz8AjGZ7TBcEQL9Eqvo`) on that issuer, to that account, scope
   **`org:admin`** only (Advanced): `subject_prefix` exactly `project_path:tacplus-dev/cloud:ref_type:branch:ref:main`
   (no `*`), claims `ref_protected` = `true`, audience `https://api.anthropic.com`, token lifetime 3600.
4. The rule's `fdrl_` and the account's `svac_` in `ci/gitlab-project.gitlab-ci.yml` (`ANTHROPIC_FEDERATION_RULE_ID`,
   `ANTHROPIC_SERVICE_ACCOUNT_ID`), by a commit, and the project's copy with it (`ci/pin.sh`): the next pipeline on main
   plans the adoption.

No key is made, stored or rotated.

## People

Readers get `viewer` and `iam.securityReviewer` on the parent folder and nothing that writes: their accounts, listed in
`stacks/folder/main.tf` (`readers`) by a commit. The host's domain-restricted sharing admits only its own directories'
accounts.

## Locally

```sh
ci/tools.sh                      # bin/: tofu, tflint (and the google ruleset), shellcheck, yq, gitleaks, the gitlab,
                                 # kubernetes and google providers, GitLab Runner and its plugin (needs go, git, curl, xz, jq)
ci/tools.sh security             # bin/: osv-scanner, trivy, govulncheck; bin/scan/: the binaries to scan (after ci/tools.sh)
ci/security.sh                   # the security job: security/report.json (needs the full history)
ci/lint.sh all                   # fmt, validate, tflint, shellcheck, policy
ci/checks.sh                     # the tests, and tofu test of every stack against mock providers
bootstrap/bootstrap.sh --folder <FOLDER_ID> --billing-account <ID> --dry-run    # with your gcloud: changes nothing
ci/lock.sh                       # after changing a provider's version, or one of ci/*-provider.sh: the lock files
```

## Never

- Applies anything not in a plan saved by its own pipeline, of a commit of main.
- Creates a service-account key, or grants anything to `allUsers` or `allAuthenticatedUsers`.
- Gives a VM an external address, admits the internet to anything but a load balancer, or opens port 22 (above, The
  network rules).
- Deletes a project, a folder, the cluster or the reader's key: projects are `deletion_policy = PREVENT`, folders and the
  cluster deletion-protected, the key `prevent_destroy`. Deleting one is Jody's, on purpose.
- Builds `prod`.
