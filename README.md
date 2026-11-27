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
  - `ci` / `tacplus-ci`: no GitLab runner since #113 (below, What runs where), the build cache (below, The build cache), the
    release registry `releases` (below, The release registry), and the GitHub Apps' KMS keys (`tacplus-manager`, `tacplus-looper`, `tacplus-reader`, `tacplus-admiral`, `tacplus-check`
    and `tacplus-merger`, import-only),
    their import jobs, the federation that signs with them and the reader's account `fleet-seatrials-reader` (below, The
    GitHub Apps' keys), the Admiral's account `admiral` and its secret `admiral-triage-gitlab` (below, The
    Admiral's credentials), the looper VMs, one instance group of 0..1 per project (below, The looper VMs), and the
    reserved machines of the rolling check and the merger (below, The reserved machines);
  - `dev` / `tacplus-dev`: the dev GKE cluster (zonal, arm64 Axion C4A, private Container-Optimized OS nodes: a normal
    pool of 3 x c4a-standard-2 on demand, a spot build pool of c4a-standard-4 from 0 to 8 over the region's zones
    with c4a, for build pods only, and a looper pool of c4a-standard-2 on demand from 0 to 2, for the overflow of
    the in-cluster runners' job pods only, and the quotas they need: below, The network rules), the DNS zone
    `dev.tacplus.dev`, `cluster-admin-pipeline`, federated from tacplus-dev/cluster's protected main, with its
    cluster-admin in the cluster, the runners' token secrets it reads and its registry `ci-images` (below, The cluster
    pipeline), each deployment's certificate secrets and `_acme-challenge` zone, which only its pipeline writes (below,
    Certificates),
    its `get-credentials` on the cluster, Cloud Build roles, deploy registry, build bucket and environment accounts
    (below, Deployments: images, the cluster and environment accounts), its fleet's CA, crypto file and root credential
    secrets, which only its init-secrets job writes (below, The fleet's CA, crypto file and root credential), its
    Google sign-in client's secret, which Jody writes in the Console and only its identity reads (below, The Google
    sign-in client),
    the one public IP, the global address `gateway`, its TCP proxy load balancer passing TLS through to the NEGs of the
    gateway's Service (below, The public entry), and `tacplus.dev`'s own zone, which only this pipeline writes (below,
    The tacplus.dev cutover), and the Admiral's workload identity provider, for its fleet kernel's issuer (below, The
    Admiral's credentials);
  - `prod` is designed but **not built**: see PRODUCTION.md.
- **The Anthropic organization** (#34): for each deployment that runs llmproxy, its llmproxy's workload identity, the
  federation issuer, the service account, its workspace membership and the rule (below, The Anthropic organization);
  the hand-made seatrials ones adopted by their IDs. Not the one org:admin rule the pipeline itself federates through,
  made by hand and only read here.
- **GitLab settings:** this project's protected `main` and environments, its protected project variables (values from
  Secret Manager by version, never in this repository), the runner registrations: the `ci` pools' and the in-cluster
  `infra` runner's (unpaused at the switch-over, #66, which paused the `cluster` and `deploy` pools: below, The cluster
  pipeline), each one's token
  written to its Secret Manager secret by this pipeline, and the read-only memberships of other projects,
  each with an expiry: `tacplus-looper-bot` a Reporter of tacplus-dev/build, for the looper's nightly recap (below,
  Memberships); and tacplus-dev/build's `.gitlab-ci.yml`, its pipeline trigger, whose token is tacplus-dev/looper's
  `BUILD_TRIGGER_TOKEN`, rotated, and its nightly and release schedules (below, The build pipeline).

## Layout

