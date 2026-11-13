# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-13 by the looper (#54).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6.10` by digest (#43: the first 2.6 build without OpenEXR, tacplus-dev/tacplus#554,
  whose 16 CVEs failed the security job on 2.6.8 and 2.6.4; go1.27.4 since 2.6.8, #39; its `gh`'s x/net and its zlib
  fixed, so no CI image entry is left in `security-exceptions.yaml` but GO-2026-5932, its `gh`'s x/crypto); OpenTofu 1.13.2, providers
  `google` 8.9.0, `kubernetes` 3.4.0 (the dev stack) and `gitlab` 19.5.0 (lock files), tflint 0.65.0 (google ruleset
  0.41.0), shellcheck 0.11.0, and the security job's gitleaks v8.30.1, OSV-Scanner v2.7.0, govulncheck v1.1.4 (built
  from their modules; gitleaks and OSV-Scanner with klauspost/compress v1.20.2, and gitleaks brotli v1.2.7, #24) and
  Trivy 0.76.1, all pinned by checksum (`ci/tools.sh`). Since #39 (GO-2026-6859, net/http) everything but shellcheck
  is built here with **go1.27.4**: OpenTofu, tflint, its ruleset and Trivy from their release's module source (pinned
  by module hash and by the build's SHA-256, `srcbuild`), yq and the scanners from their modules, and the four
  providers from their tags, reproducibly, each by its pinned SHA-256 (`ci/gitlab-provider.sh`, #3, x/net v0.62.0;
  `ci/kubernetes-provider.sh`, #18, x/net v0.62.0 and kin-openapi v0.152.0, its `manifest/openapi` ported by
  `ci/kubernetes-provider.patch`, #23; `ci/google-provider.sh`, #39, x/net v0.62.0; and `ippontech/anthropic` v1.92.0,
  the `anthropic` stack's, `ci/anthropic-provider.sh`, #34), installed only from
  `bin/providers` (`ci/tofurc.sh`) and locked by their own hashes. GitLab Runner v19.5.3 and
  the fleeting plugin v1.3.1 are built here with go1.27.4 too (`ci/runner.sh`, #40): GO-2026-6859 has no exception.
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
  and the VM reaches `https://registry.gitlab.com/v2/` (`instance_ready_command`; #50: egress before the first job). No baked image and no bake identity (superseded). Tested against mock providers only.
- **Shared pools and the build cache (#5):** three pools (README, The pools): `shared`, one always-on t2a-standard-8
  one always-on t2a-standard-8 (three until #55) with no slots since 2026-11-10 (Jody: every looper runs when it wants; up to 25 jobs a
  VM, each may use the whole VM), every looper and control job, a tacplus-dev group runner tagged `arm64`,
  `autoscale`, `autoscale-16`; builds on the `build` pool, up to two on-demand t2a-standard-8s from zero (spot until #55), eight builds at a time,
  tagged `arm64`, `build`; `deploy` and `cluster`, protected and on demand. Job containers
  share reused VMs, no privileged mode, no host Docker socket, containers and volumes discarded per job; disk bounded
  per VM, not per job. The cache: `gs://tacplus-ci-build-cache` and the registry `build-cache`, only
  `build-cache@tacplus-ci` holding a role on them, federated from tacplus-dev/build's jobs only; entries deleted
  after 30 days. Plan tests cover the cache's IAM, the federation, the lifecycles and the pools' settings, against
  mock providers only.
- **The manager's binaries (#40):** GitLab Runner v19.5.3 (#44, the release tacplus-dev/cluster runs, cluster#21) and
  the fleeting plugin v1.3.1 built here with go1.27.4, x/net v0.62.0, klauspost/compress v1.20.2 and go-jose v4.1.6,
  reproducibly, by commit and SHA-256 (`ci/runner.sh`, in the tools job:
  `bin/manager/`, which `bin/scan/` scans), uploaded by the ci stack to `gs://tacplus-ci-runner-bin`, which only the
  manager's account reads among the VMs' and jobs' (README, The manager's binaries); the manager installs both from
  there by SHA-256, with no package, no apt and nothing from upstream at boot. The jobs' helper image is still
  upstream's (go1.26.10), by digest, pulled by the pools at a job's start. Plan tests (mock providers) cover the
  bucket, its one reader, the objects and the manager's metadata; `tests/manager_startup_test.sh` the startup against
  stubs; the builds reproduced their pins here (linux/arm64 host). Not applied yet: the first boot from the bucket
  shows on the `apply:ci` of the commit the GitLab project pins (step 1's commit first, then step 2's).
- **Never without a runner manager (#46):** `apply:ci` replaced the manager destroy-first, and the destroy took the
  manager away from under the apply job itself (it runs on the `cluster` pool, through that manager): the job died
  ("Plugin did not respond", 2026-11-10 and 2026-11-12) and the fleet had no manager. Now a config change is an
  in-place metadata update that the running manager applies by itself (its watcher re-runs the startup script, which
  rewrites `config.toml`; gitlab-runner reloads it, no restart), and a new build replaces it `create_before_destroy`
  under the build's name (`runner-manager-<hash>`); `ci/policy.sh` refuses a plan that would destroy it first; each
  apply's OpenTofu log is in its job's artifacts. Tested: the policy, the startup script and its watcher (stubs), the
  plan (mock providers: a config change keeps the name, a build changes it). Not yet seen live: the first apply of
  it replaces the manager once (new name), and that apply's own job dies when the old manager goes (README, Never
  without a manager). Its first `plan:ci` failed with a cycle (#47): the crashed apply of 2026-11-12 left a deposed
  manager, and the old manager's stored dependencies name `terraform_data.manager_config`, which #46 removed; its
  destroy, the deposed manager's and the pools' templates and groups closed a loop. A `removed` block now forgets it
  (no remote object) instead of destroying it; `tests/ci_plan_test.sh` plans the stack with its real provider against
  a stub API from that state (no cycle; the cycle without the block). Not yet seen live: `plan:ci` and `apply:ci` on
  main from the real state.
- **A zone out of capacity stalls no build (#49):** on 2026-11-12 spot t2a ran out in us-central1-b and the build pool's
  one VM stayed `CREATING` for hours, every build behind it. The build pool is now a regional group over us-central1-a,
  -b and -f (the zones with t2a), target shape `ANY` (each new VM where there is capacity; redistribution off), the
  plugin pointed at the region; on demand since #55. Spread rather than an on-demand fallback (README, The pools: on-demand t2a
  in -b was out too that day). The manager's reaper (`runner-reap`, beside the watcher) deletes any pool's VM creating
  on a capacity or quota error for five minutes, so the autoscaler's next one is made where there is room, instead of
  the group retrying it forever. Tested: the plan (mock providers: the regional group, its zones and shape, the
  plugin's region, the reaper's groups in the metadata), the reaper against stubs. Not yet seen live: the first
  `apply:ci` replaces the zonal `runner-build` group (and its stuck VM) with the regional `runner-build-region` (its
  first try, of 580d4ca, failed 409: the regional group's per-zone groups took the zonal one's name; c9dc2bc renamed
  it), and the manager (a new
  startup script: a new build); whether GCP deletes a VM still creating on a stockout, as the reaper asks, shows only
  then.
- **No job lost to a new manager (#48):** #46's first replacement (pipeline 3060348536, 2026-11-12) killed every looper
  job: the new manager's gitlab-runner removed every pool VM it had not created (`no data on pre-existing instance so
  removing for safety`), and the apply deleted the old manager; the groups kept creations stuck on the old fleet's
  `QUOTA_EXCEEDED` (#29). The #49 apply (pipeline 3061478514) did it again, and died itself: it ran through the old
  manager, which it deleted (`Plugin did not respond`). Now the old one drains first and the new one starts on empty
  groups (README, No job lost to a new manager): the stack forgets a manager instead of deleting it (`destroy = false`,
  deposed ones too); the new one's startup script tells each older one to retire (metadata `runner-successor` and its
  own startup script, so a pre-#48 manager's watcher runs the retirement), waits until none is left, empties the
  pools' groups (`runner-groups`, zonal or regional) to no instance at all, then starts gitlab-runner; a retiring one
  stops gitlab-runner on SIGQUIT (no new job, its running ones finished with no time limit, the apply's own among
  them; the signal gitlab-runner's alone, `KillMode=mixed`, so its fleeting plugin serves them to the end) and deletes
  its VM. While the old one drains no new job starts. `ci/policy.sh` refuses a plan destroying a manager at all and a
  source without `destroy = false`. Tested: the startup script and `runner-retire` against a stub Compute API, the
  policy, the plan tests and `tests/ci_plan_test.sh` (the old and deposed managers forgotten). Seen live on
  2026-11-13: pipeline 3062392842 created runner-manager-4c24f5f4 at 01:19Z, which told runner-manager-e66cee62 to
  retire and waits for its jobs, none killed; but e66cee62's oldest jobs (repository managers, 11-hour timeout) held the
  whole fleet for hours, hence #51.
- **The handoff capped (#51):** a new manager takes jobs at most `manager_handoff_minutes` (30, `stacks/ci`; metadata
  `runner-handoff-limit`) after its handoff began (kept in `/var/lib/runner-handoff/since` across its startup script's
  re-runs): it tells each older one when its drain ends (`runner-drain-until`, 12 minutes before the cap since #54), and deletes
  one still there 2 minutes before it. `runner-retire` drains until then, then cuts the jobs still running (SIGTERM
  to gitlab-runner alone: aborted and failed as `runner_interrupted`; tacplus-dev/looper's kicker starts them again,
  as its jobs' retry does not name that reason), kills
  gitlab-runner a minute later if it has not stopped, and deletes its VM; a retiring manager's startup script
  restarts `runner-retire`, so one draining from before #51 takes the end too. Tested: `tests/manager_startup_test.sh`
  (a drain that ends early, one that hits the cap, on both managers' side) and the plan tests (the setting; the new
  build runner-manager-3daaeddf). Not yet seen live: the first apply of it creates runner-manager-3daaeddf and caps
  the drain of 4c24f5f4 and e66cee62 (whichever are left); that the cut jobs fail as `runner_interrupted` (gitlab-runner
  19.5.3's source says so) and the kicker starts them again shows only then (since #54, the build it applies is
  runner-manager-3c8d4bad).
- **The build pool made no VM (#53):** from about 10:25Z on 2026-11-13 every build job logged `unable to acquire
  instance within the configured timeout of 15m0s`, after the 3-hour tacplus full gates lost their VM at 10:26:40Z,
  most likely reclaimed. Not confirmed: nobody but the pipeline reads the ci project's groups. The groups repaired a
  VM they did not stop (GCP's default), recreating a reclaimed spot VM in its own zone, retried there while that zone
  is out, counted by the autoscaler as coming, and the reaper took creations only. Now every group's
  `instance_lifecycle_policy` does nothing on a failure (`DO_NOTHING`, the fleeting plugin's recommendation: it
  deletes the stopped VM and the autoscaler's next one goes where there is room), and the reaper also deletes a VM
  *recreating* on a capacity or quota error (a new manager build, runner-manager-3c8d4bad since #54: its handoff empties the
  groups, a stuck recreation too). Where a report reads the reason: the drift job's pool check (`ci/pools.sh`), in
  the drift issue: each VM a group cannot make with its error, a stopped VM it keeps, each group's errors of the last
  24 hours by error and zone, and every quota of us-central1 and the project 80% used or more; nightly, or now by
  running the drift schedule. Tested: the plan tests (mock providers: the policy on both kinds of group, the new
  build's name), `tests/manager_startup_test.sh` (a recreation reaped), `tests/pools_test.sh` (a stub gcloud). Not
  yet seen live: `apply:ci` (in place for the groups; the new manager and its handoff), and the first pool report.
  Then (13:35Z, 14:38Z) jobs dialed two build VMs for 10 minutes each, round after round: read by the hub at 15:55Z,
  `6851fa60cf6e5288` was not dead but repaired, recreated by its group at 13:34Z under its name at a new address
  (10.10.15.199), while the old manager kept dialing the old one (10.10.0.59); with `DO_NOTHING` (applied 15:43Z) a
  group no longer recreates a VM. And the quota, not spot capacity, holds the pools back: CPUS_ALL_REGIONS is 32 in
  tacplus-ci (the settings said 48), and the configured pools need 45 to 46 CPUs (shared 3x8, build 2x8, cluster 4,
  the managers 1 to 2): the second build VM stays `CREATING` on `QUOTA_EXCEEDED` (15:48Z) whenever the cluster runner
  is up, the shared pool at 2 of 3. The reaper deletes it after 5 minutes, and the next one fails the same way until
  CPUs are free.
  Since #55 the pools fit 32: the shared pool is one always-on VM, deploy a t2a-standard-2 and the build pool on
  demand (five build VMs preempted on 2026-11-13, the tacplus full gates never finishing), 32 at peak with two
  managers, and the ci stack's test refuses pools over `ci_cpus.quota` (32). Not yet seen live: `apply:ci` of it (the
  shared group down to one VM, the build and deploy templates replaced; no new manager).
- **No job left running by a handoff (#54):** #51's first real cut (the re-pin to a9ee214, 2026-11-13 12:37Z) failed
  20 looper jobs as `runner_interrupted`, retried by nothing but the kicker's next hourly pass, and left 31 looper and 8
  build jobs `running`, holding their resource groups until the hub force-cancelled and retried them by hand:
  gitlab-runner, cut, exited after its default `shutdown_timeout` (30 seconds) before reporting most of them, and a
  job still waiting for a VM never sees the abort. Now the cut has room to report (`shutdown_timeout = 420`;
  `runner-retire` kills after 480 seconds; the drain ends 12 minutes before the cap, the variable's floor 17), and the
  cloud pipeline's `handoff` job (`ci/handoff.sh`), 35 minutes after `apply:ci`, on the new manager, cancels (by force
  once `canceling`) and retries every job still `running` or `canceling` on another manager of the fleet's runners,
  and retries each job failed there as `runner_interrupted` since its pipeline began and not run again yet, with the
  gitlab stack's token (README, A handoff with jobs in flight: the drill). GitLab's `retry: when: runner_interrupted`
  would retry a cut job at once; tacplus-dev/looper's jobs do not name it (PROPOSALS.md). Tested: `tests/handoff_test.sh`
  against a stub GitLab API, `tests/manager_startup_test.sh` (the windows), the plan tests (the config; the new build
  runner-manager-3c8d4bad), `tests/ci_test.sh` (the job). Not yet seen live: the next new build's handoff, and that
  the token may retry jobs on tacplus-dev/looper's protected main and environments.
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
- **The fleet's CA and crypto file in Secret Manager (#28; Jody's option D, fleet-seatrials#44):** the dev stack's
  `fleet-secrets.tf`, from a `deployments` entry's `init_secrets`: the secrets `fleet-ca-seatrials` and
  `fleet-crypto-seatrials` (us-central1, no version), the account `seatrials-init-secrets`, which only fleet-seatrials'
  jobs in the environment `init-secrets` on protected main become, holding `secretVersionAdder` and `viewer` (metadata:
  whether a version exists) on them and no role on the project, and `secretAccessor` for `seatrials-deploy` alone
  (authoritative bindings; output `deployments` `fleet_secrets`). No GitLab token, no bot user, no `FLEET_INIT_TOKEN`
  (gitlab.com Free has no project access tokens). Tested with the dev stack's plan tests (mock providers); not applied
  yet: `apply:dev` on main does it, then fleet-seatrials#44's job adds the versions.
- **The test IdP's certificate and seeds (#32; fleet-seatrials#27):** the `deployments` entry's environment account
  `test-idp-deploy` gets, from `environment_certificates` (`test-idp = "idp.test.tacplus.dev"`, which `*.tacplus.dev`
  does not cover), the secrets `tls-test-idp` and `acme-account-test-idp` (us-central1) and the zone
  `acme-challenge-idp-test-tacplus-dev` for `_acme-challenge.idp.test.tacplus.dev.` (DNSSEC on), delegated from
  `tacplus-dev` by NS, and, from `environment_secrets`, the secret `test-idp-seeds` (no `TEST_IDP_GITLAB_TOKEN`: as
  #28); it alone adds and reads their versions and administers the zone (authoritative bindings), seatrials-deploy holds
  nothing on them, and it holds no other role but get-credentials. The module refuses a certificate or secrets for an
  environment with no account, two certificates on one domain and two secrets with one ID. Output
  `deployments.seatrials.environment_certificates` and `environment_secrets` name them. The listener `test-idp` stays
  `ready = false` until its NEG exists: the first test-idp run, which needs these, makes it. Tested with the dev stack's
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
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none. OpenTofu, the google
  provider, tflint and its ruleset carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md).
- **Security job (#10):** `security` (`ci/security.sh`), on every push, merge request and nightly, before `plan:folder`:
  OSV-Scanner on the tree, `govulncheck -mode=binary` on every pinned binary (the tools, the scanners, both providers,
  GitLab Runner and its plugin), gitleaks on the tree and its full history, Trivy on the CI image; looper-scan's policy,
  `security-exceptions.yaml` enforced (an expired entry fails); its report `security/report.json`, the artifact. Its
  first run here passes: the CI image's 223 fixable HIGH/CRITICAL findings fixed by its new digest, the scanners'
  standard library ones by building them with the latest Go (go1.27.4 since #39), gitleaks' xz (GO-2025-3922) accepted until **2026-12-04**. On build:2.6 (#22) the image had one, its `gh`'s x/net
  CVE-2026-78661, accepted (#27) until build:2.6.10 (#43) fixed it with zlib's and dropped OpenEXR (tacplus-dev/tacplus#554):
  on that digest the security job passes, 0 failing findings (run here 2026-11-12); #23's (kin-openapi) are fixed by the kubernetes
  provider's build, and #24's by building gitleaks and OSV-Scanner with the fixed klauspost/compress (GO-2026-6865) and
  brotli (GO-2026-6888), GO-2026-6865 in the downloaded OpenTofu and Trivy accepted until **2026-12-06**; GitLab Runner and its plugin, built here (#40), have no entry.
  Tested by `tests/security_test.sh` (a planted secret, in the tree and in history, an expired exception, a clean tree,
  the policy) with stubs for OSV-Scanner, govulncheck and Trivy; never run in GitLab yet (no pipeline has run).
- **Pinned for the build pipeline (#25; looper#71, #84):** `build.lock` names the CI image by digest (build 2.6.10's, #43)
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
  `stacks/gitlab/nightly-builds.yaml` (inputs `repo`, `nightly: true`; tacplus-dev/looper, 05:00 UTC; tacplus-dev/website, pinned by its `build.lock`, 06:00 UTC, #31). Tested with the
  stack's plan tests (mock providers), the stub-API plan with the real provider (`tests/gitlab_plan_test.sh`),
  `tests/build_ci_test.sh` (stub curl) and `tests/expiry_test.sh`; not applied yet: `apply:gitlab` on main does it, and
  whether GitLab takes the schedule's boolean input as the string `true` the provider sends, and the first nightly of
  looper, show there.
- **tacplus-dev/build's runner settings (#35):** a project whose jobs are tagged `build` (or any tag only tacplus-dev's
  pools serve) needs **group runners on**: the pools are tacplus-dev group runners, and a project with
  `group_runners_enabled=false` never gets one, its jobs failing `stuck_pending_no_matching_runners` after about 1.5 h
  (tacplus-dev/build until the hub's hand change of 2026-11-09; tacplus-dev/looper#113). The gitlab stack owns
  tacplus-dev/build's (`gitlab_project.build`, `modules/gitlab/build.tf`): group runners on, gitlab.com's shared runners
  off, the project adopted by its ID with `prevent_destroy` and every other attribute ignored. Tested with the stack's
  plan tests (output `build_runners`) and the stub-API plan (adopted with no change at the hand-set value; with group
  runners off, the plan turns them on and nothing else); not applied yet: `apply:gitlab` on main, and a build job
  taken by the shared pool, show there.
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
  passes); it now names each attribute that differs, the Console's value and the config's, so the next plan says what
  to write. The narrowing of seatrials' rule to `workspace:inference` is the commit after the adoption.
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
  jody1-328023 is #15; the runner pools' removal is #11 (No VMs outside GKE).
