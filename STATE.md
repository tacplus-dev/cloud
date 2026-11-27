# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-27 by the looper (#114).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:20261126-57a6521` by digest, the 2.6 line's dated build tag, never the floating
  `build:2.6` (#102; `tests/ci_test.sh` refuses one; looper#226's nightly scan moves it; `.github/workflows/gates.yml`
  still at build:20261123-57a6521's digest, PROPOSALS.md); before it build:20261123-57a6521's digest, #104;
  build:20261123-ef62327, #97: krb5
  1.21.3-5+deb13u2 and Debian's other fixes of that day, whose 159 HIGH advisories in 2.6.13's packages failed the security
  job that morning; 2.6.13, #91; since 2.6.12, #59: rebuilt by tacplus-dev/tacplus#711 with `linux-libc-dev`
  6.12.117-1, DSA-6628-1, whose six HIGH kernel CVEs in 6.12.116-1 failed the security job on 2.6.10 on 2026-11-14; no
  OpenEXR since 2.6.10, #43, tacplus-dev/tacplus#554, whose 16 CVEs failed it on 2.6.8 and 2.6.4; go1.27.4 since 2.6.8,
  #39; its `gh`'s x/net and its zlib fixed, so no CI image entry is left in `security-exceptions.yaml` but GO-2026-5932,
  its `gh`'s x/crypto); OpenTofu 1.13.2, providers
  `google` 8.9.0, `kubernetes` 3.4.0 (the dev stack) and `gitlab` 19.5.0 (lock files), tflint 0.66.0 (google ruleset
  0.41.0), shellcheck 0.11.0, and the security job's gitleaks v8.30.1, OSV-Scanner v2.7.0, govulncheck v1.1.4 (built
  from their modules; gitleaks and OSV-Scanner with klauspost/compress v1.20.2, and gitleaks brotli v1.2.7, #24) and
  Trivy 0.76.2 (tflint 0.66.0 and Trivy 0.76.2 since #62: x/net v0.62.0), all pinned by checksum (`ci/tools.sh`). Since #39 (GO-2026-6859, net/http) everything but shellcheck
  is built here with **go1.27.4**: OpenTofu, tflint, its ruleset and Trivy from their release's module source (pinned
  by module hash and by the build's SHA-256, `srcbuild`; OpenTofu with go-jose v4.1.6 in place of its release's v4.1.4,
  GHSA-mgcc-cww5-fp2q and two more with no Go vulndb id, #98), yq and the scanners from their modules, and the four
  providers from their tags, reproducibly, each by its pinned SHA-256 (`ci/gitlab-provider.sh`, #3, x/net v0.62.0;
  `ci/kubernetes-provider.sh`, #18, x/net v0.62.0 and kin-openapi v0.152.0, its `manifest/openapi` ported by
  `ci/kubernetes-provider.patch`, #23; `ci/google-provider.sh`, #39, x/net v0.62.0 and, #76, x/crypto v0.59.0; and `ippontech/anthropic` v1.92.0,
  the `anthropic` stack's, `ci/anthropic-provider.sh`, #34), installed only from
  `bin/providers` (`ci/tofurc.sh`) and locked by their own hashes. GitLab Runner and the fleeting plugin are no longer
  built here (`ci/runner.sh` went with the runner manager, #113).
- **Works (#1):** `bootstrap/bootstrap.sh` (the folder and project `bootstrap`, the state bucket,
  `cloud-admin-pipeline` with its rights and its WIF from `tacplus-dev/cloud`'s protected main, the empty secrets;
  idempotent, refuses what differs, `--dry-run`; reads a folder listed by its bare ID as gcloud now lists it, #14); the stacks `folder` (folders `ci` and `dev`, readers), `ci` (the looper VMs and the reserved machines on the network
  `runners` and its NAT, no runner pool since #113, below; the build cache, the GitHub Apps' import-only KMS keys and their federation, #19 below), `dev` (GKE Axion cluster, private COS nodes in a normal and a spot pool (#7, below; the looper pool gone, #114), `dev.tacplus.dev` zone,
  `cluster-admin-pipeline` for tacplus-dev/cluster) and `gitlab` (this project's protected main, environments and
  variables from Secret Manager by version; the in-cluster `infra` runner, #64, unpaused at the switch-over, #66, and `kick`, #81, `build-report`, #93, `build-light`, #100, `manager`, #106, and `nightly`, #116, runners); the GitLab pipeline (checks on every
  push, plan per stack saved, apply of exactly that plan automatically on main, nightly drift filing an issue, never
  applying); `ci/policy.sh` (no service-account key, nothing public, nothing a commit does not fix) on the source and on
  every plan, and the network rules on every plan (#7, below). Tests green (`ci/lint.sh all && ci/checks.sh`), here and in the CI image: each stack's plan against mock
  providers, the pipeline's rules, the plan/apply script, the policy, and the bootstrap against a stub gcloud.
- **In a folder handed to it (#8):** no organization of its own: everything is under a parent folder the host
  organization hands over (README, What the host organization provides, and its hosting note), whose
  numeric ID is an input, `bootstrap/bootstrap.sh --folder` and the protected GitLab variable `GCP_PARENT_FOLDER`
  (`ci/lib.sh` gives it to the stacks as `parent_folder`). The bootstrap reads and asks for nothing above that folder,
  and grants `cloud-admin-pipeline` nothing on it: its rights there are the host's grants, which the bootstrap
  reports: since #78 the least set the stacks use (sixteen predefined roles, each named with why in the README and
  `HOST_ROLES`), never owner or editor, and the folder stack grants it nothing (until #78, owner of `ci` and `dev`,
  Trivy GCP-0007). **Not yet live:** the host organization still grants owner on the parent folder until it
  swaps to the set; the bootstrap says which roles are missing and that owner and editor go. Unverified until the
  first apply of each stack on the set alone; the pipeline's owner of the projects it created is PROPOSALS.md's. The org policies are the host's job (Jody's decision, option B): the README
  lists the set relied on; this repository sets none, and its drift does not see them. `tests/hosting_test.sh` fails
  on any organization resource or the host's name outside the README's hosting note.
- **The runner pools and their manager retired (#113; Jody, 2026-11-25: "make sure you have all the dead stuff cut"):**
  in one land, two commits. The gitlab stack drops the four pools' registrations (`shared` 58534919, `build` 58928680,
  `deploy`, `cluster`), their token versions and the cluster runner's enablement on tacplus-dev/cloud; the ci stack
  drops their templates and groups, the manager `runner-manager-d510c62b` and its disk, the accounts and IAM,
  `runner-token-<pool>`, the bucket `tacplus-ci-runner-bin`, `runner-manager-to-workers-ssh` and the policy's
  exception and manager guards, `ci/runner.sh` with its scans and its two exceptions, the `handoff` job, and settings'
  `runner_pools`. Their history (#4 COS and readiness, #5 shared pools, #40 our runner builds, #46/#48/#51/#54 the
  manager's handoffs, #49 the regional build pool, #53 the pool check, #61 NAT logs, #63 the shared VM's disk) is in
  git and PROPOSALS.md, its entries marked moot. Kept: the network `runners`, its subnet, router and NAT (the looper VMs
  and reserved machines use them; a rename would replace them), the COS pin (`cos_arm64_image`), `ci/pools.sh`. The
  manager's `destroy = false` is in its state, so a `removed` block with `destroy = true` destroys it
  (`tests/ci_plan_test.sh` plans from that state: destroyed, and forgotten without the block). `plan:ci` first runs
  `ci/idle-runners.sh` with the GitLab token: each pool runner still registered must have no job running and none
  created within 24 hours, else no plan. The live audit (`ci/audit.sh`) names any `runner-*` VM, disk, template or
  group left (managers forgotten before #46). The quota tests count the looper VMs and the reserved machines alone:
  16 C4A CPUs of 24 (32 all regions) and 400 GB of Hyperdisk Balanced of 500 today; the reserved machines' images
  (13 CPUs, 410 GB more) need sizing under them. README, What runs where. `build-docker` (a host-Docker publish) runs
  nowhere now (PROPOSALS.md). tacplus-dev/cluster#65 dropped cluster's check against the ci stack's `runner` block, which this removes. On main: `apply:ci` and `apply:gitlab` run it on the next pin, and the
  audit should list no `runner-*` VM in tacplus-ci. Not verified against real GCP or GitLab: the idle check's first run,
  the destroy, and whether strays exist. jody1-328023's `gitlab-runner-mgr` (runners 57939705, 58307468) is outside
  this repository: Jody's to check.
- **Certificates by pipeline (#6):** `modules/settings` (`deployments`) lists the deployments whose pipelines own
  their certificates; the dev stack gives each, in `tacplus-dev`, an identity of its own federated from its GitLab
  project's protected main (`seatrials-deploy`, tacplus-dev/fleet-seatrials), the secrets `tls-<deployment>` and
  `acme-account-<environment>` (only that identity adds, reads and lists versions: `viewer` since #68, the cert job
  lists them) and the zone `acme-challenge-<domain>` for
  `_acme-challenge.<domain>` (only it holds `dns.admin`), all authoritative bindings. Tested against mock providers
  only. Interim: the same for tacplus.dev, by hand in jody1-328023 for `seatrials-deploy@jody1-328023`, with the
  commands in the README (Certificates), which the hub runs.
- **seatrials' deploy pipeline through tacplus-dev (#68, fleet-seatrials#48):** its first deploy child pipeline was
  refused three grants, now in the dev stack: `roles/storage.legacyBucketReader` for `seatrials-build` on
  `tacplus-dev-seatrials-build` (Cloud Build needs `storage.buckets.get`, which objectAdmin lacks), `secretmanager.viewer`
  on every certificate secret for its owner, and `secretAccessor` and `viewer` on `test-idp-seeds` for `seatrials-deploy`
  (`test-idp-deploy` still alone adds them). Tested with the plan tests; not yet seen live: the images, cert and
  test-idp-signin jobs past these refusals once `apply:dev` has run.
- **The test IdP's seeds stored by seatrials-deploy (#73, fleet-seatrials#27):** the test-idp job, as
  `seatrials-deploy`, was refused `secretmanager.versions.add` on `test-idp-seeds` (job 18082964636): a deployment's
  identity now also holds `secretVersionAdder` on its environment accounts' secrets, beside the environment account
  (the certificate secrets `tls-seatrials` and `acme-account-seatrials` already granted it). Tested with the plan test;
  not yet seen live: the test-idp job storing its seeds once `apply:dev` has run.
- **get-credentials on dev (#71, fleet-seatrials#27):** the deployments' `container.clusterViewer` condition named the
  cluster `projects/tacplus-dev/locations/us-central1-a/clusters/dev`, which matches only a regional cluster: IAM names
  the zonal `dev` `projects/tacplus-dev/zones/us-central1-a/clusters/dev`. So `seatrials-deploy` and `test-idp-deploy`
  got a 403 on `container.clusters.get`. The condition now uses the zonal form, which the plan test checks. Not yet seen
  live: the test-idp job past `kube:` once `apply:dev` has run.
- **The network rules of 2026-11-03 (#7):** `ci/policy.sh plan` refuses an instance or template with an external address
  (or one unknown until apply), any allow rule from `0.0.0.0/0`/`::/0` or with no source (no exception list: every LB is
  proxy-based), any rule allowing port 22 in either direction (no exception since #113 removed the runners' internal
  `runner-manager-to-workers-ssh`), a cluster without private nodes and a pool with public nodes or not
  `COS_CONTAINERD` (README, The network rules). The IAP SSH rule is gone from `ci`. In `dev`, the `arm64` pool is
  replaced by `normal` (3 x c4a-standard-2, on demand, fixed) and `spot` (c4a-standard-4 spot, 0 to 3, label `spot=true`,
  taint `spot=true:NoSchedule`, given in the stack's output `cluster` for tacplus-dev/cluster#6), both private and
  `COS_CONTAINERD`; the control plane was public then (Jody, 2026-11-04), private since #79 (below). `compute.vmExternalIpAccess` (deny all) is on the README's list
  of the host's org policies (since #8 this repository sets none). The drift job runs a live audit (`ci/audit.sh`) of
  `tacplus-ci` and `tacplus-dev` with the same checks, for what no state holds; GKE's own internal `gke-*` rules are not
  reported for port 22. Tested with plan and live fixtures and the stacks' plan tests, against mocks and a stub gcloud
  only.
- **No public control plane (#79, Jody, 2026-11-18: only load balancers are public):** the dev cluster has no public
  endpoint (`enable_private_endpoint`), and its master authorized networks, enforced on the private endpoint, Google
  Cloud's public ranges off, are the nodes' `10.20.0.0/20` and pods' `10.24.0.0/14`: the cloud, cluster and deploy
  pipelines reach it from their job pods on `infra`; the runner VMs and the internet do not (README, The network rules;
  the break-glass, README, The cluster pipeline). `ci/policy.sh plan` refuses a cluster with a public endpoint, without
  authorized networks or authorizing a public range or Google's; the live audit reports one. Clears Trivy GCP-0061
  locally (Trivy 0.76.1). Tested with the dev plan test (mock providers), the policy's and the audit's fixtures; not yet
  seen live: `apply:dev` on main closing the endpoint (an in-place update), then a cluster and a deploy pipeline green
  on `infra` against it, and the next nightly security report without GCP-0061.
- **The spot build pool over the region (#85):** on 2026-11-20 from 21:00Z tacplus gates pods waited Pending (`0/5
  nodes are available`) and their build jobs failed (`runner_system_failure`) with the `spot` pool at 2 nodes of 5,
  both in us-central1-a, the zonal cluster's only zone, out of spot c4a. The pool now spreads over every zone of the
  region whose machine types include its own (`google_compute_zones` and `google_compute_machine_types`, read at plan
  in tacplus-dev), with `total_min_node_count` 0 and `total_max_node_count` 5 (the maximum in all zones, unchanged)
  and location policy `ANY`; `normal` and the cluster stay in us-central1-a. Tested with the dev plan test (mock
  providers); not yet seen live: `apply:dev` (an in-place update of the pool), then a gates pod scheduled while the
  pool is under 5. Gap: a dev project not yet made cannot plan (its zones are read in it). The audit now shows what
  fills each spot node, the pods not scheduled, and the cluster autoscaler's events on the cluster's objects (a pod's
  `NotTriggerScaleUp` and its reason); its log, switched off until the host's grant (below, The hub's audit).
- **The node pools' quotas (#88):** the #85 spread did not let `spot` grow: its scale-ups were refused
  `QUOTA_EXCEEDED`, `HDB_TOTAL_GB` (500 GB in us-central1, all used by 5 nodes of 100 GB) and `CPUS_PER_VM_FAMILY` C4A
  (24). The dev stack now asks them of Google as Cloud Quotas preferences of `tacplus-dev`, computed from the pools
  (output `quotas`): 32 C4A CPUs (6 + 20 + one c4a-standard-4 being replaced, 30) and 1000 GB of Hyperdisk Balanced
  (9 x 100, 900); `ci/policy.sh` refuses a plan whose C4A pools they do not cover, or a preference without a contact.
  The contact Google asks about an increase is the protected variable `GCP_QUOTA_CONTACT` (`quota_contact`). The
  pipeline needs the host's `roles/cloudquotas.admin` (a new `HOST_ROLES` line). `GCP_QUOTA_CONTACT` is set (hub,
  2026-11-21); the host's `roles/owner` on the folder covers the grant until #78's least set replaces it. The first
  `apply:dev` (pipeline 3098055008) was refused, the Cloud Quotas API off in the caller's `tacplus-bootstrap`: since
  #90 the preferences' calls count against `tacplus-dev` (the dev stack's provider alias `google.quotas`,
  `billing_project` and `user_project_override`), whose module enables the API, so no bootstrap rerun is needed
  (bootstrap.sh still enables it there). Tested with the dev plan test (mock providers), `tests/quotas_plan_test.sh`
  (the real provider against the stub API: both preferences' calls name `tacplus-dev`), the policy and ci tests. Seen
  live: on 2026-11-22 the spot pool sat at its 5-node maximum (#96's commit, 11e0b30), which the old limits could not
  hold (5 x 4 + 6 = 26 C4A CPUs over 24, 8 x 100 GB over 500), so `apply:dev` made both preferences (the HDB ID
  `HDB-TOTAL-GB-per-project-region` included) and Google granted at least that much. Not seen from the looper (no
  GitLab or GCP access): the audit's Quotas rows (requested, granted, pending) at #96's 48 CPUs and 1500 GB.
- **The build pool to 8 (#96; Jody, 2026-11-23):** on 2026-11-22 `spot` sat at its 5-node maximum with 18 builds
  queued, a tacplus batch candidate waiting 1h17m. Its maximum is now 8 (c4a-standard-4 spot, still from 0, still over
  the region's zones), and the quota preferences follow from it: 48 C4A CPUs (6 + 32 + 4 + 4 = 46, with the looper
  pool's 2 x 2, #95) and 1500 GB of Hyperdisk Balanced (14 x 100 = 1400). Tested with the dev plan test (mock
  providers); not yet seen live: `apply:dev`, Google granting the increase (the pool grows as it is granted), then more
  than 5 build nodes at once.
- **The looper pool gone (#114 step 1; Jody, 2026-11-25: one pool of 3 small nodes, no autoscaling, deployments
  only):** #95's and #107's `looper` pool, the control runner's overflow, is removed with the `cluster` variable's
  `looper` field and the output's `looper_label`/`looper_taint`; the looper runs moved to the looper VMs, and the recap
  of 2026-11-26 had the normal pool full for 0 of 1060 pods. The quota preferences follow: 48 C4A CPUs (6 + 32 + 4 =
  42) and 1500 GB of Hyperdisk Balanced (12 x 100 = 1200). tacplus-dev/cluster#64 drops the pool from control's
  `concurrent` and its toleration first (cluster#61, the pool to 4, superseded). Tested with the dev plan test (mock
  providers); not yet seen live: `apply:dev` deleting the pool and lowering the preferences. Left (#114): steps 2 and
  3 (the spot pool, then the in-cluster runners and namespace `ci`) when the merge train retires
  (tacplus-dev/looper#249, #251), and step 4, the 3 nodes sized from the deployments' measured requests.
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
  reader's two variables, and the `infra` (#64), `kick` (#81), `build-report` (#93), `build-light` (#100), `manager` (#106) and `nightly` (#116) runners with their token versions.
- **The cluster pipeline's rights on dev, by this pipeline (#18):** the dev stack makes the secrets `gitlab-runner-build`,
  `gitlab-runner-control`, `gitlab-runner-infra` (#64), `gitlab-runner-kick` (#81), `gitlab-runner-build-report` (#93), `gitlab-runner-build-light` (#100), `gitlab-runner-manager` (#106) and `gitlab-runner-nightly` (#116; us-central1, empty; `secretAccessor` for `cluster-admin-pipeline` alone, `secretVersionAdder`
  for `runner_token_adders` alone, Jody's account, from the protected GitLab variable `GCP_RUNNER_TOKEN_ADDERS` (`ci/lib.sh`:
  no file names the host's directory, #8): authoritative bindings; output `runner_tokens`), and, through
  the kubernetes provider as this pipeline, the ClusterRoleBinding `cluster-admin-pipeline` of `cluster-admin` to the User
  `cluster-admin-pipeline@tacplus-dev.iam.gserviceaccount.com` (Jody: in the dev stack, as the issue says). The provider
  is configured from the cluster resource (known only after apply on a build from nothing or a replacement, which the real
  provider plans) with an ephemeral `google_client_config` token: none in the plan or the state, none expired at apply.
  `ci/policy.sh plan` refuses `roles/owner` or `roles/editor` to any service account, the pipeline's own included (#78),
  and `roles/container.admin` to any but the pipeline. tacplus-dev/cluster's hand steps 4 and 7 are this pipeline's; its README is a follow-up there
  (PROPOSALS.md). Tested with the dev stack's plan tests (mock providers), the policy's fixtures, and a plan of the binding
  with the real kubernetes provider under an unknown configuration; not applied yet: `apply:dev` on main does it, and
  whether the host admits the adder shows there; the hub sets `GCP_RUNNER_TOKEN_ADDERS` first.
- **The `infra` runner, registered and its token written by this pipeline (#64; tacplus-dev/cluster#25):** the gitlab
  stack registers the in-cluster runner of the cloud, cluster and deploy pipelines (`stacks/gitlab/main.tf`, `infra`): a
  tacplus-dev group runner, tags `cloud`, `cluster`, `deploy` and no other, untagged off, `ref_protected`, registered paused and **unpaused at the switch-over** (#66, below),
  described as the cluster's; and writes its authentication token as `gitlab-runner-infra`'s version 1 (the first of
  the empty secret the dev stack makes; cluster's `gitlab-runner/runners/infra.yaml` names that version), as this
  pipeline, its `secretmanager.admin` from the parent folder (#78): no person or agent types it (Jody, 2026-11-16), and nothing else registers it.
  The module's `runners` take a `description` (the pools', which defaulted to the manager's, went with #113); the stack's output `runners`
  gives each registration without its token, and the tests assert `infra` from it (README, The cluster pipeline; the
  switch-over is a commit flipping `paused`, PROPOSALS.md). Tested: the gitlab and dev stacks' plan tests (mock
  providers) and `tests/gitlab_plan_test.sh` (the stub API: the create of the runner and of its version, nothing else
  changed). Not applied yet: `apply:dev` makes the secret, then `apply:gitlab` registers the runner and writes the
  version; cluster's `apply` then reads it. Until it has, cluster's `apply` fails after applying the rest
  (`runner-tokens: Secret Manager refused .../gitlab-runner-infra/versions/1`).
- **The `kick` runner, registered and its token written by this pipeline (#81; tacplus-dev/cluster#36):** as `infra`:
  the gitlab stack registers the in-cluster runner of the looper's kicker and plan alone (`stacks/gitlab/main.tf`,
  `kick`), a tacplus-dev group runner, tags `arm64` and `kick` and no other (not `control`, whose reports it would take
  too), untagged off, any ref, unpaused, and writes its token as `gitlab-runner-kick`'s version 1, which cluster's
  `gitlab-runner/runners/kick.yaml` will name. Tested: the gitlab and dev stacks' plan tests and
  `tests/gitlab_plan_test.sh`. Not applied yet: `apply:dev` makes the secret, `apply:gitlab` the runner and version (a
  retry if it reaches the version first: README, The cluster pipeline); then cluster#36 adds `kick.yaml`, then
  tacplus-dev/looper tags `.control` `arm64, kick`.
- **The `build-report` runner, registered and its token written by this pipeline (#93; tacplus-dev/cluster#42):** as
  `kick`: the gitlab stack registers the in-cluster runner of the report builds alone, whose pods a land's build
  preempts (`stacks/gitlab/main.tf`, `build-report`), a tacplus-dev group runner, tags `arm64` and `build-report` and no
  other (not `build`, whose land jobs it would take too), untagged off, any ref, unpaused, and writes its token as
  `gitlab-runner-build-report`'s version 1, which cluster's `gitlab-runner/runners/build-report.yaml` names. Tested: the
  gitlab and dev stacks' plan tests and `tests/gitlab_plan_test.sh`. Not applied yet: `apply:dev` makes the secret,
  `apply:gitlab` the runner and version (a retry if it reaches the version first); then the hub re-pins cluster to
  cluster#42, then sets tacplus-dev/build's `BUILD_REPORT_TAGS` to `arm64, build-report`.
- **The `build-light` runner, registered and its token written by this pipeline (#100; tacplus-dev/cluster#51):** as
  `kick`: the gitlab stack registers the in-cluster runner, on the normal pool, of tacplus-dev/build's light jobs alone
  (`pending`, `plan`, `report-pass`, `report-fail`), so a build runner's slot goes only to the gates and security jobs
  (`stacks/gitlab/main.tf`, `build-light`), a tacplus-dev group runner, tags `arm64` and `build-light` and no other (not
  `build`, whose gates and security jobs it would take too), untagged off, any ref, unpaused, and writes its token as
  `gitlab-runner-build-light`'s version 1, which cluster#51's `gitlab-runner/runners/build-light.yaml` names. Tested:
  the gitlab and dev stacks' plan tests and `tests/gitlab_plan_test.sh`. Applied (cloud dc67c17, 2026-11-24), and
  online as runner 59984739. `files/build.gitlab-ci.yml` is looper 3ed6045's (#92; b1dbfe4, tacplus-dev/looper#224, on), which tags
  those four jobs `arm64, build-light`; `tests/build_ci_test.sh` checks they carry it and not `build`.
- **The `manager` runner, registered and its token written by this pipeline (#106; tacplus-dev/cluster#60):** as
  `build-light`: the gitlab stack registers the in-cluster runner, on the normal (always-on) pool, of the looper's
  managers alone, so a manager never waits behind the reports for a `control` slot (`stacks/gitlab/main.tf`,
  `manager`), a tacplus-dev group runner, tags `arm64` and `manager` and no other (not `control`, whose reports it
  would take too), untagged off, any ref, unpaused, and writes its token as `gitlab-runner-manager`'s version 1, which
  cluster#60's `gitlab-runner/runners/manager.yaml` names. Tested: the gitlab and dev stacks' plan tests and
  `tests/gitlab_plan_test.sh`. Not applied yet: `apply:dev` makes the secret, `apply:gitlab` the runner and version
  (a retry if it reaches the version first); then cluster#60 renders the runner, and tacplus-dev/looper#236 tags the
  managers `manager`. **Gap:** until then managers still wait for `control`'s slots.
- **The `nightly` runner, registered and its token written by this pipeline (#116; tacplus-dev/cluster#46):** as
  `build-report`: the gitlab stack registers the in-cluster runner, on the spot pool, of the nightly fan-out's jobs
  alone, whose pods run at cluster's PriorityClass `build-nightly` (above the reports, below a land's)
  (`stacks/gitlab/main.tf`, `nightly`), a tacplus-dev group runner, tags `arm64` and `build-nightly` and no other (not
  `build`, whose land jobs it would take too), untagged off, any ref, unpaused, and writes its token as
  `gitlab-runner-nightly`'s version 1, which cluster#46's `gitlab-runner/runners/nightly.yaml` names. Tested: the
  gitlab and dev stacks' plan tests and `tests/gitlab_plan_test.sh`. Not applied yet: `apply:dev` makes the secret,
  `apply:gitlab` the runner and version (a retry if it reaches the version first); then the hub re-pins cluster to
  cluster#46, then tacplus-dev/looper#220 sets `BUILD_NIGHTLY_TAGS`. **Gap:** until then the nightly's security jobs
  still queue behind the report builds on `build`'s tags. Interim: it goes with the spot pool (#114).
- **The switch-over to `infra` (#66; tacplus-dev/cluster#25):** `stacks/gitlab/main.tf` unpaused `infra` and paused the
  `cluster` and `deploy` pools' runners; #113 removed every pool's runner, so `infra` has no stand-in. If `infra` takes
  no job: README, The cluster pipeline, the break-glass.
- **The cluster pipeline's registry (#45; tacplus-dev/cluster#21, decision (1)):** the dev stack makes the Artifact
  Registry Docker repository `ci-images` (us-central1, `us-central1-docker.pkg.dev/tacplus-dev/ci-images`, output
  `cluster_pipeline.registry`), private: `artifactregistry.writer` for `cluster-admin-pipeline` alone and
  `artifactregistry.reader` for the nodes' `gke-nodes` alone, authoritative bindings on that repository only; no cleanup
  policy. For tacplus-dev/cluster's own GitLab Runner images (its `runner-images` job, then its interim exception goes,
  by 2026-11-25). Tested with the dev stack's plan tests (mock providers); not applied yet: `apply:dev` on main does it.
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
- **The reader's key off jody1-328023 (#30):** `tacplus-reader` is imported too (`tacplus-reader-import`, the
  importers' bindings on it), a new key: Jody generates a new private key for the app and imports it (README, The
  GitHub Apps' keys), then the old one is revoked once its signers have moved. Besides the namespace, it signs for
  tacplus-dev/cloud's jobs through tacplus-bootstrap's pool (the drift issue: the pipeline file's
  `TACPLUS_READER_KMS_KEY` is the new key's), tacplus-dev/cluster's through the dev project's pool, and for the account `fleet-seatrials-reader@tacplus-ci` (no other role),
  which only tacplus-dev/fleet-seatrials' jobs become, through the dev project's pool (their `GCP_WIF_PROVIDER`); the
  ci stack's output `app_accounts`. The ci stack reads the dev project's number, so `plan:ci` now needs `apply:dev`.
  Tested with the stack's plan tests (mock providers) and `tests/ci_test.sh`; not applied yet, and no seatrials job
  has minted a token through it: `apply:ci`, Jody's import, then fleet-seatrials' variables (its own issue).
- **The Admiral's credentials (#84; tacplus-dev/admiral#5, Jody's option A, 2026-11-20):** `modules/settings`
  (`admiral`; `github_apps`' fourth app, `tacplus-admiral`, 5853599 / 184144753). The dev stack's `admiral.tf`: the
  pool `fleet-kernels` and its provider `seatrials`, OIDC for the seatrials kernel's issuer `https://seatrials.tacplus.dev`
  (discovery), admitting `spiffe://tacplus.dev/system/services/admiral` alone (seatrials' trust domain since #119), its audience the provider's own. The ci
  stack's `admiral.tf`: the account `admiral@tacplus-ci`, which only that subject becomes; `signerVerifier` on the
  import-only key `tacplus-admiral` (import job `tacplus-admiral-import`), for it alone (a `github_apps` signer on it is
  refused); the secret `admiral-triage-gitlab`, no version, which it alone reads and `GCP_ADMIRAL_SECRET_ADDERS`'s
  members alone add to (`ci/lib.sh`). The ci stack's output `admiral` is the Admiral's Config (README, The Admiral's
  credentials). Tested with the stacks' plan tests (mock providers) and `tests/ci_test.sh`; not applied yet: `apply:dev`
  then `apply:ci`, with `GCP_KMS_KEY_IMPORTERS` and `GCP_ADMIRAL_SECRET_ADDERS` set first (the hub), then Jody's import
  within three days and the token's first version; the first exchange is the Admiral's (admiral#5).
  The provider's first `apply:dev` (pipeline 3096232218) failed on the host's `iam.workloadIdentityPoolProviders`,
  then `https://gitlab.com` only (#86); the host has allowed `https://seatrials.tacplus.dev` since 2026-11-21
  (the host's pipeline), so the next `apply:dev` makes it as #84 wrote it (README, The org policies).
- **The looper VMs (#108; decisions/looper-build-vms-2026-11-24.md, tacplus the pilot):** `modules/settings`
  (`looper_vms`: tacplus, a spot c4a-standard-8 with 200 GB of Hyperdisk Balanced, no image until
  tacplus-dev/looper#239). The ci stack's `looper-vms.tf`: the group `looper-vm-tacplus` in us-central1-b at 0 (the
  kicker and the VM size it, never a plan), its template on the pools' COS arm64 pin, no external address, no SSH key
  and the project's blocked (`ci/policy.sh` refuses a key in any VM's metadata, and a looper VM that does not block
  the project's), one generic cloud-init (`files/looper-vm-cloud-init.yaml`, `files/looper-vm.sh`: an idle exit sizes
  the group to 0, a preemption's does not); the account `looper-vm-tacplus`: logWriter, reader of `looper-model-token`
  alone (no version, no adder: Jody adds it out of band), a signer of `tacplus-looper`'s key, and `looperVmResizer`
  on its own group; the kicker's jobs (environment `kicker`) hold `looperVmResizer` on the `looper-vm-` groups alone.
  Tested with the ci stack's plan tests (mock providers), `tests/looper_vm_test.sh` and `tests/policy_test.sh`; on
  GitHub Actions too (`.github/workflows/gates.yml`, branches `hub/**`). Not applied, not seen live: whether
  `cos-arm64-121-18867-652-12` boots on C4A with Hyperdisk, and whether the conditions on `resource.name` admit the
  resize. **Quota:** at 1 the VM's 8 CPUs are over `CPUS_ALL_REGIONS` (32, all of it the pools' at their peak) and
  need tacplus-ci's C4A CPU and Hyperdisk Balanced quotas, unread: a raise, or fewer pool CPUs, before the kicker sizes
  it to 1.
- **The reserved machines and the metadata cut-off (#111; decisions/agentic-dev-flow-2026-11-25.md):**
  `modules/settings` (`reserved_vms`): `check-tacplus` (c4a-standard-16), `check-tacplus-dev` (c4a-standard-4) and
  `merger` (c4a-standard-1), on demand, with no image yet (tacplus-dev/looper#249, #251), so their groups are at 0.
  The ci stack's `reserved-vms.tf` gives each its own group, its own account (logWriter, and a signer of its role's key
  alone: `tacplus-check` or `tacplus-merger`, neither of which has a version or an app yet), the looper VMs' OS and
  cloud-init, and `looper-role` in the metadata. `files/looper-vm.sh` runs `looper-vm check` or `looper-vm merger`
  (the merger with no container socket) and never sizes these machines down. On every VM it cuts the build
  containers off from the metadata server (a `DOCKER-USER` rule, or nothing starts). Tested with the ci stack's plan
  tests and `tests/looper_vm_test.sh`. Not applied, not seen live: whether COS's iptables and Docker's
  `DOCKER-USER` behave as the stubs do. **Before an image is pinned:** Jody's two apps and key imports, and
  `CPUS_ALL_REGIONS` raised to 49 or more (the stack test counts the machines then; PROPOSALS.md).
- **The public entry: a TCP proxy, TLS passed through (#21):** the dev stack's `load-balancer.tf` makes Google's global
  external proxy Network Load Balancer on the address `gateway` (decisions/network-exposure-2026-11-03.md, addendum "we
  terminate TLS, not the cloud"): per listener of `modules/settings` `load_balancer`, a forwarding rule
  (`EXTERNAL_MANAGED`, TCP), a target TCP proxy (no PROXY header), a backend service (TCP, idle timeout a day) and a TCP
  health check on the endpoints' port; `gateway` on 443 to the NEG `seatrials-gateway` (endpoints 8443, tacplus-dev/operator#22
  renders its Service), `test-idp` on 8443 to `seatrials-test-idp` (the test IdP's own port: a TCP proxy does not route
  by SNI; fleet-seatrials renders it). Each starts `ready = false`, with no backend, until GKE has made its NEG; `test-idp` is
  `ready = true` (#42), `gateway` not yet. The
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
- **The fleet's CA and crypto file in Secret Manager (#28; Jody's option D, fleet-seatrials#44):** the dev stack's
  `fleet-secrets.tf`, from a `deployments` entry's `init_secrets`: the secrets `fleet-ca-seatrials` and
  `fleet-crypto-seatrials` (us-central1, no version), the account `seatrials-init-secrets`, which only fleet-seatrials'
  jobs in the environment `init-secrets` on protected main become, holding `secretVersionAdder` and `viewer` (metadata:
  whether a version exists) on them and no role on the project, and `secretAccessor` for `seatrials-deploy` alone
  (authoritative bindings; output `deployments` `fleet_secrets`). No GitLab token, no bot user, no `FLEET_INIT_TOKEN`
  (gitlab.com Free has no project access tokens). Tested with the dev stack's plan tests (mock providers); not applied
  yet: `apply:dev` on main does it, then fleet-seatrials#44's job adds the versions. The root credential's key
  (#105, fleet-seatrials#77): a third secret, `fleet-root-cred-seatrials`, the same accounts and roles (its reader
  `seatrials-deploy`, the client-steps job's; output `fleet_secrets.root_cred`); tested the same way, not applied yet.
- **The test IdP's certificate and seeds (#32; fleet-seatrials#27):** the `deployments` entry's environment account
  `test-idp-deploy` gets, from `environment_certificates` (`test-idp = "idp.test.tacplus.dev"`, which `*.tacplus.dev`
  does not cover), the secrets `tls-test-idp` and `acme-account-test-idp` (us-central1) and the zone
  `acme-challenge-idp-test-tacplus-dev` for `_acme-challenge.idp.test.tacplus.dev.` (DNSSEC on), delegated from
  `tacplus-dev` by NS, and, from `environment_secrets`, the secret `test-idp-seeds` (no `TEST_IDP_GITLAB_TOKEN`: as
  #28); it alone adds and reads the certificate's versions and administers the zone (authoritative bindings), it and
  seatrials-deploy add, read and list the seeds' (#68, #73), and it holds no other role but get-credentials. The module refuses a certificate or secrets for an
  environment with no account, two certificates on one domain and two secrets with one ID. Output
  `deployments.seatrials.environment_certificates` and `environment_secrets` name them. The listener `test-idp` is
  `ready = true` (#42): its NEG `seatrials-test-idp` (us-central1-a, 8443) exists since the first test-idp run, 2026-11-17. Tested with the dev stack's
  plan tests (mock providers); not applied yet: `apply:dev` on main does it, and whether the job adds, reads and writes
  its records shows in fleet-seatrials#27.
- **The Google sign-in client's secret (#37; Jody, fleet-seatrials#46):** the dev stack's `google-signin.tf`, from a
  `deployments` entry's `google_signin`: the secret `google-signin-seatrials` (us-central1, no version), `secretAccessor`
  for `seatrials-deploy` alone and `secretVersionAdder` for `google_signin_adders` alone (and, #56, a member binding of
  `roles/oauthconfig.editor` on the project for each, to make the client in Google Auth Platform), from the protected GitLab
  variable `GCP_GOOGLE_SIGNIN_ADDERS` (`ci/lib.sh`, as the runners' token adders; Jody's account), who adds the client
  JSON by hand in the Console (Google has no API for a web client): authoritative bindings; output `deployments`
  `google_signin`. No project module or stack makes a secret version (`tests/secret_values_test.sh`). Tested with the
  dev stack's plan tests (mock providers); not applied yet: the hub sets `GCP_GOOGLE_SIGNIN_ADDERS`, `apply:dev` on
  main makes it, then Jody adds the first version.
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none; of the google
  provider's, none since #76 (x/crypto v0.59.0, GO-2026-5932). OpenTofu, tflint and its ruleset carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md). x/net html's GO-2026-6860 and GO-2026-6866 name OpenTofu and the ruleset only since
  tflint 0.66.0 and Trivy 0.76.2 (#62). OpenTelemetry Go < v1.47.0 (GHSA-q7gw-24fr-5p69, MODERATE, no Go vulndb id, so
  the security job does not see it; the nightly scan found it, #99) in OpenTofu, tflint, its ruleset, OSV-Scanner and
  Trivy, whose latest releases still have it: accepted until **2026-12-23** (Jody, #99). GO-2026-6975 (otel < v1.47.0,
  W3C baggage) in OpenTofu, tflint, its ruleset and Trivy, published 2026-11-23 with no tool release fixing it, turned
  the hub's security job red (#103): accepted until **2026-12-08**, each entry scoped by `where` to its binary (Jody's
  decision, CI tooling never blocks). GitLab Runner and its plugin, and GO-2026-6984 (fastzip) with them, are no longer
  built or scanned here (#113).
- **Security job (#10):** `security` (`ci/security.sh`), on every push, merge request and nightly, before `plan:folder`:
  OSV-Scanner on the tree, `govulncheck -mode=binary` on every pinned binary (the tools, the scanners, the providers),
  gitleaks on the tree and its full history, Trivy on the CI image; looper-scan's policy,
  `security-exceptions.yaml` enforced (an expired entry fails; one with a `where` accepts its id only there, #103); its
  report `security/report.json`, the artifact. Since #101 (tacplus-dev/looper#225) it fails only on what ships
  (OSV-Scanner's and gitleaks' findings, `scope: "shipped"`): govulncheck's on the pins and Trivy's on the CI image are
  `tooling`, reported under "CI tooling (reported, never failing)" and never failing; an expired exception still fails,
  whatever it names. Its first run here passes: the CI image's 223 fixable HIGH/CRITICAL findings fixed by its new digest, the scanners'
  standard library ones by building them with the latest Go (go1.27.4 since #39), gitleaks' xz (GO-2025-3922) accepted until **2026-12-04**. On build:2.6 (#22) the image had one, its `gh`'s x/net
  CVE-2026-78661, accepted (#27) until build:2.6.10 (#43) fixed it with zlib's and dropped OpenEXR (tacplus-dev/tacplus#554):
  on that digest the security job passed, 0 failing findings (run here 2026-11-12), until 2026-11-14 03:31Z, when Trivy's
  database gained Debian's fix for six HIGH kernel CVEs in its `linux-libc-dev` 6.12.116-1 (DSA-6628-1) and the job went
  red on main, skipping every plan and apply (#59): build:2.6.12 (tacplus-dev/tacplus#711) carries 6.12.117-1, and on its
  digest Trivy 0.76.1 reports no HIGH or CRITICAL finding with a fix (run here 2026-11-14, both platforms). On 2026-11-23
  03:0xZ 159 HIGH Debian advisories (krb5 CVE-2026-107364, CVE-2026-112315, linux-libc-dev CVE-2026-99785, ...) turned it
  red on build:2.6.13 (#97): the 2026-11-23 rebuild of build:2.6 carries the fixes, and on its digest Trivy reports 164 HIGH
  or CRITICAL findings, none with a fix (run here 2026-11-23). Each kernel
  advisory batch recurs this way until the image question in PROPOSALS.md is decided; #23's (kin-openapi) are fixed by the kubernetes
  provider's build, and #24's by building gitleaks and OSV-Scanner with the fixed klauspost/compress (GO-2026-6865) and
  brotli (GO-2026-6888), GO-2026-6865 in the downloaded OpenTofu and Trivy accepted until **2026-12-06**.
  Tested by `tests/security_test.sh` (a planted secret, in the tree and in history, an expired exception, a clean tree,
  the policy, a `where`) with stubs for OSV-Scanner, govulncheck and Trivy; never run in GitLab yet (no pipeline has run).
- **Pinned for the build pipeline (#25; looper#71, #84):** `build.lock` names the CI image by digest at its dated build tag (#102)
  and `gates.yaml` its sets: full (`ci/tools.sh && ci/lint.sh all && ci/checks.sh`), and since #118 docs
  (`tests/hosting_test.sh`) for a change to PROPOSALS.md, ROADMAP.md, STATE.md, HISTORY.md or LICENSE alone
  (`tests/gates_test.sh`), so tacplus-dev/build builds
  this repository in that image, with no Docker, and runs its security checks; `tests/ci_test.sh` refuses a
  `build.lock` that is not the CI file's `default.image`. Builds of main run from the pin and report since
  tacplus-dev/looper#113 (2026-11-15): ca0e523's, pipeline 3070014440, green on the gates full, its security report one
  LOW semgrep finding (`ci/lib.sh:64`, IFS set globally), none failing the policy.
- **tacplus-dev/build's trigger and schedules (#26, #67, #112; looper#71, #84, #164, #252):** the gitlab stack's `build`
  (`modules/gitlab/build.tf`): tacplus-dev/build's `.gitlab-ci.yml`, tacplus-dev/looper's `ci/build.gitlab-ci.yml` at
  `build_ci_commit` (b40b42b since #112: looper#252's `release` input and branch releases, on the looper image c3a8b379,
  main-7c1dc4d, looper#261; before it 3e40ec7, #109: looper#237's build of 4 jobs, `BUILD_CHILD_VERDICT` "true" on the looper image
  d53cb7c1 (main-e0ab92d, whose child's security job sets the verdict, `looper-build scan`), `tests/build_ci_test.sh`
  refusing it on 790b7849; before it 3ed6045, #92: looper#221's image 790b7849, with looper#207's side-by-side scanners
  (`BUILD_SCAN_JOBS`), #209 and #210, the light jobs on `build-light`; before it b1dbfe4, #100: looper#224's light
  tags `arm64, build-light`; before it cf993b6, #92: looper#209's report slots below the pool's nodes,
  `BUILD_POOL_NODES` "2", `BUILD_REPORT_TAGS`, still the looper image cd7d3689; before it e877150, #82: the looper image cd7d3689, looper#202's `BUILD_GATES_REQUESTS_<repo>`, looper#185's
  nightly slots and looper#195's report slots; before it c0f7304, #75: the looper image ffd21be6, looper#173's retry of
  `runner_external_dependency_failure` and `api_failure`, an image a cold spot node could not pull in time, and
  the manager's one rebuild of an infra-only red, so the in-cluster build runner can be unpaused; before it f2f5237, #72: looper#172's `BUILD_DOCKER_TAGS: "arm64, build-docker"`, a host-Docker
  publish only on the VM build pool's runner, so the in-cluster build runner can be unpaused; before it 1d25d29, #69:
  the looper image a40bf646, #73 step 1's publish in the child pipeline with rootless BuildKit, #165, #168, #169;
  before that ad005bd, #67) copied as
  is (`stacks/gitlab/files/`), the hub's copy adopted by import, checked against GitHub and
  linted by GitLab's `ci/lint` in `plan:gitlab` before every plan (`ci/build-ci.sh`; `update` bumps it); a pipeline
  trigger on tacplus-dev/build, its token tacplus-dev/looper's (88136765) protected, masked `BUILD_TRIGGER_TOKEN`,
  rotated by a commit of its `rotate_by` (2027-02-05, every 90 days; the drift's expiry check reports it from 30 days
  before; the new trigger before the old one goes); its settings (#82, `build.variables`, unprotected, unmasked):
  `BUILD_GATES_REQUESTS_tacplus` = `3 10Gi 3500m 12Gi`, tacplus's gates job's size (looper#202), read since the
  bump to e877150, its limits the runner's ceilings (#83: 2 CPU slowed the timing-bound gates) and its requests 3 CPU
  10Gi since #87 (at 3500m 12Gi it fit no c4a-standard-4 spot node after its DaemonSets and never scheduled; the hub
  set 3 10Gi by hand on 2026-11-21, which the stack now keeps; `ci/policy.sh` refuses a larger request in a plan; a
  tacplus gates pod running on the spot pool, and its peak, the `pod use at the end` line, not yet confirmed); and **one nightly schedule** (#67), `nightly` at 03:00 UTC, the
  input `nightly: true` and no `repo`: its pipeline lists the repositories whose main pins a build image and runs each
  one's nightly in a child pipeline (looper#164), so every pinned repository has a nightly again and no list is kept
  here (`ci/nightly-builds.sh`, `pinned-repositories.yaml` and the drift's `nightly-builds` check are gone). It
  replaces #65's ten per-repository schedules (gitlab.com allows a project 10): a `moved` block makes it looper's
  schedule changed in place and the apply deletes the other nine, never asking for an 11th; the module still refuses
  more than 10 at plan. **Two release schedules** (#112, README, The build pipeline), on main with no `repo` either, so
  3 of the 10: `release-main` at 08:00 UTC, the input `release: main` (each pinned repository's main at its
  `main-green`, skipped when that is its release already or there is none), and `release-branches` every 3 h at :30,
  `release: branches` (each `release/X.Y` with something new; else one `nothing-new` job), created after the build
  file (`depends_on`) and an output of their own, `build_schedules` (the file's import reads `build.project`). Their
  publish needs the hub's step (README, The release's publish identity: `registry` a protected environment of
  tacplus-dev/build, and jody1-328023's provider admitting its protected `main` in it), by hand, not yet done. Tested
  with the stack's plan tests (mock providers), the stub-API plan with the real provider
  (`tests/gitlab_plan_test.sh`), `tests/build_ci_test.sh` (stub curl) and `tests/expiry_test.sh`; not seen yet:
  `apply:gitlab` on main of #67 (its in-place change, and which of the ten exist live), the first fan-out nightly,
  and #112's first release pipelines and a `<repo>:main-<commit12>` publish.
- **tacplus-dev/build's runner settings (#35):** a project whose jobs are tagged `build` (or any tag only tacplus-dev's
  pools serve) needs **group runners on**: the pools are tacplus-dev group runners, and a project with
  `group_runners_enabled=false` never gets one, its jobs failing `stuck_pending_no_matching_runners` after about 1.5 h
  (tacplus-dev/build until the hub's hand change of 2026-11-09; tacplus-dev/looper#113). The gitlab stack owns
  tacplus-dev/build's (`gitlab_project.build`, `modules/gitlab/build.tf`): group runners on, gitlab.com's shared runners
  off, the project adopted by its ID with `prevent_destroy` and every other attribute ignored. Tested with the stack's
  plan tests (output `build_runners`) and the stub-API plan (adopted with no change at the hand-set value; with group
  runners off, the plan turns them on and nothing else); not applied yet: `apply:gitlab` on main, and a build job
  taken by the shared pool, show there.
- **fleet-seatrials reads tacplus-dev/build's release records (#117; tacplus-dev/looper#262, fleet-seatrials#82):**
  the gitlab stack's `build.job_token_readers` admits tacplus-dev/fleet-seatrials to build's job token allowlist (one
  `gitlab_project_job_token_scope`, not authoritative: the hub's hand entries stay); no `members` entry, as the triggered
  pipelines' user, the group bot, is a Reporter of build by inheritance. The module's `build.downstream_triggers` (a
  trigger of the project it starts, rotated by `rotate_by`, its token build's protected, masked variable scoped to one
  protected environment, never `*`) is in place, the stack's map empty. Tested with the stack's plan tests and the
  stub-API plan; not applied yet. **Left:** the stack's `seatrials` entry (`BUILD_SEATRIALS_TRIGGER_TOKEN`, scope
  `seatrials-trigger`) once fleet-seatrials#82 is live; fleet-seatrials' daily schedule, still the hub's to make, owned
  by a member of tacplus-dev (else a `members` entry); the acceptance (a fleet-seatrials job's 200 on
  `release-<repo>/main/record`, `seatrials: pipeline <url> started`) is on GitLab, after the apply.
- **The Anthropic organization (#34; Jody's option A, 2026-11-10):** the stack `anthropic` owns each llmproxy
  deployment's workload identity (issuer, service account and its workspace membership, rule) from `modules/settings`
  (`deployments`, `llmproxy`), and adopts seatrials' hand-made ones by their IDs (`fdis_01JKxG3CyMXqfgcG8HoqorvT`,
  `svac_01EoVk8wqp7sVYgBkRyyd5MT`, `fdrl_01Fvxu1oSKHN6rwtdZmRbGY8`) and makes the account's explicit membership of `wrkspc_017AfVbSBgLY399kXGDRtQ6e`
  (it had none: the first live plan found no membership to import);
  `prevent_destroy` and an `archived_at` postcondition refuse a re-create under a new ID; `ci/policy.sh` refuses an
  adoption with a change, a rule of another scope than `workspace:developer`/`workspace:inference` and a non-developer
  account. The provider is our reproducible build of `ippontech/anthropic` 1.92.0 with go1.27.4 (#39)
  (`ci/anthropic-provider.sh`), installed from `bin/providers` only, locked, scanned by govulncheck. Its credential is no
  key: the jobs' GitLab ID tokens, one per exchange (`ci/anthropic-token.sh`), through a bootstrap `org:admin` rule made
  by hand, which the stack only reads and checks; `ci/tofu.sh` reports a failing check in the plan and the drift.
  Tested against a mock provider and, with the real provider and the credential path, a stub of Anthropic's API
  (`tests/anthropic_plan_test.sh`). The bootstrap is made (Jody, 2026-11-11: rule `fdrl_01JYRHz8AjGZ7TBcEQL9Eqvo`,
  account `svac_011SKzqJqvTtj2LmUFbbDztN`, issuer `gitlab-com`) and set in the CI file, so the pipeline on main plans
  and applies the stack. **Partly run:** the first `plan:anthropic` (pipeline 3057435167, 2026-11-12) exchanged through
  the bootstrap rule and imported the issuer, account and rule with no error, and failed on the membership's import (no
  explicit membership exists), now made instead. The second (pipeline 3064308469, 2026-11-13) was refused: the account
  and the rule are adopted with a change, which the refusal did not say (the plan's text is printed only once the policy
  passes); it now names each attribute that differs, the Console's value and the config's. The third (pipeline
  3066773640, job 18022609528) listed them: the account's and the rule's descriptions, the rule's audience and its token
  lifetime (600, not the default 3600), written as the Console holds them. The fourth (pipeline 3067066143, jobs
  18024991251/2, 2026-11-14) adopted with no change: 3 imported, the membership added. seatrials' rule is now narrowed
  to `workspace:inference` in a commit of its own (an update in place, the same ID), applied by the next pin. Its
  subject is now `spiffe://tacplus.dev/system/services/llmproxy` (#119; fleet-seatrials#16 makes `tacplus.dev`
  seatrials' trust domain), an update in place too, to apply before seatrials' first deploy on `tacplus.dev`.
- **The hub's audit (#77; Jody, 2026-11-17):** the hub's read-only gcloud checks run in this pipeline instead of on the
  Mac, with no key anywhere (README, The hub's audit). The ci stack makes `hub-audit@tacplus-ci`
  (`modules/projects/ci/hub-audit.tf`), which only this project's protected main becomes through the pipeline's own
  provider, with `compute`, `container`, `monitoring`, `secretmanager` and (#88) `cloudquotas` viewer and `serviceusage.serviceUsageConsumer`
  on `tacplus-ci` and `tacplus-dev`; `ci/policy.sh` refuses any other role to it in a plan, the module in its input. The
  `audit` job (`ci_audit`, `ci/hub-audit.sh`) is alone in its pipeline: the hourly schedule `audit` (minute 7) the gitlab
  stack makes on this project, known by its description (it sets no variable: pipeline variables are the Owner role's
  here), or a web or API run with `CLOUD_AUDIT` `true`. It writes `audit.json` and `audit.md` (exposure, inventory,
  quotas with usage, the hour's 10-minute CPU maxima per VM and node and the `ci` namespace's containers' use against
  their requests, the secrets' names and version states), the artifact `src/audit/` for 30 days (members only), and is
  red on an ingress rule open to `0.0.0.0/0`/`::/0`, a VM's external IP or a read it cannot make. Since #88 its quotas
  include C4A CPUs and Hyperdisk Balanced GB in the region, their limits and the project's preferences (requested,
  granted, pending) from Cloud Quotas (hub-audit's `roles/cloudquotas.viewer`), their usage the inventory's. Since #85 it also
  reads the cluster's API: each spot node's allocatable against its pods' requests, each pod on it with its owner (a
  runner pod's GitLab job), and the pods not scheduled, with why; no pod's spec is written out; and the cluster
  autoscaler's events on the cluster's objects (`NotTriggerScaleUp` with its reason, `TriggeredScaleUp`; the hour
  Kubernetes keeps them), which need no grant. And the cluster
  autoscaler's last 6 hours (no-scale-ups by pool, zone and reason; scale-up errors joined to the pools tried) through
  the log view `hub-audit-autoscaler` and a `roles/logging.viewAccessor` conditioned on it alone (Jody's option A; never
  `logging.viewer`), which `ci/policy.sh` holds to that view and its one filter. Since #94 its inventory lists the
  network endpoint groups (name, zone, size, type, the Service GKE made each for), so the hub sees `seatrials-gateway`
  and `seatrials-test-idp` appear; the listener `gateway` stays `ready = false` until the first one exists
  (tacplus-dev/fleet-seatrials#1, the first deploy). That part is off: `modules/settings`'
  `autoscaler_log` is `false` until the host grants `cloud-admin-pipeline` `roles/logging.configWriter` (a new
  `HOST_ROLES` line), so no `apply:ci` fails before it; then a commit sets it `true` (PROPOSALS.md). Tested with stubs and
  fixtures (`tests/hub_audit_test.sh`), the policy, the pipeline's rules and the ci and gitlab plan tests. Not yet seen
  live: `apply:ci` makes the account and its grants, `apply:gitlab` the schedule, once the GitLab project is pinned to the
  commit; then the first scheduled run, which #77 waits on. The hub's download URL answers from `main`'s latest
  successful pipeline only (README; PROPOSALS.md).
- **The release registry (#115; the hub's approval of design B, on Jody's standing word, 2026-11-26, tacplus-dev/looper#265;
  tacplus-dev/fleet-seatrials#82):** the ci stack makes `us-central1-docker.pkg.dev/tacplus-ci/releases`
  (`modules/projects/ci/releases.tf`, `modules/settings` `releases`): DOCKER, in the region (#120: the multi-region `us`
  failed the first `apply:ci`, 2026-11-27, against the host's `gcp.resourceLocations`, `in:us-central1-locations`; the ci
  module now refuses any location but its region), no cleanup policy; one writer, `release-publish@tacplus-ci`, which only tacplus-dev/build's
  protected `main` in its environment `registry` becomes (provider `tacplus-dev-build-release` of the pool `gitlab-com`);
  one reader, `seatrials-deploy@tacplus-dev`; both bindings authoritative, and `ci/policy.sh` refuses another writer, a
  reader not a service account or another role on it. The audit lists every repository's bindings (its registries
  section, through hub-audit's custom role `hubAuditRegistries`: list and getIamPolicy, never an image), a public one a
  finding. The ci stack's output `releases` gives build its registry, account and provider. Tested with mock providers,
  the policy's fixtures and the audit's stubs. Not yet live: `apply:ci`, then build publishing there
  (tacplus-dev/looper#265: until then the releases are in jody1-328023, which seatrials-deploy cannot read), then the
  acceptance, `crane manifest` of a release by digest as `seatrials-deploy`.
- **Released / deployed:** nothing released. The first pipeline (3030204494) applied `folder`, and `ci` and `dev` in part (#16).
- **Known gaps:** never run against real GCP or GitLab: the plans are tested against mock providers (the gitlab
  stack's also against a stub of gitlab.com's API, #17), so an API's
  refusal (a role missing, a name taken) shows only in the first pipeline. The GitLab project `tacplus-dev/cloud`, its
  runner (tag `cloud`), `GCP_WIF_PROVIDER`, the reader app's install, and the schedule are the hub's
  (README, Before the first pipeline); until Jody's registrar change, tacplus.dev resolves through the zone in
jody1-328023, which the hub keeps alike (README, The tacplus.dev cutover). The test IdP's own load balancer and address
in jody1-328023 do not carry over: in the new cluster it is on port 8443 of the address `gateway` (#21, PROPOSALS.md). The runners are
  registered paused and the cluster is empty until the later move off jody1-328023; with no host Docker socket, the
  jobs that use one (looper-docker, the host-socket gates) must move to build jobs first (looper#71). The build jobs
  do not use the cache yet: tacplus-dev/build's jobs need its `id_tokens` and BuildKit and compiler cache
  configuration (tacplus-dev/tacplus#315). The challenge zone's delegation and seatrials' move to its identity in `tacplus-dev` (copying the
  certificate's versions, no new order) wait for that move (README, Certificates). Follow-ups in PROPOSALS.md.
- **Blocked on:** the host's grants on the parent folder, Jody's bootstrap run (README, What the host organization
  provides; What Jody runs, in order), the host's grants to `cloud-admin-pipeline`, then the hub's steps (no issue). The move off
  jody1-328023 is #15. #113's land waits on tacplus-dev/cluster#65 (above).