| Path | What |
|---|---|
| `bootstrap/bootstrap.sh` | Jody's one-time script (below). |
| `modules/settings` | The names every stack shares: the parent folder (an input, never written here), region, project IDs, the pipeline's identity, the looper VMs and the reserved machines, tacplus-ci's quotas. |
| `modules/folder`, `modules/projects/ci`, `modules/projects/dev`, `modules/gitlab` | The modules. |
| `stacks/<folder\|ci\|dev\|gitlab\|anthropic>` | The five roots, each its own state (`gs://tacplus-bootstrap-tofu-state/<stack>`), OpenTofu and providers pinned exactly, `.terraform.lock.hcl` with every provider's hashes, `tests/` (its plan against mock providers). |
| `ci/gitlab-project.gitlab-ci.yml` | The GitLab project's `.gitlab-ci.yml`, with `CLOUD_COMMIT` set (`ci/pin.sh`). |
| `ci/*.sh` | `tools` (pinned tools, by checksum), `security` (the security job), `gitlab-provider`, `kubernetes-provider` and `anthropic-provider` (those providers, built from source), `anthropic-token` (the anthropic provider's ID tokens, one per exchange), `tofurc` (OpenTofu installs those builds only), `lint`, `checks`, `policy`, `tofu` (plan, apply, drift), `drift`, `audit` (the drift's live audit), `hub-audit` (the audit job's report, below, The hub's audit), `iam-ready` (a new project's IAM gate), `dns` (the drift's DNS check), `pools` (the drift's pool check), `idle-runners` (`plan:ci`'s check that the retired pools' runners are idle, #113), `expiry` (the drift's expiry check), `build-ci` (tacplus-dev/build's `.gitlab-ci.yml`, checked and linted), `lib` (credentials), `lock`, `pin`. |
| `stacks/gitlab/files/build.gitlab-ci.yml` | tacplus-dev/build's `.gitlab-ci.yml`, tacplus-dev/looper's copied as is (below, The build pipeline). |
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
  `modules/settings` names. The `audit` job alone is `hub-audit@tacplus-ci.iam.gserviceaccount.com` instead, read-only,
  through the same provider (below, The hub's audit).
- **Runner:** the in-cluster `infra` runner (below, The cluster pipeline), tag `cloud`, a pod per job in the dev
  cluster, protected refs only. Every job is tagged for it.
- **The parent folder:** the protected project variable `GCP_PARENT_FOLDER`, its numeric ID; `ci/lib.sh` gives it to the
  stacks as their variable `parent_folder`, and refuses a job without one. No file here holds it.
- **Order:** the checks, then `folder` (the folders), then `ci` and `dev` (the projects), then `gitlab` (whose runner
  tokens go to the `ci` project's secrets). Each stage's plan is made after the stage before it is applied. `anthropic`
  runs beside them after the checks, needing none (below, The Anthropic organization).
- **A new project's IAM:** the pipeline's rights in `tacplus-ci` and `tacplus-dev` are its roles on the parent folder,
  which reaches a project created seconds before only after a minute or two. In each project module everything after
  the project and its APIs waits for `terraform_data.iam_ready`, which runs `ci/iam-ready.sh`: Resource Manager's
  `testIamPermissions` until the pipeline holds the permissions of the project's first creates on three checks in a
  row, ten seconds apart, bounded to ten minutes. An existing project passes at once.

| Job | When | What |
|---|---|---|
| `tools` | every push and merge request | OpenTofu, tflint (and its google ruleset), shellcheck, yq and gitleaks, pinned by version and SHA-256, and the gitlab, kubernetes and anthropic providers built from source (`ci/tools.sh`); checks the project's `.gitlab-ci.yml` is this repository's with only `CLOUD_COMMIT` set (`ci/pin.sh --check`). |
| `fmt`, `validate`, `tflint`, `shellcheck`, `policy` | every push and merge request | `ci/lint.sh <job>`: no credential, no cloud. `policy` refuses a service-account key, `allUsers`/`allAuthenticatedUsers`, and what a commit does not fix (`timestamp()`, `uuid()`, an image at `:latest`, an image family). |
| `test` | every push and merge request | `ci/checks.sh`: the shell tests, and `tofu test` of each stack: its plan under a stub parent folder, with empty projects (mock providers). The gitlab stack is also planned with its real providers against a stub of gitlab.com's API (`tests/gitlab_plan_test.sh`, #17): gitlab.com is an Enterprise instance to the provider, on Free too; and the anthropic stack against a stub of Anthropic's (`tests/anthropic_plan_test.sh`, #34). |
| `security` | every push and merge request, and the nightly schedule | `ci/tools.sh security && ci/security.sh`: OSV-Scanner, govulncheck, gitleaks and Trivy, the policy and `security-exceptions.yaml` (below, Security checks): it fails on what ships, never on CI tooling (#101); its report the artifact `src/security/`. `plan:folder` needs it: no plan, so no apply, unless it passes. |
| `plan:<stack>` | main (push, web, API) | `plan:ci` first: the tacplus-ci pools' runners idle for a day, if any is still registered (`ci/idle-runners.sh`, with the GitLab token, #113; below, What runs where). `ci/tofu.sh plan`: the plan, saved as the artifact `plans/<stack>.tfplan` with its `.txt` (to read), `.json` and `.sha256`; refused, and so never applied, if `ci/policy.sh` refuses the plan: a key, a public member, `roles/owner` or `roles/editor` to any service account, the pipeline's own included (#78), `roles/container.admin` to one but the pipeline (below, The cluster pipeline), a break of the network rules (below), an Anthropic identity adopted with a change (below, The Anthropic organization), another writer, a reader not a service account or another role on the release registry (#115; below, The release registry), or a `BUILD_GATES_REQUESTS_*` requesting more than 3 CPU or 10Gi (#87; below, The build pipeline: its settings). A failing check is said, not refused. The artifacts are for project members only (a plan can hold secret values). |
| `apply:<stack>` | main, **automatically** once its plan succeeds | `ci/tofu.sh apply`: applies **exactly that saved plan** (its SHA-256 checked; OpenTofu refuses it if the state changed since). Environment `<stack>`, one at a time. |
| `audit` | the hourly schedule `audit`, and on demand (web or API, `CLOUD_AUDIT` `true`) | Alone in its pipeline: the hub's report of `tacplus-ci` and `tacplus-dev` (exposure, inventory, quotas, utilization, secrets' names, registries' IAM), read as the read-only `hub-audit` (`ci/hub-audit.sh`); its artifact `src/audit/` (`audit.json`, `audit.md`), 30 days. Red on an ingress rule open to `0.0.0.0/0`, a VM's external IP or a public registry (below, The hub's audit). |
| `drift` | the nightly schedule | A plan of every stack (`anthropic` once its bootstrap rule is set), saved nowhere, no lock, with its failing checks, then the live audit of the projects against the network rules (`ci/audit.sh`, below) and of what is left of the runner pools (any `runner-*` VM, disk, template or group, #113), the pool check (`ci/pools.sh`: why an instance group of the ci project makes no VM) and the expiry check (`ci/expiry.sh`: an expiry within 30 days, below, Memberships); if anything differs, breaks them or expires, an issue here (one open at a time; a new drift is a comment). Never applies. |

The cloud jobs run only on main, because Workload Identity Federation admits only this project's protected main: a merge
request gets the checks, and its plan runs once it is merged. Only `apply-prod` (not built) will be a protected manual job
that Jody plays, on a commit already applied to dev.

### Determinism

- Every tool, provider and image is pinned by version and digest: OpenTofu 1.13.2, tflint 0.66.0 and its google ruleset
  0.41.0, shellcheck 0.11.0, Trivy 0.76.2 (each by SHA-256, `ci/tools.sh`); yq by module version (the Go checksum
  database); gitleaks v8.30.1, OSV-Scanner v2.7.0 and govulncheck v1.1.4 by module version and hash, built with Go 1.27.3; the
  `google` 8.9.0, `kubernetes` 3.4.0 (the dev stack), `gitlab` 19.5.0 and `anthropic` 1.92.0 (ippontech's, the anthropic stack) providers, by hash in each lock file (`ci/lock.sh` writes them; jobs init with
  `-lockfile=readonly`), the `gitlab`, `kubernetes`, `google` and `anthropic` ones our own reproducible builds (below), by its commit and its SHA-256; the CI image by digest;
  the looper VMs' and the reserved machines' Container-Optimized OS image by name (`modules/settings`' `cos_arm64_image`).
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
  `22`, or a range covering it) is refused, with no exception: the runners' internal rule
  `runner-manager-to-workers-ssh` went with the runner VMs (#113). Break-glass on a VM is its serial console and its logs.
- **No VM outside GKE** (#11; `decisions/only-vms-are-k8s-nodes-2026-11-04.md`, and for the build environment
  `looper-build-vms-2026-11-24.md`, tacplus-dev/roadmap): a standalone VM (`google_compute_instance`,
  `google_compute_instance_from_template` or `_from_machine_image`) created or updated is refused in every stack, with
  no exception; so is an instance template or instance group manager, zonal or regional, but the ci module's
  looper VMs and reserved machines, admitted by address (`module.ci.google_compute_instance_template` and
  `google_compute_instance_group_manager`, `looper_vm`, `reserved_vm` and the check machines' `reserved_vm_check`),
  whose templates must boot Container-Optimized OS pinned by name (`modules/settings`' `cos_arm64_image`) and are held
  to the rules above and below like any VM. The source check refuses the same resource blocks outside
  `modules/projects/ci`'s two. A new kind of VM outside GKE is a
  change to `ci/policy.sh`'s admitted list, reviewed as such. GKE's own nodes are in no plan; the live audit does not
  report this one (a live VM has no stack address), and names the runner pools' leftovers instead (below, What runs
  where).
- **Private nodes, on Container-Optimized OS:** a cluster without `private_cluster_config.enable_private_nodes`, a node pool
  with public nodes, or one whose `image_type` is not `COS_CONTAINERD`, is refused.
- **No public control plane** (Jody, 2026-11-18, #79: only load balancers are public; until then it was public, Jody,
  2026-11-04): the dev cluster's control plane has no public endpoint (`enable_private_endpoint`), and its private one
  (`172.16.0.0/28`) accepts only the cluster's own nodes (`10.20.0.0/20`) and pods (`10.24.0.0/14`), its master
  authorized networks enforced on the private endpoint too, Google Cloud's public ranges off. The cloud, cluster and
  deploy pipelines reach it from inside, on the in-cluster runner `infra` (below, The cluster pipeline), whose job pods
  are in the pods' range; `get-credentials` gives the private endpoint, which is the cluster's only one. Nothing on the
  internet, the VMs in `tacplus-ci` and the hub's own machine included, reaches it. A cluster with a public
  endpoint, with no master authorized networks, or authorizing a public range or Google Cloud's public ranges, is
  refused in a plan, and the live audit reports one.
- **The pools:** `normal`, 3 x c4a-standard-2, on demand and fixed, runs the platform in the cluster's zone; `spot`,
  c4a-standard-4 spot from 0 to 8 (5 until #96), labelled `spot=true` and tainted `spot=true:NoSchedule`, runs build pods only: only
  they tolerate the taint (tacplus-dev/cluster#6). The dev stack's output `cluster` gives the label and the taint.
  `spot` spreads over every zone of the region that offers its machine type (#85: the provider's machine-type data,
  read at plan): on 2026-11-20 spot c4a ran out in us-central1-a, then its only zone, and gates pods waited Pending at
  2 nodes of 5. Its 8 are the pool's in all zones (`total_max_node_count`), and GKE makes each node in whichever zone
  has the capacity (location policy `ANY`). `looper` (#95, the decision's addendum of 2026-11-22), c4a-standard-2 on
  demand from 0 to 4 (#107) in the cluster's zone, labelled `looper=true` and tainted `looper=true:NoSchedule`, runs the looper
  runs that overflow the normal nodes: only the control runner's job pods tolerate the taint
  (tacplus-dev/cluster#47), so it empties back to 0 when they end. On demand, as a looper run lasts hours and spot
  would preempt it; 4 is at most the about $260/month Jody approved on 2026-11-24 (#107; 2 and $130/month until then),
  and a larger maximum needs Jody's yes. The output
  `cluster` gives its label and taint too.
- **The node pools' quotas (#88):** on 2026-11-21 `spot` still stopped at 2 nodes of 5, every scale-up refused
  `QUOTA_EXCEEDED`: Hyperdisk Balanced (`HDB_TOTAL_GB`, 500 GB in us-central1, all used by 5 nodes of 100 GB) and C4A
  CPUs (`CPUS_PER_VM_FAMILY`, 24). The dev stack asks Google for what its pools need, as Cloud Quotas preferences of
  `tacplus-dev` in the region, computed from the pools, never typed (its output `quotas`): C4A CPUs, each pool's at
  its maximum and one node's of the largest machine type for a node being replaced, rounded up to a multiple of 8
  (6 + 32 + 8 + 4 = 50: 56, with the build pool's 8 x 4, #96, and the looper pool's 4 x 2, #95, #107); Hyperdisk Balanced, a
  disk of `disk_gb` for each of those nodes, rounded up to a multiple of 500 (16 x 100 = 1600: 2000). A plan whose C4A pools its preferences do not cover (none, another
  region's, or fewer) is refused (`ci/policy.sh`), as is a preference without a contact. Google asks the contact
  about an increase: the protected GitLab variable `GCP_QUOTA_CONTACT`, an email of the host's directory with quota
  update permission on `tacplus-dev` (`ci/lib.sh` gives it to the dev stack as `quota_contact`). An increase may wait
  on Google's review: the preference is reconciling until granted, and the hub's audit shows each quota's limit, usage
  and request (below, The hub's audit). The pipeline makes them with the host's `roles/cloudquotas.admin` (below, What
  the host organization provides), through a provider of their own whose calls count against `tacplus-dev`
  (`billing_project`, `user_project_override`, #90), which enables the Cloud Quotas API itself, not against the
  pipeline's `tacplus-bootstrap` (`tests/quotas_plan_test.sh`). Raising a pool raises them in the same commit; a raise Google has not granted yet
  leaves the pool short until it does.

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
  the pipeline's Google credentials. Its tag v8.9.0 at the pinned commit, with go1.27.4, x/net v0.62.0 and x/crypto
  v0.59.0 (GO-2026-5932, #76: it deletes `openpgp`, which the provider does not import), installed and locked as the
  `gitlab` one is.
- **OpenTofu, tflint, its google ruleset and Trivy are built from source with go1.27.4** (#39): upstream's releases are
  built with go1.27.3 or go1.26.10, without GO-2026-6859's fix. `ci/tools.sh` builds each from its release's module
  (pinned by its `h1:` hash, checked against the Go checksum database) as upstream builds it (CGO off, `-trimpath`, its
  ldflags), with no VCS stamp, so reproducibly: each build is refused unless its SHA-256 is the pinned one. yq, gitleaks,
  OSV-Scanner and govulncheck are built with the same Go. Each goes back to upstream's release when one is built on a
  fixed Go (PROPOSALS.md).
- **Accepted until 2026-12-03:** OpenTofu 1.13.2, tflint 0.66.0 and its ruleset 0.41.0:
  x/net HTTP/2 and html, x/crypto/openpgp, x/mod's sumdb and a gRPC
  server panic. They run on trusted, pinned inputs (lock-file hashes, this repository, Google APIs and gitlab.com over
  TLS), and none of them has a fixed release yet. tflint 0.66.0 and Trivy 0.76.2 have x/net v0.62.0, so x/net html's
  GO-2026-6860 and GO-2026-6866 name only OpenTofu and the ruleset (#62).

- **Accepted until 2026-12-04** (#10): gitleaks v8.30.1's xz (GO-2025-3922), with no gitleaks release past it yet.
- **gitleaks and OSV-Scanner are built with the fixed klauspost/compress and brotli** (#24): `ci/tools.sh` builds each
  from its pinned module in a copy of its source that requires klauspost/compress v1.20.2 (GO-2026-6865, a panic on
  two-block frames) and, for gitleaks, brotli v1.2.7 (GO-2026-6888, excessive allocation decompressing crafted
  streams), checked against the Go checksum database, until their releases require them. **Accepted until
  2026-12-06** (Jody's decision on #24): GO-2026-6865 in the downloaded OpenTofu 1.13.2 and Trivy 0.76.2, which decode only
  pinned, trusted inputs; each pin moves when its upstream ships the fix.
- **OpenTofu is built with the fixed go-jose** (#98): `ci/tools.sh` builds it from its release's module source
  (`srcbuild`) requiring go-jose v4.1.6, checked against the Go checksum database, in place of the release's v4.1.4
  (GHSA-mgcc-cww5-fp2q, HIGH, a DoS parsing JWKs with RSA keys; GHSA-4w3g-jfj2-cw2q and GHSA-vvm8-gf78-28g4), whose
  advisories have no Go vulndb id yet, so govulncheck cannot see them; `tests/security_test.sh` checks `bin/tofu`'s.
- **GitLab Runner and its fleeting plugin are no longer built or scanned here** (#113): the runner manager that ran
  them went with its pools (below, What runs where), and with them their exceptions (GO-2026-6984, the plugin's
  GHSA-q7gw-24fr-5p69).
- **The CI image is the 2.6 line's build:20261126-57a6521 by digest** (#102; build:2.6's rebuild of 2026-11-26; before it
  build:20261123-57a6521, #104; build:20261123-ef62327, #97, from Debian's fixes of that day,
  krb5 1.21.3-5+deb13u2 among them, after 159 HIGH advisories in 2.6.13's packages turned the security job red; 2.6.13, #91;
  2.6.12, #59): its `linux-libc-dev` is 6.12.117-1 (DSA-6628-1: six HIGH kernel
  CVEs in 6.12.116-1 turned the security job red on 2026-11-14; tacplus-dev/tacplus#711 rebuilt the image, as #554
  did), its `gh` has x/net >= v0.62.0 (CVE-2026-78661, #27) and its zlib the fix (CVE-2026-85091), so their exceptions
  are gone, and it has no OpenEXR since 2.6.10 (#43; tacplus-dev/tacplus#554: 16 CVEs in Debian 13's, from
  buildpack-deps' imagemagick). Its `gh`'s x/crypto/openpgp is GO-2026-5932's, above. No kernel from the headers
  package runs here, so each kernel advisory batch is a re-pin, not a risk (PROPOSALS.md).

The `security` job enforces it (below), on every pipeline.

### Security checks

tacplus-dev/looper#49's floor, in this pipeline (#10): tacplus-dev/build's checks, which run it elsewhere, never reach
this one, which applies with the strongest credentials we have. `ci/security.sh`, the `security` job, on every push, merge
request and nightly schedule:

- **OSV-Scanner** on the tree's dependency manifests and lock files (the commit's tree; today it reads none of them:
  the providers' lock files are OpenTofu's, and their binaries are scanned below);
- **`govulncheck -mode=binary`** on every pinned binary the pipeline runs or installs, symbols present: OpenTofu, tflint
  and its google ruleset, yq, gitleaks, OSV-Scanner, Trivy and govulncheck, the `gitlab`, `kubernetes` and `google`
  providers (`bin/`). shellcheck is not Go;
- **gitleaks** on the tree and its whole history (the job fetches it: a shallow clone fails);
- **Trivy** on the CI image the jobs run in, by its digest (`default.image`).

**The policy** is looper-scan's (tacplus-dev/looper#225): every finding has a `scope`, `shipped` (OSV-Scanner and
gitleaks: the tree, its lock files and its history) or `tooling` (govulncheck on the pinned binaries, Trivy on the CI
image: what only our pipelines run), and only a shipped one fails (tacplus-dev/roadmap
`decisions/security-gates-ship-only-2026-11-23.md`, #101). It fails on any shipped secret, and on any shipped HIGH or
CRITICAL finding that has a fixed version, unless an unexpired entry of `security-exceptions.yaml` names it (its ID or
an alias) and, with a `where` (a path or a path glob, looper-scan's: `*` within a path segment, `**` across them), the
finding's binary or file (#103). A tooling finding is reported, never failing: the job lists each one the policy would
otherwise fail under "CI tooling (reported, never failing)", with its count beside those failing; an exception accepts
it as it does a shipped one. An entry that has expired, whose fields are not exactly `id`, `reason`, `decided_by` and
`expires` (YYYY-MM-DD) and an optional `where`, or whose `where` is empty, fails the job whatever it names, and so does
a tool that cannot run or a pinned binary missing. A failing `security` job stops the pipeline before `plan:folder`.
The report: `security/report.json` (every finding: its scope, and blocking, accepted or neither; `tooling`, the count
reported; the problems; the verdict), with each tool's own report in `security/raw/`; the job's artifact, kept 30
days. The vulnerability databases are the day's, so a commit that passed can fail the next night: fix the pin, or
accept the finding with a reason and an expiry, at most 30 days. `tests/security_test.sh` tests it (a planted secret,
an expired exception, a clean tree, the policy, a `where`, a tooling finding reported and passing) with stubs for
the scanners that need a database.

### How a change flows

1. A pull request here; the tests run as its gates (the looper's land, or `ci/tools.sh && ci/lint.sh all && ci/checks.sh`,
   `gates.yaml`'s `full`; a change to the top-level docs no other test reads, PROPOSALS.md, ROADMAP.md, STATE.md,
   HISTORY.md and LICENSE, runs its `docs` set alone, `tests/hosting_test.sh`, #118). They run in the image `build.lock`
   pins by digest, the CI image, with no Docker: tacplus-dev/build builds a commit only from that pin (looper#71). To
   move it, change `build.lock` and the CI file's `default.image` together (`tests/ci_test.sh` refuses them apart): a new
   digest is a change like any other, landed on the full gates. The pin is a tacplus line's dated build tag at its digest,
   `build:<YYYYMMDD>-<commit>@sha256:…`, never a floating `build:X.Y`, which moves on every rebuild (#102, cluster#54):
   the nightly scan moves it to its line's newest (looper#226).
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
- **For `cloud-admin-pipeline`**, once the bootstrap has made it, on the parent folder: the least set the stacks use
  (#78; `HOST_ROLES` in `bootstrap/bootstrap.sh`, which reports any still to grant), never `roles/owner` or
  `roles/editor` (`ci/policy.sh` refuses either to any service account in a plan, and the bootstrap says to remove
  either where the host still grants it):
  - `roles/resourcemanager.folderAdmin`: the folders `ci` and `dev`, and the readers' grants on the parent folder;
  - `roles/resourcemanager.projectCreator`: the projects `tacplus-ci` and `tacplus-dev`;
  - `roles/billing.projectManager`: their billing link (with `billing.user` on the billing account, the bootstrap's);
  - `roles/resourcemanager.projectIamAdmin`: the projects' IAM;
  - `roles/serviceusage.serviceUsageAdmin`: their APIs;
  - `roles/iam.serviceAccountAdmin`: their service accounts, and who may use or federate to them;
  - `roles/iam.serviceAccountUser`: those accounts on the VMs and the cluster's nodes;
  - `roles/iam.workloadIdentityPoolAdmin`: the federations' pools and providers;
  - `roles/iam.roleAdmin`: the custom role of the apps' key importers;
  - `roles/compute.admin`: the networks, firewall rules, routers and NAT, the VMs, their templates and groups, and the
    load balancer;
  - `roles/container.admin`: the cluster and its node pool, and through GKE's RBAC its `cluster-admin` binding (below,
    The cluster pipeline): the one service account that holds it;
  - `roles/dns.admin`: the zones, their records and IAM;
  - `roles/secretmanager.admin`: the secrets, their versions (the in-cluster runners' tokens) and IAM;
  - `roles/cloudkms.admin`: the apps' key ring, keys, import job and IAM;
  - `roles/storage.admin`: the buckets (the build cache), their objects and IAM;
  - `roles/artifactregistry.admin`: the registries and their IAM;
  - `roles/logging.configWriter`: the log views, `hub-audit-autoscaler` on each project's `_Default` bucket (#85; below,
    The hub's audit). Granted before `modules/settings`' `autoscaler_log` is set `true`, in a commit of its own: until
    then the ci stack makes no log view.
  - `roles/cloudquotas.admin`: the dev node pools' quota preferences, C4A CPUs and Hyperdisk Balanced GB (#88; above,
    The network rules, The node pools' quotas). Granted before the first `apply:dev` that makes them, with `GCP_QUOTA_CONTACT` set:
    until then that apply fails on them. Their calls count against `tacplus-dev` (#90), whose Cloud Quotas API the dev
    stack enables, with `serviceusage.services.use` there from `roles/serviceusage.serviceUsageAdmin`: the bootstrap
    need not be run again for them (it enables the API in `tacplus-bootstrap` too, which no stack relies on).

  A role here is one a stack's resource needs (`tests/apis_test.sh` names the API of each); a new kind of resource
  is a new line here, and the host's grant, before its first apply. Nothing beyond these, and nothing at the
  organization's level: this repository holds no right over the host's organization; the folder stack grants the
  pipeline nothing (until #78, owner of `ci` and `dev`).
- **The org policies, the host organization's job.** It enforces them for everything under it, the parent folder
  included, and checks them for drift; this repository relies on them and sets none (`roles/orgpolicy.policyAdmin` can be
  granted only at an organization's level). The set it relies on:
  - `iam.disableServiceAccountKeyCreation` and `iam.disableServiceAccountKeyUpload`, enforced: no service-account key;
  - `iam.workloadIdentityPoolProviders`: `https://gitlab.com`, and each fleet kernel's issuer a provider here trusts:
    in dev `https://seatrials.tacplus.dev`, the Admiral's (#84; below, The Admiral's credentials). A new kernel issuer
    is a host step before its provider's first apply: a provider for an issuer the host does not allow fails `apply:dev`
    (#86), and every apply after it;
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
(`GCP_GOOGLE_SIGNIN_ADDERS`, below, The Google sign-in client, #37), and the Admiral's secret's adders
(`GCP_ADMIRAL_SECRET_ADDERS`, below, The Admiral's credentials, #84), whose token is the GitLab.com user
`tacplus-admiral`'s (its email `jody+tacplus-admiral@seabeam.net`, a plus-address of Jody's, #89), a Reporter of the
triage project seabeam/triage and of nothing else. The node pools' quota contact (`GCP_QUOTA_CONTACT`, #88) is
`jody@seabeam.net` too.
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
   Console (below, The Google sign-in client); `GCP_QUOTA_CONTACT` (protected): the email Google asks about an
   increase of the dev node pools' quotas (above, The network rules, The node pools' quotas). The gitlab stack adopts it and `main`'s
   protection (its import blocks), and sets the reader's two variables from Secret Manager.
4. **The drift issue:** the tacplus-reader app installed on `tacplus-dev/cloud` with Issues read and write. This
   project's jobs sign with the KMS key `tacplus-reader` in `tacplus-ci` (the ci stack's binding, #30) once its version
   is imported (below, The GitHub Apps' keys): until then the drift job files no issue.
5. **`.gitlab-ci.yml`** from `ci/pin.sh <commit of main>`, and a nightly schedule on main.

The first pipeline on main then creates the folders, the `ci` and `dev` projects, and the GitLab
settings, each from its saved plan. tacplus.dev's zone in `tacplus-dev` writes the delegations of the dev zone and the
challenge zones itself; until the registrar names it, the zone in jody1-328023 still answers, and the hub gives it the
same records (below, The tacplus.dev cutover).

## The hub's audit

#77 (Jody, 2026-11-17): the hub's read-only cloud checks run in this pipeline, not with gcloud on the Mac (Jody's login
there expires daily, and a key file on disk would break "nothing on the Mac" and "secrets only in protected GitLab
variables"). There is no key anywhere: the `audit` job federates its ID token, as every cloud job does, as
`hub-audit@tacplus-ci.iam.gserviceaccount.com` (the ci stack, `modules/projects/ci/hub-audit.tf`), which only this
project's protected `main` becomes, through the pipeline's own provider.

- **Its rights:** on `tacplus-ci` and `tacplus-dev`, `roles/compute.viewer`, `roles/container.viewer`,
  `roles/monitoring.viewer`, `roles/serviceusage.serviceUsageConsumer`, `roles/secretmanager.viewer` (names and
  versions' metadata, never their values: no accessor) and `roles/cloudquotas.viewer` (the quotas' limits and
  preferences, #88); and (#115) its own custom role `hubAuditRegistries` on each project, which lists the Artifact
  Registry repositories and reads their IAM policies (`artifactregistry.locations.list`,
  `artifactregistry.repositories.get`, `.list` and `.getIamPolicy`) and never downloads an image: no predefined role
  does only that. No write role: `ci/policy.sh` refuses any other role to it in a
  plan (and that custom role any other permission, or on another project), and the module refuses one in its input. And the cluster autoscaler's log alone (#85), once `modules/settings`'
  `autoscaler_log` is `true` (after the host's `roles/logging.configWriter`, above): `roles/logging.viewAccessor` on
  each project, conditioned on `resource.name` being that project's view `hub-audit-autoscaler`, on its `_Default`
  bucket, whose filter is `LOG_ID("container.googleapis.com/cluster-autoscaler-visibility")` and nothing more.
  `ci/policy.sh` refuses any other log grant to it (unconditioned, on another view, or in a binding or a policy
  document) and that view with any other filter; never `roles/logging.viewer`, as a job's output, in the logs, may hold
  a secret (#77).
- **When:** hourly at minute 7, the schedule `audit` on `main` that the gitlab stack makes (`stacks/gitlab/main.tf`), and
  on demand: Run pipeline on `main` with `CLOUD_AUDIT` set to `true`, from the web or the API
  (`glab ci run -b main --variables CLOUD_AUDIT:true`). Either pipeline is the `audit` job alone (the other jobs'
  rules leave it out). The schedule sets no variable, as the project allows pipeline variables to the Owner role only
  (above, Before the first pipeline), which the schedule's owner, the gitlab stack's token user, may not be: the
  rules know it by its description, `audit`. The nightly drift schedule is still the hub's.
- **What it reports** (`ci/hub-audit.sh`), in `audit.json` (for the hub to read) and `audit.md` (the same, as tables;
  also in the job's log):
  - **exposure:** the enabled ingress allow rules open to `0.0.0.0/0` or `::/0` (a disabled one listed, not a finding),
    the VMs with an external IP, the external addresses and what uses each, the load balancers (forwarding rules);
  - **inventory:** every VM (name, machine type, provisioning model, status, created), every node pool (machine, spot,
    its autoscaling's min and max, its nodes now), the disks by type (count and GB), and the network endpoint groups
    (#94: name, zone, size, type, and the Service GKE made each for), so the hub sees when `seatrials-gateway` and
    `seatrials-test-idp` exist, and their endpoints, without gcloud;
  - **quotas:** `CPUS_ALL_REGIONS`, and the region's `CPUS`, `SSD_TOTAL_GB`, `PREEMPTIBLE_CPUS` and `T2A_CPUS`, with
    usage (null where the region lists none); and the region's `CPUS_PER_VM_FAMILY` of C4A and `HDB_TOTAL_GB` (#88),
    their limits from Cloud Quotas (Compute lists neither), with the project's quota preference for each (requested,
    granted, and pending while Google reviews it), their usage the inventory's (Cloud Quotas gives none): the vCPUs of
    the region's C4A VMs not stopped, and the GB of its Hyperdisk Balanced disks;
  - **utilization** over the last hour, the maximum of its 10-minute windows (Cloud Monitoring): each VM's CPU, each GKE
    node's CPU (of its allocatable), and each container's CPU and memory used against its requests in namespace `ci`;
  - **secrets:** their names and their versions' states only;
  - **registries** (#115): every Artifact Registry repository, in every location, its format, and each role's members
    on the repository's own policy: the release registry's writer and readers (below, The release registry) as the
    hub checks them, and each deploy registry's;
  - **scheduling** (#85), through the cluster's API (`roles/container.viewer`; the job runs in the cluster, which alone
    reaches its private endpoint): each spot node, its allocatable CPU and memory against the sum of its pods'
    requests, and each pod on it with its phase, creation, owner (its owner references, or the GitLab job of a runner's
    pod, by URL) and CPU and memory requests; and the pods not scheduled, with the scheduler's reason. What fills a
    spot node is read, not inferred. A pod's spec, its env with it, never leaves the job's temporary directory;
  - **the cluster autoscaler** (#85): its events on the cluster's objects, through the cluster's API (`roles/container.viewer`,
    as above; Kubernetes keeps them about an hour): a pod's `NotTriggerScaleUp` with the autoscaler's reason, or its
    `TriggeredScaleUp` with the group and size it asked for, each with its count, first and last times. And over the
    last 6 hours, from its visibility log through the view
    `hub-audit-autoscaler` alone: each no-scale-up by pool, zone and reason (a pool rejected or skipped, or the
    autoscaler's own reason, a backoff say), its count, first and last times and the pods it left; and each scale-up
    error, joined to the pools its decision tried. The log only once `modules/settings`' `autoscaler_log` is `true`
    (above, Its rights); until then `autoscaler.read` is `false` and `unavailable` says why.

  An API not enabled in a project (GKE's in `tacplus-ci`) is noted in `unavailable`, its list empty. `findings` are
  the exposure findings, `errors` the reads it could not make.
- **Red:** the job fails, its report kept, on an exposure finding (an ingress rule open to `0.0.0.0/0` or `::/0`, a VM
  with an external IP, a registry granting a role to `allUsers` or `allAuthenticatedUsers`) or a read it could not make, so either shows in the pipeline too.
- **Reading it:** the hub reads the latest `audit` artifact:
  `glab api "projects/88513714/jobs/artifacts/main/download?job=audit" > audit.zip` (the zip holds `src/audit/audit.json`
  and `src/audit/audit.md`), or one file, `glab api "projects/88513714/jobs/artifacts/main/raw/src/audit/audit.json?job=audit"`.
  The artifacts are for project members only. GitLab answers these from `main`'s latest *successful* pipeline: a red
  audit's report, or the hour after another pipeline on `main` succeeds (a push's, the nightly drift's: no `audit` job
  in it, so a 404), is read by the job's ID instead:
  `glab api "projects/88513714/jobs?scope[]=success&scope[]=failed&per_page=50"` (the newest job named `audit`), then
  `glab api "projects/88513714/jobs/<id>/artifacts/src/audit/audit.json"`. They are kept 30 days.

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

fleet-seatrials' pipeline user (#117) needs no entry: a job token has its job's user's permissions, and the user that
fleet-seatrials' triggered pipelines run as (the trigger's owner, this stack's token user) is a member of tacplus-dev,
so a Reporter of tacplus-dev/build by inheritance, as is any group member (GitLab refuses a project membership below
an inherited one). The one that could need it is its daily schedule's owner, which the hub makes by hand: a member of
tacplus-dev reads the records; a user of fleet-seatrials alone gets `tacplus-dev/build:<user>`, Reporter, here, or its
scheduled pipelines' reads of the release records get a 404.

**Renewing one:** the drift job's expiry check (`ci/expiry.sh`) reports every `expires_at` of the stacks that is past or
within 30 days, in the drift issue. A commit of a later date renews it; the pipeline applies it.

## The build pipeline

#26 (tacplus-dev/looper#71, #84; tacplus-dev/roadmap
`suggestions/2026-11-06-pin-every-repository-so-the-build-pipeline-and-its-security-checks-run-anywhere.md`, step 2):
the looper's reports and managers get their gates from build jobs in tacplus-dev/build, which this pipeline sets up
(`modules/gitlab/build.tf`, from the gitlab stack's `build`):

- **Its runners** (#35): group runners on, gitlab.com's shared runners off (`gitlab_project.build`, the project adopted
  by its ID, never destroyed, nothing else of it managed). Its jobs are tagged `build`, which only tacplus-dev's group
  runners (the in-cluster ones, below, What runs where) take: with group runners off, every build job waits about 1.5 h and fails
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
- **Its settings** (#82): project variables that `looper-build` reads, written by `apply:gitlab` from the stack's
  `build.variables` (no secret: unprotected, unmasked). `BUILD_GATES_REQUESTS_tacplus` = `3 10Gi 3500m 12Gi` sizes
  tacplus's gates job (`"<cpu> <memory> <cpu limit> <memory limit>"`, tacplus-dev/looper#202), whose gates were
  OOM-killed in the runner's default 8Gi pod: its limits are the runner's ceilings, 3500m and 12Gi (#83: at 2 CPU its
  timing-bound gates slowed and failed), and its requests 3 CPU and 10Gi (#87): a request must fit a c4a-standard-4
  spot node's allocatable (~3920m, ~13.3Gi) after its DaemonSets (metadata server, logging, Dataplane V2, CSI,
  metrics) and the build's helper; at 3500m 12Gi it scheduled on no node, nor on a new one. Only a limit may be the
  ceiling: on an otherwise empty node the gates still burst to it. `ci/policy.sh` refuses, in a plan, any
  `BUILD_GATES_REQUESTS_*` requesting more than 3 CPU or 10Gi. Every other repository's keeps the defaults. It takes
  effect once the looper image pinned in `build.gitlab-ci.yml` carries #202.
- **Its job token allowlist** (#117; tacplus-dev/looper#262, tacplus-dev/fleet-seatrials#82): the projects of
  `build.job_token_readers`, one `gitlab_project_job_token_scope` each, today tacplus-dev/fleet-seatrials, whose deploy
  reads the release records (`release-<repo>/main/record`, `release-tacplus/main/record`, build's generic packages)
  with its own `JOB-TOKEN`. One entry per project, not the whole list: an entry the hub made by hand stays. The job's
  user must also be at least a Reporter of build (above, Memberships).
- **`BUILD_SEATRIALS_TRIGGER_TOKEN`** (#117; tacplus-dev/looper#262), once tacplus-dev/fleet-seatrials#82 is live:
  `build.downstream_triggers`, a pipeline trigger of the project it starts (fleet-seatrials), owned, as build's own, by
  this pipeline's token user, and rotated as build's own (its `rotate_by`). Its token is build's protected, masked
  variable, scoped to one environment, `seatrials-trigger`, a protected environment of build (Maintainers deploy): main's
  `release-report` alone declares it (`environment: {name: seatrials-trigger, action: access}`) and starts seatrials'
  pipeline after a main record moves; no other job of build receives it, the gates job, which runs a repository's own
  code, least of all. The module refuses a downstream trigger scoped `*` or not at all. Until it is there,
  `release-report` logs "seatrials not started" and dev waits for its daily schedule.
- **Its rotation**, every 90 days: the trigger's `rotate_by` in `stacks/gitlab/main.tf` is a date in the commit, never
  computed (the plan is the commit's alone). The drift job's expiry check (`ci/expiry.sh`) reports it from 30 days
  before; a commit of a date 90 days later replaces the trigger: the new one is made and becomes the variable's
  before the old one is deleted, so a build started in between fails at most once.
- **The nightly schedule** (#67): one, on tacplus-dev/build's main at 03:00 UTC, with the input `nightly: true` and no
  `repo`: its pipeline lists the tacplus-dev repositories whose main pins a build image (a `tacplus.lock` or a
  `build.lock`) and runs each one's nightly (a build and the security scans of its main as it is then) in a child
  pipeline of its own, one's failure stopping no other's (tacplus-dev/looper#164). The list is the pipeline's, not
  this repository's: a repository pinned since is in the next nightly with no commit here, and a pin issue asks
  nothing here. It replaced #33's schedule per pinned repository, of which GitLab's 10 schedules a project kept ten
  (#65): the apply of #67 changed looper's into it and deleted the other nine. The module still refuses more than 10
  at plan.
- **The release schedules** (#112; tacplus-dev/looper#252, its README, Release builds by branch): two more on main,
  no `repo` either, so tacplus-dev/build has 3 of its 10. **`release-main`**, at 08:00 UTC, after the nightly, the
  input `release: main`: every pinned repository's main, each building the commit its `main-green` names (the rolling
  check's, tacplus-dev/looper#249), never main's head; a main whose `main-green` is its release already, or that has
  none yet, is skipped. It runs on the nightly's `nightly-slot-<n>` resource groups and `BUILD_NIGHTLY_TAGS`, so a
  nightly still running at 08:00 queues it rather than fails it. **`release-branches`**, every 3 hours at :30
  (`30 1-23/3 * * *`, clear of 03:00, 08:00 and the audit's :07), the input `release: branches`: each `release/X.Y`
  branch whose head is not its release's commit; with nothing new its child pipeline is one job, `nothing-new`. A
  green release publishes `<repo>:<branch>-<commit, 12 hex>` by digest and its `release-report` moves
  `release-<repo>/<branch>/record`. **Build main now** is no schedule: the trigger's API run on main with
  `{"repo": "<repo>", "release": "main"}`. GitLab refuses a pipeline whose input the file does not declare, so the
  module creates a schedule after the build file (`depends_on`); `release` is declared from looper's b6f80ed on, and
  `build_ci_commit` is b40b42b, whose looper image (main-7c1dc4d) carries #252's `looper-build`
  (tacplus-dev/looper#261).
- **The release's publish identity** (#112, the hub's, by hand: tacplus-dev/tacplus#223's registry
  `us-docker.pkg.dev/jody1-328023/tacplus`, its pool, provider and `artifactregistry.writer` binding are in
  jody1-328023 and no stack here holds them). A tag release publishes from the build project's protected tag
  `<repo>/vX.Y.Z`; a branch release from its protected `main`, in the job's environment `registry` (looper-build's
  publish refuses any other ref). The provider behind `GCP_WIF_PROVIDER` (one provider: the job's `id_token` audience
  is built from that one variable) admits both, and on main only `registry`, a protected environment, so no other
  job on main can exchange its token. The hub's steps (`P=jody1-328023`; `POOL` and `PROVIDER` from the variable's
  value, `projects/<number>/locations/global/workloadIdentityPools/POOL/providers/PROVIDER`; G and H as in tacplus-dev/
  looper's README, Credentials):

  ```sh
  # 1. registry a protected environment of tacplus-dev/build, deployable by Maintainers (the schedules' and the
  #    trigger's owner is one); GitLab answers 409 if it is already
  curl -sfH "$H" -X POST "$G/projects/tacplus-dev%2Fbuild/environments" -d name=registry || true
  curl -sfH "$H" -X POST "$G/projects/tacplus-dev%2Fbuild/protected_environments" -H 'Content-Type: application/json' \
    -d '{"name": "registry", "deploy_access_levels": [{"access_level": 40}]}'
  # 2. the condition as it is, kept for the record, then widened
  gcloud iam workload-identity-pools providers describe PROVIDER --project=$P --location=global \
    --workload-identity-pool=POOL --format='value(attributeCondition,attributeMapping)'
  gcloud iam workload-identity-pools providers update-oidc PROVIDER --project=$P --location=global \
    --workload-identity-pool=POOL --attribute-condition='assertion.project_path == "tacplus-dev/build" &&
    assertion.ref_protected == "true" && (assertion.ref_type == "tag" || (assertion.ref_type == "branch" &&
    assertion.ref == "main" && assertion.environment == "registry" && assertion.environment_protected == "true"))'
  # 3. the writer's binding: a principalSet of the whole pool (.../workloadIdentityPools/POOL/*) needs nothing more;
  #    one scoped to an attribute of the tags needs the same principal for main's registry jobs
  gcloud artifacts repositories get-iam-policy tacplus --project=$P --location=us
  ```

  Step 2's condition keeps whatever the old one required beyond these (fold its other clauses in). Then a
  "build main now" of a repository with a `main-green` publishes `<repo>:main-<commit, 12 hex>`.

**Not yet:** nothing is applied before the first pipeline; the builds need the build runner (tags `arm64`, `build`),
which the hub registers for tacplus-dev/looper#84.

## What runs where

#113 (Jody, 2026-11-25: "make sure you have all the dead stuff cut. I dont want a large bill"): tacplus-ci's GitLab
runner pools (`shared`, `build`, `deploy`, `cluster`), their manager VM `runner-manager-*` and its disk, their
registrations, token secrets (`runner-token-<pool>`), accounts, IAM, the manager's binaries' bucket
(`tacplus-ci-runner-bin`) and its SSH rule (`runner-manager-to-workers-ssh`) are gone. By the audit of 2026-11-26 the
always-on shared VM sat at 0.1% CPU, its runner's last job 2026-11-25T09:43Z, and the build pool was at 0, paused.
What runs now:

| What | Where | Runner (tags) |
|---|---|---|
| This repository's pipeline (`cloud`), tacplus-dev/cluster's (`cluster`), the deployments' (`deploy`, fleet-seatrials') | the dev cluster, `ci` namespace, normal pool, protected refs only | in-cluster `infra` (`cloud`, `cluster`, `deploy`), the gitlab stack's |
| tacplus-dev/build's land builds: gates, security | the dev cluster, spot pool | in-cluster `build` (`arm64`, `build`), the hub's (tacplus-dev/cluster) |
| tacplus-dev/build's report builds | the dev cluster, spot pool, below a land's | in-cluster `build-report` (`arm64`, `build-report`) |
| tacplus-dev/build's light jobs (pending, plan, report-pass, report-fail) | the dev cluster, normal pool | in-cluster `build-light` (`arm64`, `build-light`) |
| tacplus-dev/build's nightly fan-out | the dev cluster, spot pool, above the reports, below a land's | in-cluster `nightly` (`arm64`, `build-nightly`, #116) |
| The looper's control jobs; its kicker and plan; its managers | the dev cluster | in-cluster `control`, `kick` (`arm64`, `kick`), `manager` (`arm64`, `manager`) |
| The looper's reports (a looper and its builder per project) | tacplus-ci, outside GitLab | the looper VMs (below, The looper VMs) |
| The rolling check of main, the merger | tacplus-ci, outside GitLab | the reserved machines (below, The reserved machines) |

The tags only the pools carried run nowhere: `autoscale` and `autoscale-16` (the shared pool's, which no job had used
for a day), and `build-docker`, the build pool's (#70), for a release's publish that needs host Docker
(tacplus-dev/looper#172's `BUILD_DOCKER_TAGS`): no in-cluster runner has a Docker socket, so such a publish waits for a
builder image with rootless BuildKit (tacplus-dev/tacplus#315; PROPOSALS.md).

The ci project keeps what the looper VMs and the reserved machines use: the network `runners`, its subnet
`runners-us-central1`, its router and NAT `runners`, still named for the pools (a new name would replace those VMs),
and the Container-Optimized OS pin (`modules/settings`' `cos_arm64_image`). GitLab Runner is no longer built, pinned
or scanned here: tacplus-dev/cluster builds its runner and helper images from upstream itself (cluster#21, #44).

**How it was retired, safely.** One land, two commits: the gitlab stack's drops the registrations, the ci stack's the
rest. Either apply order holds: a token version whose secret is already gone is a 404, which the google provider's
read and delete take as gone. Before the ci stack's plan, `plan:ci` runs `ci/idle-runners.sh`: with the GitLab token,
each pool runner still registered (described `tacplus-ci <pool> ...`) must have no job running and none created in
the last 24 hours; it prints each one's last job, and fails the plan, so no apply, otherwise; with none left it
passes. The manager's `destroy = false` (#48) is kept in its state by OpenTofu, so taking its resource block away would
have forgotten it, not destroyed it, and its VM would have billed on outside every state: a `removed` block with
`destroy = true` (`modules/projects/ci/main.tf`) destroys it, and `tests/ci_plan_test.sh` plans from that state to
show it (and that without the block it is forgotten). The managers made before #46 were forgotten by their own
`destroy = false`; the drift job's live audit (`ci/audit.sh`) names any `runner-*` VM, disk, instance template or
instance group still in a project, which no stack holds: it bills, and goes by hand, on Jody's word, or by an import
and a destroy. The hourly audit's inventory (below, The hub's audit) is the check that none is left: no `runner-*` VM
in tacplus-ci, its CPU use the looper VMs' alone.

### Moving off jody1-328023: the interim runner VMs, for Jody

#11. Made by hand in jody1-328023 before this pipeline ran, and in no stack here and in no audit of this pipeline, so
no apply removes them. If they still exist, they still bill. For Jody to delete once the switch has run green for a
week: since #113's apply (tacplus-ci's pools gone, the jobs on the in-cluster runners, the looper VMs and the reserved
machines; ROADMAP.md, Later: jody1-328023 drained; `decisions/looper-build-vms-2026-11-24.md`, its migration step 7):

- `gitlab-runner-mgr`, the runner manager VM;
- the runner managed instance groups it drives, with their instance templates and VMs (runners 57939705 and 58307468,
  paused);
- then their GitLab registrations, 57939705 and 58307468.

```sh
p=jody1-328023
gcloud compute instances list --project=$p --format='table(name,zone.basename(),status)'
gcloud compute instance-groups managed list --project=$p --format='table(name,location(),targetSize)'
gcloud compute instance-templates list --project=$p --format='table(name)'
# Each runner group, then the manager, then the templates the groups used:
gcloud compute instance-groups managed delete <group> --zone=<zone> --project=$p
gcloud compute instances delete gitlab-runner-mgr --zone=<zone> --project=$p
gcloud compute instance-templates delete <template> --project=$p
```

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

## The release registry

#115 (the hub's approval of its design B, on Jody's standing word, 2026-11-26, tacplus-dev/looper#265;
tacplus-dev/looper#252, tacplus-dev/fleet-seatrials#82): the images tacplus-dev/build's release builds publish by
digest, `<repo>:<branch>-<commit, 12 hex>`, in `tacplus-ci` rather than jody1-328023 (#15 empties it). `modules/projects/ci/releases.tf`, its names in `modules/settings` (`releases`).

- **Where:** the Docker repository `us-central1-docker.pkg.dev/tacplus-ci/releases`, in the region (#120: the host's
  `gcp.resourceLocations` admits it alone; the multi-region `us` of the releases' first home,
  `us-docker.pkg.dev/jody1-328023/tacplus`, failed `apply:ci`). No cleanup policy: a deployment pins a release by digest, and nothing
  it pins is deleted.
- **Its writer:** `release-publish@tacplus-ci.iam.gserviceaccount.com` alone (`artifactregistry.writer`, an
  authoritative binding). Only tacplus-dev/build's publish jobs become it: its protected `main`, in its GitLab
  environment `registry`, through the provider `tacplus-dev-build-release` of the pool `gitlab-com` in `tacplus-ci`
  (condition: the project, a branch, `main`, protected; the binding names the project and environment together, the
  provider mapping `attribute.project_environment`). Not the build cache's provider, which admits any job of build on
  any ref. A publish job federates with an `id_tokens` token whose audience is its provider
  (`https://iam.googleapis.com/projects/<tacplus-ci's number>/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-build-release`),
  as `release-publish`: the ci stack's output `releases` gives the registry, the account and the provider, build's
  variables for a release.
- **Its readers:** each deployment that copies a release by digest into its own deploy registry (the same manifest,
  nothing rebuilt), so that the cluster never pulls across projects: `artifactregistry.reader`, authoritative, to its
  identity in `tacplus-dev`. Today seatrials' alone, `seatrials-deploy@tacplus-dev.iam.gserviceaccount.com`, as its
  `releases` job runs (fleet-seatrials#82). Nobody else reads it.
- **Guarded:** `ci/policy.sh` refuses, in a plan, any other writer, a reader that is not a service account, or any other
  role on it; the module refuses a reader that is not a service account. The audit lists its bindings (above, The hub's
  audit: registries).
- **Until build publishes here:** the releases are still in jody1-328023, which the publish job's `BUILD_REGISTRY` and
  `GCP_WIF_PROVIDER` name; switching a release's publish to this registry and `release-publish` is
  tacplus-dev/looper's half. fleet-seatrials takes the registry from each release record's `image`, so it follows.

## The cluster pipeline

`cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com` is tacplus-dev/cluster's pipeline identity, keyless,
through Workload Identity Federation (pool `gitlab-com`, provider `tacplus-dev-cluster`), condition: tacplus-dev/cluster's
protected `main`. The dev stack gives it, and nobody makes any of it by hand (#18; tacplus-dev/cluster's README, What
the hub does, steps 4 and 7, are this pipeline's):

- **In GCP:** `roles/container.clusterViewer` on `tacplus-dev`, to get the cluster's credentials. No service account
  holds `roles/container.admin`, `roles/owner` or `roles/editor` (`ci/policy.sh` refuses each in any plan, the
  pipeline's own `container.admin`, the host's grant, alone excepted; owner and editor not even the pipeline's, #78):
  each could delete the cluster.
- **In the cluster:** the ClusterRoleBinding `cluster-admin-pipeline` of the ClusterRole `cluster-admin` to the User
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com`, made through the kubernetes provider as this pipeline
  (its `roles/container.admin` from the parent folder covers GKE's RBAC), against the cluster's private endpoint (#79),
  from the `infra` runner's job pod in the cluster. The provider's token is
  ephemeral (`ephemeral "google_client_config"`): the plan and the apply each open their own, and none is in the saved
  plan or the state. On a plan before the cluster exists, or of its replacement, the provider's endpoint is known only
  after apply, and the binding is made once the cluster is; a cluster rebuilt by hand loses it, and the drift plan
  shows it to be made again. The drift job's plan of `dev` reads it from the cluster.
- **The runners' token secrets:** `gitlab-runner-build`, `gitlab-runner-control`, `gitlab-runner-infra` (#64),
  `gitlab-runner-kick` (#81), `gitlab-runner-build-report` (#93), `gitlab-runner-build-light` (#100),
  `gitlab-runner-manager` (#106) and `gitlab-runner-nightly` (#116),
  us-central1, created empty, one per runner of tacplus-dev/cluster's `gitlab-runner/runners/`, whose `tacplus.token`
  names a version of each. Only `cluster-admin-pipeline` reads them (`secretAccessor`); only the dev stack's
  `runner_token_adders` add versions by hand (`secretVersionAdder`, which reads none): authoritative bindings, so a
  grant added by hand is drift. The adders are the protected GitLab variable `GCP_RUNNER_TOKEN_ADDERS`, members
  comma-separated (`user:`, `group:`, `serviceAccount:` and an email), which `ci/lib.sh` gives the stack and refuses
  unless each is a member; unset or empty, nobody adds versions. Their accounts are the host's directory's, which no
  file here names (Jody's today: the hosting note, above). For `build` and `control`, the hub registers the runner
  through GitLab's API and pipes its token into a new version as that account (`gcloud secrets versions add
  gitlab-runner-build --project=tacplus-dev --data-file=-`); a new token is a new version, and a pull request in
  tacplus-dev/cluster naming it. The dev stack's output `runner_tokens` names the eight secrets.
- **The `infra` runner (#64; tacplus-dev/cluster#25, its README, The infra runner):** the in-cluster runner of the
  cloud, cluster and deploy pipelines, which let the runner VMs go (#113). The **gitlab stack registers it** (`stacks/gitlab/main.tf`,
  `infra`), and nothing else does: a tacplus-dev group runner, tags `cloud`, `cluster` and `deploy` and no other, "run
  untagged jobs" off, protected refs only (`ref_protected`), registered paused and **unpaused at the switch-over**
  (#66, below); and it writes the runner's authentication
  token as `gitlab-runner-infra`'s **version 1** (the first version of the empty secret the dev stack made, the version
  cluster's `infra.yaml` names), as this pipeline (its `roles/secretmanager.admin` from the parent folder). **The token never leaves the pipeline:** GitLab gives it to the stack's apply, which writes it to
  Secret Manager, where `cluster-admin-pipeline` alone reads it into the runner's Secret; it is in the gitlab stack's
  state (PROPOSALS.md, Secret values out of plans and state), in no output, log or plan file, and no person or agent
  types it. A re-registration (the runner replaced) writes a new version and disables the old: its number moves, and a
  pull request in tacplus-dev/cluster moves `tacplus.token` to it. **The switch-over** (#66; cluster's README): once
  `apply:gitlab` had written the token and cluster's pipeline had applied `infra`, one commit to `stacks/gitlab/main.tf`
  unpaused `infra` and paused the `cluster` and `deploy` pools' runners, which carry the same tags, so no job goes to a
  VM and a green pipeline is `infra`'s; then one cloud and one cluster pipeline green on it; #113 removed the pools'
  runners and VMs. `paused` is the stack's: a runner paused or unpaused in GitLab's UI is drift the next
  `apply:gitlab` undoes. Pausing stops new pickups, not a running job, so the `apply:gitlab` that pauses the `cluster`
  pool finishes on it. Since then the `cloud`, `cluster` and `deploy` jobs run inside the cluster they apply: a plan
  replacing the cluster, its normal pool or the `ci` namespace stops its own job mid-apply. **Break-glass, if `infra`
  takes no job** (its token, image or node): the `cloud` jobs, a revert's apply among them, stay pending. Until #113 the
  hub unpaused the `cluster` pool's runner by hand and landed the revert on it; with the pools gone, `infra` has no
  stand-in, so its repair is tacplus-dev/cluster's pipeline (its own runner) or, failing that, Jody's break-glass
  (below, Break-glass).
- **The `kick` runner (#81; tacplus-dev/cluster#36, its `gitlab-runner/runners/kick.yaml`):** the in-cluster runner
  of the looper's kicker and plan alone (tacplus-dev/looper's `.control` jobs), so one always runs while `control`'s
  slots are full of reports. The gitlab stack registers it (`stacks/gitlab/main.tf`, `kick`) and writes its token as
  `gitlab-runner-kick`'s **version 1**, as it does `infra`'s: a tacplus-dev group runner, tags `arm64` and `kick` and no
  other, "run untagged jobs" off, any ref (the kicker and plan run on main's schedules), unpaused. Not `control` among
  its tags: GitLab gives a runner every job whose tags are a subset of its own, so a runner holding `control` would
  take the reports too and fill up as `control` does; `control`, lacking `kick`, never takes `kick`'s jobs. No job
  carries `kick` until tacplus-dev/looper tags `.control` `arm64, kick`, after cluster's pipeline has applied the
  runner. `apply:gitlab` does not wait on `apply:dev` (it needs no control plane: the break-glass above): if it reaches
  the version before `apply:dev` has made the secret, it fails after registering the runner, and a retry writes it.
- **The `build-report` runner (#93; tacplus-dev/cluster#42, its `gitlab-runner/runners/build-report.yaml`):** the
  in-cluster runner of the report builds alone (every build of tacplus-dev/build but a manager's land, which
  tacplus-dev/looper#209 starts with `report: true` on tacplus-dev/build's `BUILD_REPORT_TAGS`). Its jobs are `build`'s,
  on the spot pool, but at cluster's PriorityClass `build-report` (-1, never preempting), below a land's build's pods,
  so a land's gates pod preempts a report build instead of waiting for one to end. The gitlab stack registers it
  (`stacks/gitlab/main.tf`, `build-report`) and writes its token as `gitlab-runner-build-report`'s **version 1**, as it
  does `kick`'s: a tacplus-dev group runner, tags `arm64` and `build-report` and no other, "run untagged jobs" off, any
  ref, unpaused. Not `build` among its tags: GitLab gives a runner every job whose tags are a subset of its own, so a
  runner holding `build` would take a land's jobs too, at the report builds' priority, where they could be preempted;
  `build`, lacking `build-report`, never takes a report's. No job carries `build-report` until the hub sets
  `BUILD_REPORT_TAGS` to `arm64, build-report`, after cluster's pipeline has applied the runner, whose `apply` needs
  this version to exist (cluster's `ci/runner-tokens.sh` refuses a runner whose version it cannot read). As `kick`'s,
  if `apply:gitlab` reaches the version before `apply:dev` has made the secret, a retry writes it.
- **The `build-light` runner (#100; tacplus-dev/cluster#51, its `gitlab-runner/runners/build-light.yaml`):** the
  in-cluster runner, on the normal pool, of tacplus-dev/build's light jobs alone: `pending`, `plan`, `report-pass` and
  `report-fail`, which run `looper-build` in the looper image for seconds to a minute and need no spot node, no build
  image and no whole node. On the build runner they held its slots: on 2026-11-23 at 10:3xZ 42 `pending` and 42
  `plan` jobs waited behind its `concurrent: 6`, held by four `security-tacplus` jobs and two `gates`, and
  fleet-seatrials' land candidate waited 77 minutes at its first job. The gitlab stack registers it
  (`stacks/gitlab/main.tf`, `build-light`) and writes its token as `gitlab-runner-build-light`'s **version 1**, as it
  does `kick`'s: a tacplus-dev group runner, tags `arm64` and `build-light` and no other, "run untagged jobs" off, any
  ref, unpaused. Not `build` among its tags: GitLab gives a runner every job whose tags are a subset of its own, so a
  runner holding `build` would take the gates and security jobs onto the normal pool; `build`, lacking `build-light`,
  never takes a light job. No job carries `build-light` until tacplus-dev/looper's `ci/build.gitlab-ci.yml` tags the
  light jobs so (tacplus-dev/looper#224) and this repository bumps its copy to that commit, after cluster's pipeline
  has applied the runner. As `kick`'s, if `apply:gitlab` reaches the version before `apply:dev` has made the secret, a
  retry writes it.
- **The `manager` runner (#106; tacplus-dev/cluster#60, its `gitlab-runner/runners/manager.yaml`):** the in-cluster
  runner, on the normal (always-on) pool, of the looper's managers alone (tacplus-dev/looper#236's `.manager`). On the
  `control` runner they waited for its slots behind the reports: on 2026-11-24 at 19:59Z its 17 were full and five
  managers were pending, and while a manager waits nothing merges in its repository. The gitlab stack registers it
  (`stacks/gitlab/main.tf`, `manager`) and writes its token as `gitlab-runner-manager`'s **version 1**, as it does
  `kick`'s: a tacplus-dev group runner, tags `arm64` and `manager` and no other, "run untagged jobs" off, any ref,
  unpaused. Not `control` among its tags: GitLab gives a runner every job whose tags are a subset of its own, so a
  runner holding `control` would take the reports too and fill up as `control` does; `control`, lacking `manager`,
  never takes a manager. This applies before cluster's pipeline renders the runner, whose `apply` needs the version to
  exist (the lesson of tacplus-dev/cluster#51); no job carries `manager` until tacplus-dev/looper tags its managers so
  (tacplus-dev/looper#236), after cluster's pipeline has applied the runner. As `kick`'s, if `apply:gitlab` reaches the
  version before `apply:dev` has made the secret, a retry writes it.
- **The `nightly` runner (#116; tacplus-dev/cluster#46, its `gitlab-runner/runners/nightly.yaml`):** the in-cluster
  runner, on the spot pool, of the nightly fan-out's jobs alone (tacplus-dev/build's `BUILD_NIGHTLY_TAGS`). Its jobs
  are `build`'s (the same pool, security context and ceilings: a nightly's CodeQL asks 3500m / 12Gi,
  tacplus-dev/looper#189), but at cluster's PriorityClass `build-nightly` (0, preempting): above the report builds'
  `build-report` (-1) and below a land's build's `build` (1). On `build`'s tags, on 2026-11-21/22, 10 of 31
  repositories' security jobs waited Pending behind the report builds, failed `runner_system_failure` and published
  nothing. The gitlab stack registers it (`stacks/gitlab/main.tf`, `nightly`) and writes its token as
  `gitlab-runner-nightly`'s **version 1**, as it does `kick`'s: a tacplus-dev group runner, tags `arm64` and
  `build-nightly` and no other, "run untagged jobs" off, any ref, unpaused. Not `build` among its tags: GitLab gives a
  runner every job whose tags are a subset of its own, so a runner holding `build` would take a land's jobs too, at the
  nightly's priority. This applies before the hub re-pins cluster to a commit with cluster#46, whose `apply` needs the
  version to exist (`ci/runner-tokens.sh` refuses a runner whose version it cannot read); no job carries
  `build-nightly` until tacplus-dev/looper#220 sets `BUILD_NIGHTLY_TAGS`, after cluster's pipeline has applied the
  runner. As `kick`'s, if `apply:gitlab` reaches the version before `apply:dev` has made the secret, a retry writes it.
  Interim: it and its secret go with the spot pool when the merge train retires (#114).
- **Its registry (#45; tacplus-dev/cluster#21, the hub's decision (1), 2026-11-12):** the Artifact Registry Docker
  repository `us-central1-docker.pkg.dev/tacplus-dev/ci-images`, for the GitLab Runner and helper images
  tacplus-dev/cluster builds itself (crane, no container runtime) and its `gitlab-runner/pin.yaml` names by digest.
  Private: `cluster-admin-pipeline` alone holds `roles/artifactregistry.writer` on it, the nodes' account `gke-nodes`
  alone `roles/artifactregistry.reader` (the runner Deployment and its job pods pull through the nodes), both
  authoritative bindings on the repository only, so a grant added by hand is drift. No cleanup policy: no image a pin
  names is deleted. The dev stack's output `cluster_pipeline` names it (`registry`).

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
| `tacplus-admiral` | 5853599 | 184144753 | the Admiral alone, as the account `admiral` (#84; below, The Admiral's credentials): no GitLab job |

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

## The Admiral's credentials

#84; tacplus-dev/admiral#5 (Jody's option A, 2026-11-20). The Admiral, a fleet service in `/system` of the dev
cluster's fleet (seatrials), files issues on GitHub as the `tacplus-admiral` App and in the triage project on GitLab.com
holding no long-lived secret in its config: it federates its own identity, the kernel-signed ES256 JWT whose `sub` is
its SPIFFE ID (`ServiceManager::token_for_external(aud)`), into one service account, which has KMS sign its App's JWT
and reads the GitLab token at run time. Its names are `modules/settings` (`admiral`); the dev module's `admiral.tf`
makes the federation, the ci module's `admiral.tf` the rest.

- **The federation** (`tacplus-dev`): the pool `fleet-kernels`, for fleet services by their kernel's identity (not
  GitLab's jobs, not GKE Workload Identity), and in it the provider `seatrials`, an OIDC provider for the seatrials
  kernel's issuer `https://seatrials.tacplus.dev` (its keys by discovery, as llmproxy's Anthropic issuer, #34), mapping
  `google.subject` to `assertion.sub` and admitting `spiffe://tacplus.dev/system/services/admiral` alone. One issuer URL,
  never a pattern: the trust domain (`tacplus.dev`, seatrials' `spiffe_prefix` since fleet-seatrials#16, #119) is a
  fleet's setting, not a key, so another fleet may mint that SPIFFE ID and another fleet's Admiral is another provider,
  a commit. The audience is the provider's own (GCP's default):
  `//iam.googleapis.com/projects/<tacplus-dev's number>/locations/global/workloadIdentityPools/fleet-kernels/providers/seatrials`.
  The issuer must stay publicly discoverable; if it ever is not, the provider takes its JWKS inline (`jwks_json`), and
  a kernel key rotation becomes a commit.
- **The account** `admiral@tacplus-ci.iam.gserviceaccount.com`: only
  `principal://iam.googleapis.com/projects/<tacplus-dev's number>/locations/global/workloadIdentityPools/fleet-kernels/subject/spiffe://tacplus.dev/system/services/admiral`
  becomes it (`roles/iam.workloadIdentityUser`, authoritative). It is in `tacplus-ci`, beside the keys, whose project
  enables Cloud KMS (`tacplus-dev` does not).
- **The key** `tacplus-admiral`, a `github_apps` key like the others (above, The GitHub Apps' keys: import-only, no
  version, `prevent_destroy`, its import job `tacplus-admiral-import`, imported by `GCP_KMS_KEY_IMPORTERS`'s members),
  on which `admiral` alone is `roles/cloudkms.signerVerifier` (as #84 asks: it signs, and may read the public key),
  authoritative; no GitLab job signs with it (the module refuses a `github_apps` signer on it).
- **The secret** `admiral-triage-gitlab` in `tacplus-ci` (us-central1), made with no version: `admiral` alone reads
  it (`secretAccessor`); the members of the protected GitLab variable `GCP_ADMIRAL_SECRET_ADDERS` (comma-separated, as
  `GCP_RUNNER_TOKEN_ADDERS`; `ci/lib.sh` gives them to the ci stack as `admiral_secret_adders` and refuses one that is
  not a member) alone add its versions (`secretVersionAdder`: add, never read). Unset or empty: nobody adds one.
  Authoritative bindings: a grant added by hand is drift.
- **Outputs:** the ci stack's `admiral`, the Admiral's Config, none of it secret: `wif_provider` and `audience`, the
  provider's name and the audience its kernel's token is for; `subject`; `service_account`; `key` and `key_version`
  (`cryptoKeyVersions/1`, once imported); `secret` (`projects/tacplus-ci/secrets/admiral-triage-gitlab`); `app_id`
  and `installation_id`. The dev stack's `admiral` gives the provider too.

**Jody's steps**, once `apply:dev` then `apply:ci` of the commit that makes them have run, with `GCP_KMS_KEY_IMPORTERS`
and `GCP_ADMIRAL_SECRET_ADDERS` set to his account before that pipeline (the import job lives three days from then):

1. The App's key: on the `tacplus-admiral` App's page (app 5853599, Settings, Private keys), Generate a private key,
   and import it at once:

   ```sh
   k=tacplus-admiral
   openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER -in $k.private-key.pem -out $k.der
   gcloud kms keys versions import --import-job=$k-import --keyring=looper --location=us-central1 --project=tacplus-ci \
     --key=$k --algorithm=rsa-sign-pkcs1-2048-sha256 --target-key-file=$k.der   # version 1
   shred -u $k.private-key.pem $k.der
   ```

   Then `GCP_KMS_KEY_IMPORTERS` is cleared, as for the other keys.
2. The GitLab token, a dedicated user's personal access token (#89; Jody's decision, 2026-11-21, admiral#5): GitLab.com
   offers project and group access tokens and service accounts on Premium only, and the triage project's group is on
   Free. Its reach is a project access token's all the same: one project, Reporter.
   1. The user: sign up on GitLab.com as `tacplus-admiral`, with its own email (a plus-address of Jody's, so the
      mail domain needs no new account: the hosting note) and Jody's password. By hand: GitLab.com has no API for a
      sign-up.
   2. Its membership: on the triage project (Manage, Members), invite `tacplus-admiral` as Reporter, and nothing
      else: no other project, no group. A manual invite, not a pipeline: a pipeline would
      need a long-lived GitLab credential of its own able to add members, more exposure than one invite.
   3. Its token: signed in as `tacplus-admiral` (User settings, Personal access tokens), a token with scope `api`, its
      expiry at most a year (GitLab's cap); then, its value never in a file or a shell's history:

      ```sh
      gcloud secrets versions add admiral-triage-gitlab --project=tacplus-ci --data-file=-   # paste, then Ctrl-D
      ```

   A rotation is step 3 again, before the token expires: a new token on that user, a new version, then the old token
   revoked on GitLab (GitLab.com has no inbound federation, admiral#5, so this token is the one long-lived secret, of
   one user who is a Reporter of one project).

Nothing of it is tested end to end here: the first exchange is the Admiral's (admiral#5), after both steps.

## The looper VMs

#108; `decisions/looper-build-vms-2026-11-24.md` (tacplus-dev/roadmap). One looper+builder per project, outside the
deployment cluster, in `tacplus-ci` (`modules/projects/ci/looper-vms.tf`; the projects in `modules/settings`'
`looper_vms`, tacplus first). Each is a zonal instance group `looper-vm-<repo>`, at 0 until the kicker
(tacplus-dev/looper#241) sizes it to 1, of one C4A VM (spot or not, its Hyperdisk Balanced boot disk only a cache) on
stock Container-Optimized OS for arm64 (`modules/settings`' `cos_arm64_image`). The VM has no external address (NAT), no SSH key, the
project's keys blocked and no firewall rule to it; its window is Cloud Logging. One cloud-init for every project
(`files/looper-vm-cloud-init.yaml`, `files/looper-vm.sh`, tested by `tests/looper_vm_test.sh`) reads the repository,
the image (by digest; empty: nothing runs) and the VM's group from the metadata, pulls the image and runs it with the
cache and the container socket; when the container exits 0 (idle), the VM sizes its own group to 0. Before the
container starts, the containers it starts through the socket (the builds, on Docker's bridge) are cut off from the
VM's metadata server, and so from its account's tokens (#111; the panel's finding 5): one rule in `DOCKER-USER` refuses
every TCP port of 169.254.169.254 but DNS's; if it cannot be made, nothing starts.

The VM's account `looper-vm-<repo>`, keyless, writes logs, reads the secret `looper-model-token` and no other, signs
with `tacplus-looper`'s key (never `tacplus-manager`'s), and resizes its own group alone (the custom role
`looperVmResizer`: an instance group's get and update, conditioned on the group's name). The kicker's jobs (the looper
project's environment `kicker`) hold the same role on the `looper-vm-` groups alone. `looper-model-token` is made with
no version and no adder: Jody adds its value out of band (`gcloud secrets versions add looper-model-token
--project=tacplus-ci --data-file=-`).

## The reserved machines

#111; `decisions/agentic-dev-flow-2026-11-25.md` (tacplus-dev/roadmap, the panel's items 4, 5 and 8; capacity approved
by Jody 2026-11-25). In `tacplus-ci` (`modules/projects/ci/reserved-vms.tf`; `modules/settings`' `reserved_vms`):
`check-tacplus`, the rolling check of tacplus's main (c4a-standard-8 with 100 GB of Hyperdisk Balanced, until the full
gates are measured on it; more only if they need it, so its gate groups run side by side), `check-tacplus-dev`, the
org's other repositories' (t2a-standard-4, 100 GB pd-balanced), and `merger`, the merger's control machine
(t2a-standard-1, 30 GB pd-balanced). All three run the looper image of `main-c0d53ba` by digest (tacplus-dev/looper#249,
#251). Each is a zonal instance group of its own name, of one on-demand VM (never spot), its boot disk its own cache;
not a looper VM (no model token, not the reports' key, no kicker) and not the GitLab build project. The sizes are what
tacplus-ci's quotas admit without a raise (Jody, 2026-11-25; `ci_cpus`, `ci_disks`: C4A 24 of 24 with the looper VMs,
T2A 5 of 24, 29 CPUs of 32), right-sized later from the rolling check's measurement (PROPOSALS.md). The OS, the network,
the SSH rules and the cloud-init are the looper VMs'; the metadata's `looper-role` makes it run `looper-vm check` (with
the container socket, its builds cut off from the metadata server) or `looper-vm merger` (no container socket: it
runs no project code), and `looper-env` gives its container its app's IDs and the key ring.

Builders run only while used (Jody, 2026-11-25). A check machine's group is 0..1, never sized by a plan: when every
check on it ended idle (`looper-vm check` exits 0), its VM has its group stop it (`stopInstances`, `files/looper-vm.sh
post`); the stopped VM keeps its boot disk, the cache, and costs only that. The merger's machine is the one always-on
machine, at 1 while it has an image, sized by the plan alone, and the small orchestrator: every minute
(`files/looper-vm.sh kick`, beside the merger's container) it asks `looper-check needed` of each check machine whose
group runs no VM (in the looper image, as the merger's app: has main's head no verdict of the check, or a pending
one?) and starts it (`startInstances`, or `resize` to 1 for its first VM). The drift's pool check does not report a VM
its group means to keep stopped.

Each machine's account, its own name, keyless, writes logs and signs with its machine's GitHub App key alone:
`tacplus-manager`, the identity that merges today, until Jody makes `tacplus-check` and `tacplus-merger` (the hub, for
Jody, 2026-11-25: a setting, no new App to go live; PROPOSALS.md). Its signers are the managers' jobs and these three
accounts; never a looper VM's (the module refuses `looper_vm_app_key = "tacplus-manager"`, and a test checks the
binding). The build containers on the check machines cannot reach their metadata server, so a report still cannot
mint the check's status or a merge. The checks share one key, whose login the merger's gate trusts
(`LOOPER_CHECK_LOGIN`); a merger's own key, once it has one, no job, account or other machine may sign with. A check
machine's account may also stop its own group's VM, and the merger's start the check machines' (`looperVmResizer`,
conditioned on the groups' names). Until the check has been seen working, the looper VMs' reports still land through
the manager (`LOOPER_VM_MR=0`; PROPOSALS.md).

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
  them, `secretVersionAdder`, `secretAccessor` and `viewer` (authoritative bindings): it adds versions, reads them and
  lists them (#68: the cert job finds the latest enabled version by listing them). Their values
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
  conditioned on `resource.name == "projects/tacplus-dev/zones/us-central1-a/clusters/dev"`: `get-credentials` on
  `dev` and nothing else of GKE. That is a zonal cluster's name as GKE checks it; the `locations/` form is a regional
  cluster's, and never matched `dev` (#71: `container.clusters.get` 403). Its rights inside the cluster are
  tacplus-dev/cluster's (`deployments.yaml`).
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
  `roles/storage.objectAdmin` and `roles/storage.legacyBucketReader` (#68: Cloud Build refuses to run a build as an
  account without `storage.buckets.get` on its logs bucket, which objectAdmin lacks), nobody else a role.
- **Its environment accounts** (`environment_accounts`): by GitLab environment, a service account only its project's
  jobs in that environment, on protected `main`, may become, with the cluster's credentials and no other role. Its
  provider maps `attribute.project_environment` to the job's project and environment joined by `:` (a GitLab project
  path has no `:`; a job without an environment maps to `<project>:`), and the account's `workloadIdentityUser`
  binding names `attribute.project_environment/<project>:<environment>`: the pool `gitlab-com` is shared by
  tacplus-dev's projects, so the environment alone would admit another project's job in an environment of that name.
  An environment account is never the deployment's identity or its builds' account (the module refuses it). Besides,
  it may own a certificate (above, Certificates) and **secrets of its own** (`environment_secrets`, #32): by environment,
  secret IDs (us-central1, made with no version) whose versions only it and the deployment's identity add, read and
  list (`secretVersionAdder`, `secretAccessor` and `viewer`; #68: seatrials' own jobs read the test IdP's seeds; #73:
  its test-idp job, as `seatrials-deploy`, stores them on the first run), authoritative bindings; reading `latest`
  tells its job whether one exists yet. They replace GitLab variables a job would write with a token: gitlab.com Free
  has no project access tokens (as #28). Their values are never in this repository, a plan or the state.

| Deployment | Registry | Build bucket, builds' account | Environment accounts |
|---|---|---|---|
| `seatrials` | `us-central1-docker.pkg.dev/tacplus-dev/seatrials` | `gs://tacplus-dev-seatrials-build` (7 days), `seatrials-build` | `test-idp`: `test-idp-deploy` (the test IdP, a pod in the cluster), its certificate and its secret `test-idp-seeds` (the seeds its passwords are derived from, replacing `TEST_IDP_GITLAB_TOKEN`) |

The output `deployments` names each one's `registry`, `build` (`bucket`, `sa`), `environment_accounts` (by
environment, the service account's email) and `environment_secrets` (by environment, the secrets' names).

### The fleet's CA, crypto file and root credential

#28 (Jody's option D, 2026-11-08; fleet-seatrials#44): a deployment's fleet CA and crypto file, and (#105,
fleet-seatrials#77) its root credential's private key, are made once by its
project's `init-secrets` job and live in Secret Manager, as its certificate does: no GitLab variable holds them, and no
GitLab token or bot user writes them (gitlab.com Free has no project access tokens; `decisions/secrets-by-pipeline-2026-11-05.md`).
From the `deployments` entry's `init_secrets` (`modules/projects/dev/fleet-secrets.tf`):

- **The secrets** `fleet-ca-<deployment>`, `fleet-crypto-<deployment>` and `fleet-root-cred-<deployment>` (the root
  credential's private key; its public half is the deployment's `operator.yaml`'s), us-central1, made with no version:
  the job adds the first. Their values are never in this repository, a plan or the state.
- **The job's account** `<init_secrets.account_id>`: only its project's jobs in the GitLab environment
  `<init_secrets.environment>`, on protected `main`, may become it (its provider's condition, and the
  `workloadIdentityUser` binding on `attribute.project_environment/<project>:<environment>`, as an environment
  account's). It holds `secretVersionAdder` (adds a version, reads none) and `viewer` (whether a version exists, so that
  a second run skips; never a value) on the three secrets, and no role on the project. The module refuses it as any
  other of the deployment's accounts, and its environment as any other of the deployment's environments.
- **The reader:** the deployment's identity alone holds `secretAccessor` on them. All three bindings are authoritative:
  a grant added by hand is drift.

Where each of a deployment's secrets lives, and who writes and reads it:

| Secret (tacplus-dev, us-central1) | What | Adds versions | Reads |
|---|---|---|---|
| `tls-seatrials` | the certificate chain and its key | `seatrials-deploy` | `seatrials-deploy` |
| `acme-account-seatrials` | its ACME account's key | `seatrials-deploy` | `seatrials-deploy` |
| `fleet-ca-seatrials` | the fleet's CA | `seatrials-init-secrets` (fleet-seatrials' jobs in `init-secrets`) | `seatrials-deploy` |
| `fleet-crypto-seatrials` | the fleet's crypto file | `seatrials-init-secrets` (fleet-seatrials' jobs in `init-secrets`) | `seatrials-deploy` |
| `fleet-root-cred-seatrials` | the fleet's root credential's private key | `seatrials-init-secrets` (fleet-seatrials' jobs in `init-secrets`) | `seatrials-deploy` (fleet-seatrials' client-steps job) |
| `google-signin-seatrials` | its Google sign-in (OAuth web) client: the client JSON the Console downloads | Jody, by hand in the Console (`GCP_GOOGLE_SIGNIN_ADDERS`): once when the client is made, the bootstrap step, and at each rotation; Google offers no API that makes a web client or its secret | `seatrials-deploy` (fleet-seatrials' `apply` and `signin-secrets` jobs) |

The output `deployments` names each one's `fleet_secrets` (`ca`, `crypto`, `root_cred`, the job's `environment` and
its `sa`, the `GCP_SERVICE_ACCOUNT` its job impersonates through the deployment's `GCP_WIF_PROVIDER`).

### The Google sign-in client

#37 (Jody, 2026-11-09; fleet-seatrials#46): a deployment's Google sign-in (OAuth web) client is in `tacplus-dev`, and its
secret in Secret Manager, which its deploy jobs read through WIF; never a GitLab variable. Google has no public API that
makes a web client or its secret (IAP's OAuth Admin API was shut down on 2026-03-19), so a person adds its versions: no
pipeline identity does. From the `deployments` entry's `google_signin` (`modules/projects/dev/google-signin.tf`):

- **The secret** `google-signin-<deployment>`, us-central1, made with no version. Its value is never in this repository,
  a plan or the state.
- **Who makes the client and adds versions:** the members of the protected GitLab variable `GCP_GOOGLE_SIGNIN_ADDERS` (comma-separated, as
  `GCP_RUNNER_TOKEN_ADDERS`; `ci/lib.sh` gives them to the dev stack as `google_signin_adders` and refuses one that is
  not a member), Jody's account today (the hosting note, above): `secretVersionAdder` on the secret alone, which adds
  versions and reads none, and `roles/oauthconfig.editor` on the project `tacplus-dev` (#56), which Google Auth
  Platform needs to make the client's branding and the client (`clientauthconfig.brands.create`,
  `oauthconfig.verification.update`): a member binding, not authoritative. Unset or empty, nobody adds them.
- **The reader:** the deployment's identity alone holds `secretAccessor` (fleet-seatrials' `apply` and `signin-secrets`
  jobs). Both bindings are authoritative: a grant added by hand is drift.

**Jody's step**, once when the client is made (the bootstrap) and at each rotation: in the Console (Google Auth
Platform: *Branding* once, then *Clients*) make or rotate the web client, download its JSON, and add it as the secret's
next version, in the Console's Secret Manager page of `google-signin-seatrials` (New version, upload the file) or with
gcloud:

```sh
gcloud secrets versions add google-signin-seatrials --project=tacplus-dev --data-file=client_secret.json
shred -u client_secret.json
```

Then fleet-seatrials' pipeline reads it, checks it with Google and installs it (its `docs/deploy-pipeline.md`, The Google
sign-in client); its `signin-secrets` job's log says `google: the client secret from the secret google-signin-seatrials`.
`secretVersionAdder` lists no secret and shows no version: the Console page is reached by its link
(`https://console.cloud.google.com/security/secret-manager/secret/google-signin-seatrials/versions?project=tacplus-dev`)
when the account holds no Secret Manager role on `tacplus-dev`, and gcloud needs none. The output `deployments` names each one's
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
(`gcloud compute network-endpoint-groups list --project=tacplus-dev`), a commit sets `ready = true` and `apply:dev` adds it. `test-idp` is ready (its NEG made by fleet-seatrials' first
test-idp run, 2026-11-17; #42); `gateway` is not yet.

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
  The refusal names each attribute that differs, its value in the Console and in the config (a sensitive one only by
  name), as the plan's text is printed only once the policy passes; not what the provider computes (the rule's
  `workspace_ids`). The second live plan (2026-11-13) listed seatrials' descriptions, its rule's audience
  (`https://api.anthropic.com`) and token lifetime (600 seconds): they are in `modules/settings` as the Console holds them.
  seatrials' rule was narrowed to `workspace:inference` that way, in the commit after its adoption (Jody, 2026-11-10:
  llmproxy calls inference only): an update in place, with the same ID.
- **The membership is made, not adopted:** a federated token acts in a workspace other than the organization's default
  only once its account is an explicit member of it (the provider's `anthropic_service_account_workspace`). seatrials'
  hand-made account was none: the first live plan (2026-11-12) found no membership to import, its workspace access
  only the implicit default-workspace one every account has. So the stack makes it, the one write of the adoption's
  apply; it has no ID llmproxy names, and one removed in the Console is made again by the next apply.
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
  and the pipeline's credential path (`tests/anthropic_plan_test.sh`): the adoption with no change and the membership
  made, a Console edit planned back, a membership removed in the Console made again, an archived identity refused, a widened bootstrap rule reported.

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
