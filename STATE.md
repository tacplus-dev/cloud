# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-04 by the looper (#13).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.5` by digest (v2.5.11's, #10); OpenTofu 1.13.2, providers `google` 8.9.0 and `gitlab` 19.5.0 (lock
  files), tflint 0.65.0 (google ruleset 0.41.0), shellcheck 0.11.0, and the security job's gitleaks v8.30.1, OSV-Scanner v2.7.0,
  govulncheck v1.1.4 (built from their modules with go1.27.3) and Trivy 0.76.1, all pinned by checksum (`ci/tools.sh`). The `gitlab`
  provider is our own reproducible build of its v19.5.0 tag with go1.26.10 and x/net v0.62.0 (`ci/gitlab-provider.sh`,
  #3), installed only from `bin/providers` (`ci/tofurc.sh`) and locked by its own hashes.
- **Works (#1):** `bootstrap/bootstrap.sh` (the folder and project `bootstrap`, the state bucket,
  `cloud-admin-pipeline` with its rights and its WIF from `tacplus-dev/cloud`'s protected main, the empty secrets;
  idempotent, refuses what differs, `--dry-run`; reads a folder listed by its bare ID as gcloud now lists it, #14); the stacks `folder` (folders `ci` and `dev`, readers), `ci` (runner manager VM, the arm64 pools as MIGs (#5, below), runner token secrets, the build
  cache, import-only KMS key for the reader app), `dev` (GKE Axion cluster, private COS nodes in a normal and a spot pool (#7, below), `dev.tacplus.dev` zone,
  `cluster-admin-pipeline` for tacplus-dev/cluster) and `gitlab` (this project's protected main, environments and
  variables from Secret Manager by version; the pools' runners, registered paused); the GitLab pipeline (checks on every
  push, plan per stack saved, apply of exactly that plan automatically on main, nightly drift filing an issue, never
  applying); `ci/policy.sh` (no service-account key, nothing public, nothing a commit does not fix) on the source and on
  every plan, and the network rules on every plan (#7, below). Tests green (`ci/lint.sh all && ci/checks.sh`), here and in the CI image: each stack's plan against mock
  providers, the pipeline's rules, the plan/apply script, the policy, and the bootstrap against a stub gcloud.
- **In a folder handed to it (#8):** no organization of its own: everything is under a parent folder the host
  organization hands over (README, What the host organization provides, and its hosting note), whose
  numeric ID is an input, `bootstrap/bootstrap.sh --folder` and the protected GitLab variable `GCP_PARENT_FOLDER`
  (`ci/lib.sh` gives it to the stacks as `parent_folder`). The bootstrap reads and asks for nothing above that folder,
  and grants `cloud-admin-pipeline` nothing on it: its folderAdmin, projectCreator and owner there are the host's
  grants, which the bootstrap reports. The org policies are the host's job (Jody's decision, option B): the README
  lists the set relied on; this repository sets none, and its drift does not see them. `tests/hosting_test.sh` fails
  on any organization resource or the host's name outside the README's hosting note.
- **Runner image and readiness (#4):** the pools boot Container-Optimized OS for arm64, pinned by image name in
  `modules/settings` (`cos_arm64_image`, never a family: the module and `ci/policy.sh` refuse one), vanilla
  (`decisions/builds-in-containers-2026-11-03.md`): no startup-script, nothing installed at boot, OS updates off, the
  OS's own Docker. Every pool waits, bounded to ten minutes, until `docker info` answers the connecting user
  (`instance_ready_command`). No baked image and no bake identity (superseded). Tested against mock providers only.
- **Shared pools and the build cache (#5):** three pools (README, The pools): `shared`, one always-on t2a-standard-8
  (two jobs of 4 CPUs and 14g, no swap) for agent, build and control jobs, a tacplus-dev group runner under today's tags
  (`arm64`, `autoscale`, `autoscale-16`, `build`); `deploy` and `cluster`, protected and on demand. Job containers
  share reused VMs, no privileged mode, no host Docker socket, containers and volumes discarded per job; disk bounded
  per VM, not per job. The cache: `gs://tacplus-ci-build-cache` and the registry `build-cache`, only
  `build-cache@tacplus-ci` holding a role on them, federated from tacplus-dev/build's jobs only; entries deleted
  after 30 days. Plan tests cover the cache's IAM, the federation, the lifecycles and the pools' settings, against
  mock providers only.
- **Certificates by pipeline (#6):** `modules/settings` (`deployments`) lists the deployments whose pipelines own
  their certificates; the dev stack gives each, in `tacplus-dev`, an identity of its own federated from its GitLab
  project's protected main (`seatrials-deploy`, tacplus-dev/fleet-seatrials), the secrets `tls-<deployment>` and
  `acme-account-<environment>` (only that identity adds and reads versions) and the zone `acme-challenge-<domain>` for
  `_acme-challenge.<domain>` (only it holds `dns.admin`), all authoritative bindings. Tested against mock providers
  only. Interim: the same for tacplus.dev, by hand in jody1-328023 for `seatrials-deploy@jody1-328023`, with the
  commands in the README (Certificates), which the hub runs.
- **The network rules of 2026-11-03 (#7):** `ci/policy.sh plan` refuses an instance or template with an external address
  (or one unknown until apply), any allow rule from `0.0.0.0/0`/`::/0` or with no source (no exception list: every LB is
  proxy-based), any rule allowing port 22 in either direction but the runners' internal `runner-manager-to-workers-ssh`
  exactly as it is (it goes with #11), a cluster without private nodes and a pool with public nodes or not
  `COS_CONTAINERD` (README, The network rules). The IAP SSH rule is gone from `ci`. In `dev`, the `arm64` pool is
  replaced by `normal` (3 x c4a-standard-2, on demand, fixed) and `spot` (c4a-standard-4 spot, 0 to 3, label `spot=true`,
  taint `spot=true:NoSchedule`, given in the stack's output `cluster` for tacplus-dev/cluster#6), both private and
  `COS_CONTAINERD`; the control plane stays public (Jody). `compute.vmExternalIpAccess` (deny all) is on the README's list
  of the host's org policies (since #8 this repository sets none). The drift job runs a live audit (`ci/audit.sh`) of
  `tacplus-ci` and `tacplus-dev` with the same checks, for what no state holds; GKE's own internal `gke-*` rules are not
  reported for port 22. Tested with plan and live fixtures and the stacks' plan tests, against mocks and a stub gcloud
  only; the runner VMs are not spot (moot: they go with #11).
- **The one public IP and tacplus.dev's zone (#13):** the dev stack reserves the global external IPv4 address `gateway`
  (`prevent_destroy`) for the Gateway's load balancer, and holds tacplus.dev's zone `tacplus-dev` (DNSSEC on), written
  only by this pipeline: the records copied from the zone in jody1-328023 (`modules/settings`, `zone`), each deployment's
  hostnames (`seatrials.tacplus.dev`, `idp.test.tacplus.dev`) A to the address, and the delegations of
  `dev.tacplus.dev` and `_acme-challenge.tacplus.dev`; `apply:dev` prints the zone's name servers for the registrar.
  `ci/policy.sh` refuses a global address without `prevent_destroy` in the source, and in a plan any other external
  address and any external forwarding rule; the live audit reports them. The drift job's DNS check (`ci/dns.sh`)
  compares 8.8.8.8's and 1.1.1.1's answers with the zone. The cutover (TTLs first, the registrar's name servers, both
  zones for 48 h) is in the README; nothing of it is done. IPv4 only (PROPOSALS.md). Tested with the stacks' plan
  tests, plan, source and live fixtures, and a stub gcloud and dig; `ci/dns.sh` also run against the real resolvers.
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none. OpenTofu, the google
  provider, tflint and its ruleset, GitLab Runner and the fleeting plugin carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md).
- **Security job (#10):** `security` (`ci/security.sh`), on every push, merge request and nightly, before `plan:folder`:
  OSV-Scanner on the tree, `govulncheck -mode=binary` on every pinned binary (the tools, the scanners, both providers,
  GitLab Runner and its plugin), gitleaks on the tree and its full history, Trivy on the CI image; looper-scan's policy,
  `security-exceptions.yaml` enforced (an expired entry fails); its report `security/report.json`, the artifact. Its
  first run here passes: the CI image's 223 fixable HIGH/CRITICAL findings fixed by its new digest, the scanners'
  standard library ones by building them with go1.27.3, gitleaks' xz (GO-2025-3922) accepted until **2026-12-04**.
  Tested by `tests/security_test.sh` (a planted secret, in the tree and in history, an expired exception, a clean tree,
  the policy) with stubs for OSV-Scanner, govulncheck and Trivy; never run in GitLab yet (no pipeline has run).
- **Released / deployed:** nothing applied. No pipeline has run.
- **Known gaps:** never run against real GCP or GitLab: the plans are tested against mock providers only, so an API's
  refusal (a role missing, a name taken) shows only in the first pipeline. The GitLab project `tacplus-dev/cloud`, its
  runner (tag `cloud`), `GCP_WIF_PROVIDER`, the reader app's install and KMS grant, and the schedule are the hub's
  (README, Before the first pipeline); until Jody's registrar change, tacplus.dev resolves through the zone in
jody1-328023, which the hub keeps alike (README, The tacplus.dev cutover). The test IdP's own load balancer and address
in jody1-328023 do not carry over: in the new cluster it is behind the Gateway (PROPOSALS.md). The runners are
  registered paused and the cluster is empty until the later move off jody1-328023; with no host Docker socket, the
  jobs that use one (looper-docker, the host-socket gates) must move to build jobs first (looper#71). The build jobs
  do not use the cache yet: tacplus-dev/build's jobs need its `id_tokens` and BuildKit and compiler cache
  configuration (tacplus-dev/tacplus#315). The challenge zone's delegation and seatrials' move to its identity in `tacplus-dev` (copying the
  certificate's versions, no new order) wait for that move (README, Certificates). Follow-ups in PROPOSALS.md.
- **Blocked on:** the host's grants on the parent folder, Jody's bootstrap run (README, What the host organization
  provides; What Jody runs, in order), the host's grants to `cloud-admin-pipeline`, then the hub's steps (no issue). #4's
  acceptance (`runner-image measure 20`, no first-job image-pull failure) waits for the runners' move off jody1-328023.
