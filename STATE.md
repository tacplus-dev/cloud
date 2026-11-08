# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-08 by the looper (#26).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6` by digest (v2.6.1's, #22: the latest released line; one HIGH
  finding with a fix, its `gh`'s x/net CVE-2026-78661, accepted in `security-exceptions.yaml` until 2026-12-06, #27); OpenTofu 1.13.2, providers `google` 8.9.0, `kubernetes` 3.4.0 (the dev stack) and `gitlab` 19.5.0 (lock
  files), tflint 0.65.0 (google ruleset 0.41.0), shellcheck 0.11.0, and the security job's gitleaks v8.30.1, OSV-Scanner v2.7.0,
  govulncheck v1.1.4 (built from their modules with go1.27.3; gitleaks and OSV-Scanner with klauspost/compress v1.20.2, and
  gitleaks brotli v1.2.7, #24) and Trivy 0.76.1, all pinned by checksum (`ci/tools.sh`). The `gitlab`
  provider is our own reproducible build of its v19.5.0 tag with go1.26.10 and x/net v0.62.0 (`ci/gitlab-provider.sh`,
  #3), installed only from `bin/providers` (`ci/tofurc.sh`) and locked by its own hashes; the `kubernetes` provider is
  too, its v3.4.0 tag with go1.27.3, x/net v0.62.0 (`ci/kubernetes-provider.sh`, #18) and kin-openapi v0.152.0, its
  `manifest/openapi` ported to it by `ci/kubernetes-provider.patch` (#23): no kin-openapi finding, none accepted.
- **Works (#1):** `bootstrap/bootstrap.sh` (the folder and project `bootstrap`, the state bucket,
  `cloud-admin-pipeline` with its rights and its WIF from `tacplus-dev/cloud`'s protected main, the empty secrets;
  idempotent, refuses what differs, `--dry-run`; reads a folder listed by its bare ID as gcloud now lists it, #14); the stacks `folder` (folders `ci` and `dev`, readers), `ci` (runner manager VM, the arm64 pools as MIGs (#5, below), runner token secrets, the build
  cache, the GitHub Apps' import-only KMS keys and their federation, #19 below), `dev` (GKE Axion cluster, private COS nodes in a normal and a spot pool (#7, below), `dev.tacplus.dev` zone,
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
  (`prevent_destroy`) for the load balancer (its TCP proxy, #21), and holds tacplus.dev's zone `tacplus-dev` (DNSSEC on), written
  only by this pipeline: the records copied from the zone in jody1-328023 (`modules/settings`, `zone`), each deployment's
  hostnames (`seatrials.tacplus.dev`, `idp.test.tacplus.dev`) A to the address, and the delegations of
  `dev.tacplus.dev` and `_acme-challenge.tacplus.dev`; `apply:dev` prints the zone's name servers for the registrar.
  `ci/policy.sh` refuses a global address without `prevent_destroy` in the source, and in a plan any other external
  address and any external forwarding rule; the live audit reports them. The drift job's DNS check (`ci/dns.sh`)
  compares 8.8.8.8's and 1.1.1.1's answers with the zone. The cutover (TTLs first, the registrar's name servers, both
  zones for 48 h) is in the README; nothing of it is done. IPv4 only (PROPOSALS.md). Tested with the stacks' plan
  tests, plan, source and live fixtures, and a stub gcloud and dig; `ci/dns.sh` also run against the real resolvers.
- **The recap reads tacplus-dev/build (#12):** the gitlab stack makes `tacplus-looper-bot` a Reporter (20) of
  tacplus-dev/build until 2027-10-01 (Jody's option B: the looper's `GITLAB_TOKEN`, no new secret; Free gitlab.com has no
  project access tokens). The module's `members` take Guest or Reporter only, each with an expiry from the commit; the
  drift job's expiry check (`ci/expiry.sh`) reports one past or within 30 days, and a commit renews it. Tested with the
  stack's plan tests against mock providers and a fixture; not applied yet: `apply:gitlab` on main does it.
- **The first apply's two refusals (#16):** pipeline 3030204494 stopped in `apply:ci` (Cloud KMS counted against
  `tacplus-bootstrap`, the caller's project, where it was off) and `apply:dev` (`iam.workloadIdentityPools.create` denied
  in `tacplus-dev`, created seconds before), each a partial apply. The bootstrap now also enables Cloud KMS and Artifact
  Registry in `tacplus-bootstrap`, and `tests/apis_test.sh` names every google type the stacks use with its API and
  where its calls count (the caller's: bootstrap's `SERVICES`; the resource's: the module's APIs), failing on a type it
  does not name. Each project module's `terraform_data.iam_ready` (`ci/iam-ready.sh`: `testIamPermissions` until the
  pipeline holds its first creates' permissions on three checks in a row, bounded to ten minutes) comes after the
  project and its APIs, and everything else after it (`tests/iam_ready_test.sh`). Tested against stubs and mock
  providers; not yet against GCP: recovery is Jody's bootstrap run again (it enables the two APIs), then a pipeline on
  main from the partial state.
- **`plan:gitlab` on gitlab.com (#17):** pipeline 3030507386's `plan:gitlab` failed: gitlab.com says it is an Enterprise
  instance (`/metadata`), on Free too, and there provider 19.5.0 refuses a branch protection's `push_access_level` and
  `merge_access_level`. main's protection is now `allowed_to_push` and `allowed_to_merge`, by role (Maintainers; no
  force push), and the stack imports main's protection and `GCP_WIF_PROVIDER` by the project's numeric ID: by its path,
  the state's `project` differed from the config's and the first apply would have replaced both. `tests/gitlab_plan_test.sh`
  plans the stack with its real providers against a stub API (`tests/stubapi`) over a fixture of gitlab.com's and
  Google's answers (`tests/fixtures/gitlab/api.json`, built from the APIs' documented responses, not recorded: the
  looper cannot read the project's settings): both adopted with no change, nothing replaced or deleted, the old form
  refused. Its plan: the two adoptions, and creates of the membership (#12), the four protected environments, the
  reader's two variables, and the three paused runners with their token versions.
- **The cluster pipeline's rights on dev, by this pipeline (#18):** the dev stack makes the secrets `gitlab-runner-build`
  and `gitlab-runner-control` (us-central1, empty; `secretAccessor` for `cluster-admin-pipeline` alone, `secretVersionAdder`
  for `runner_token_adders` alone, Jody's account, from the protected GitLab variable `GCP_RUNNER_TOKEN_ADDERS` (`ci/lib.sh`:
  no file names the host's directory, #8): authoritative bindings; output `runner_tokens`), and, through
  the kubernetes provider as this pipeline, the ClusterRoleBinding `cluster-admin-pipeline` of `cluster-admin` to the User
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com` (Jody: in the dev stack, as the issue says). The provider
  is configured from the cluster resource (known only after apply on a build from nothing or a replacement, which the real
  provider plans) with an ephemeral `google_client_config` token: none in the plan or the state, none expired at apply.
  `ci/policy.sh plan` refuses `roles/owner` or `roles/container.admin` to any service account but the pipeline's own owner
  of its folders. tacplus-dev/cluster's hand steps 4 and 7 are this pipeline's; its README is a follow-up there
  (PROPOSALS.md). Tested with the dev stack's plan tests (mock providers), the policy's fixtures, and a plan of the binding
  with the real kubernetes provider under an unknown configuration; not applied yet: `apply:dev` on main does it, and
  whether the host admits the adder shows there; the hub sets `GCP_RUNNER_TOKEN_ADDERS` first.
- **The GitHub Apps' keys in tacplus-ci (#19; looper#83):** the key ring `looper` holds `tacplus-manager`,
  `tacplus-looper` and `tacplus-reader` (`modules/settings` `github_apps`, with the apps' IDs), import-only RS256
  software keys with no version, `prevent_destroy`; the reader's key and key ring moved to the map's addresses
  (`moved`). `tacplus-manager` and `tacplus-looper` each have an import job; the members of the protected GitLab
  variable `GCP_KMS_KEY_IMPORTERS` (`ci/lib.sh`, as the adders) alone import: `cloudkms.importer` by a key-ring binding
  conditioned on the import jobs' names (the provider has no import job IAM, PROPOSALS.md) and the custom role
  `kmsKeyVersionImporter` (versions create only) on each key. The pool `gitlab-loopers`, its provider `gitlab-looper`
  (tacplus-dev/looper's protected refs, `attribute.role` = `project_id:ref:ref_protected:environment`) and `gitlab-com`
  (tacplus-dev's protected refs, namespace 145863835); each key's own signers: `tacplus-looper` for looper's main in
  `looper-report`, `looper-scan`, `looper-plan` and `kicker`, `tacplus-manager` in `looper-manager` and `looper-scan`
  (the module refuses `looper-report`), `tacplus-reader` for the namespace. The ci stack's output `looper_variables`
  gives the looper project's variables. Tested with the stack's plan tests (mock providers) and `tests/ci_test.sh`; not
  applied yet: `apply:ci` on main does it, then Jody's import (README, The GitHub Apps' keys) and the looper's setup.
- **The public entry: a TCP proxy, TLS passed through (#21):** the dev stack's `load-balancer.tf` makes Google's global
  external proxy Network Load Balancer on the address `gateway` (decisions/network-exposure-2026-11-03.md, addendum "we
  terminate TLS, not the cloud"): per listener of `modules/settings` `load_balancer`, a forwarding rule
  (`EXTERNAL_MANAGED`, TCP), a target TCP proxy (no PROXY header), a backend service (TCP, idle timeout a day) and a TCP
  health check on the endpoints' port; `gateway` on 443 to the NEG `seatrials-gateway` (endpoints 8443, tacplus-dev/operator#22
  renders its Service), `test-idp` on 8443 to `seatrials-test-idp` (the test IdP's own port: a TCP proxy does not route
  by SNI; fleet-seatrials renders it). Both start `ready = false`, with no backend, until GKE has made the NEGs. The
  firewall rule `allow-google-proxies`, the dev module's only one, admits tcp:8443 to the nodes from `35.191.0.0/16` and
  `130.211.0.0/22` alone. `ci/policy.sh plan` admits only that forwarding rule (global, `EXTERNAL_MANAGED`, TCP, on
  `gateway`, to a TCP proxy), refuses any certificate, Certificate Manager resource, SSL policy, HTTP(S) or SSL proxy or
  URL map, and any ingress allow rule from a public range but Google's (the live audit reports those too). The NEGs'
  names are in the README (The public entry). Tested with the dev stack's plan tests (mock providers), plan fixtures,
  `tests/load_balancer_test.sh` and the audit's fixtures; not applied yet, and not against GCP: `apply:dev` on main does
  it.
- **seatrials on dev (#20; fleet-seatrials#39):** the dev stack's `deploy.tf`, from each `deployments` entry: its identity
  and each environment account get `container.clusterViewer` conditioned on the cluster `dev` (get-credentials); with
  `images`, Cloud Build (APIs `cloudbuild`, `artifactregistry`, `storage` enabled; the identity holds
  `cloudbuild.builds.editor` and `serviceusage.serviceUsageConsumer` on the project, `serviceAccountUser` on the builds'
  account), the builds' account (`seatrials-build`, only `logging.logWriter` on the project), the deploy registry
  `us-central1-docker.pkg.dev/tacplus-dev/seatrials` (no cleanup policy; the builds write, the identity and `gke-nodes`
  read) and the bucket `gs://tacplus-dev-seatrials-build` (7 days; `storage.admin` the identity's, `storage.objectAdmin`
  the builds'); `environment_accounts`: `test-idp-deploy`, which only fleet-seatrials' jobs in the environment `test-idp`
  on protected main become (the provider maps `attribute.project_environment`, project and environment joined), with no
  other role. Cloud Build is for now (Jody): it goes once looper#84 moves builds to the cluster. fleet-seatrials' builds
  must name the builds' account (`gcloud builds submit --service-account`). Tested with the dev stack's plan tests (mock
  providers); not applied yet, and the mapping's `has()` not yet seen by GCP: `apply:dev` on main does it.
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none. OpenTofu, the google
  provider, tflint and its ruleset, GitLab Runner and the fleeting plugin carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md).
- **Security job (#10):** `security` (`ci/security.sh`), on every push, merge request and nightly, before `plan:folder`:
  OSV-Scanner on the tree, `govulncheck -mode=binary` on every pinned binary (the tools, the scanners, both providers,
  GitLab Runner and its plugin), gitleaks on the tree and its full history, Trivy on the CI image; looper-scan's policy,
  `security-exceptions.yaml` enforced (an expired entry fails); its report `security/report.json`, the artifact. Its
  first run here passes: the CI image's 223 fixable HIGH/CRITICAL findings fixed by its new digest, the scanners'
  standard library ones by building them with go1.27.3, gitleaks' xz (GO-2025-3922) accepted until **2026-12-04**. On build:2.6 (#22) the image had one, its `gh`'s x/net
  CVE-2026-78661, accepted until **2026-12-06** (the hub's decision on #27) until tacplus-dev/tacplus#350 ships a `gh`
  with x/net >= v0.62.0 and the digest moves; #23's (kin-openapi) are fixed by the kubernetes
  provider's build, and #24's by building gitleaks and OSV-Scanner with the fixed klauspost/compress (GO-2026-6865) and
  brotli (GO-2026-6888), GO-2026-6865 in the downloaded OpenTofu, Trivy and GitLab Runner accepted until **2026-12-06**.
  Tested by `tests/security_test.sh` (a planted secret, in the tree and in history, an expired exception, a clean tree,
  the policy) with stubs for OSV-Scanner, govulncheck and Trivy; never run in GitLab yet (no pipeline has run).
- **Pinned for the build pipeline (#25; looper#71, #84):** `build.lock` names the CI image by digest (build 2.6, v2.6.1's)
  and `gates.yaml` its one set, full (`ci/tools.sh && ci/lint.sh all && ci/checks.sh`), so tacplus-dev/build builds
  this repository in that image, with no Docker, and runs its security checks; `tests/ci_test.sh` refuses a
  `build.lock` that is not the CI file's `default.image`.
- **tacplus-dev/build's trigger and nightly schedules (#26; looper#71, #84):** the gitlab stack's `build`
  (`modules/gitlab/build.tf`): tacplus-dev/build's `.gitlab-ci.yml`, tacplus-dev/looper's `ci/build.gitlab-ci.yml` at
  `build_ci_commit` copied as is (`stacks/gitlab/files/`), the hub's copy adopted by import, checked against GitHub and
  linted by GitLab's `ci/lint` in `plan:gitlab` before every plan (`ci/build-ci.sh`; `update` bumps it); a pipeline
  trigger on tacplus-dev/build, its token tacplus-dev/looper's (88136765) protected, masked `BUILD_TRIGGER_TOKEN`,
  rotated by a commit of its `rotate_by` (2027-02-05, every 90 days; the drift's expiry check reports it from 30 days
  before; the new trigger before the old one goes); and one schedule per repository of
  `stacks/gitlab/nightly-builds.yaml` (inputs `repo`, `nightly: true`; tacplus-dev/looper, 05:00 UTC). Tested with the
  stack's plan tests (mock providers), the stub-API plan with the real provider (`tests/gitlab_plan_test.sh`),
  `tests/build_ci_test.sh` (stub curl) and `tests/expiry_test.sh`; not applied yet: `apply:gitlab` on main does it, and
  whether GitLab takes the schedule's boolean input as the string `true` the provider sends, and the first nightly of
  looper, show there.
- **Released / deployed:** nothing released. The first pipeline (3030204494) applied `folder`, and `ci` and `dev` in part (#16).
- **Known gaps:** never run against real GCP or GitLab: the plans are tested against mock providers (the gitlab
  stack's also against a stub of gitlab.com's API, #17), so an API's
  refusal (a role missing, a name taken) shows only in the first pipeline. The GitLab project `tacplus-dev/cloud`, its
  runner (tag `cloud`), `GCP_WIF_PROVIDER`, the reader app's install and KMS grant, and the schedule are the hub's
  (README, Before the first pipeline); until Jody's registrar change, tacplus.dev resolves through the zone in
jody1-328023, which the hub keeps alike (README, The tacplus.dev cutover). The test IdP's own load balancer and address
in jody1-328023 do not carry over: in the new cluster it is on port 8443 of the address `gateway` (#21, PROPOSALS.md). The runners are
  registered paused and the cluster is empty until the later move off jody1-328023; with no host Docker socket, the
  jobs that use one (looper-docker, the host-socket gates) must move to build jobs first (looper#71). The build jobs
  do not use the cache yet: tacplus-dev/build's jobs need its `id_tokens` and BuildKit and compiler cache
  configuration (tacplus-dev/tacplus#315). The challenge zone's delegation and seatrials' move to its identity in `tacplus-dev` (copying the
  certificate's versions, no new order) wait for that move (README, Certificates). Follow-ups in PROPOSALS.md.
- **Blocked on:** the host's grants on the parent folder, Jody's bootstrap run (README, What the host organization
  provides; What Jody runs, in order), the host's grants to `cloud-admin-pipeline`, then the hub's steps (no issue). #4's
  acceptance (`runner-image measure 20`, no first-job image-pull failure) waits for the runners' move off jody1-328023.
