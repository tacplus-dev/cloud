# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-24 by the looper (#106).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.6` by digest, its digest of 2026-11-24 (build:20261123-57a6521, #104; before it
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
  `bin/providers` (`ci/tofurc.sh`) and locked by their own hashes. GitLab Runner v19.6.0 (#99) and
  the fleeting plugin v1.3.1 are built here with go1.27.4 too (`ci/runner.sh`, #40): GO-2026-6859 has no exception.
- **Works (#1):** `bootstrap/bootstrap.sh` (the folder and project `bootstrap`, the state bucket,
  `cloud-admin-pipeline` with its rights and its WIF from `tacplus-dev/cloud`'s protected main, the empty secrets;
  idempotent, refuses what differs, `--dry-run`; reads a folder listed by its bare ID as gcloud now lists it, #14); the stacks `folder` (folders `ci` and `dev`, readers), `ci` (runner manager VM, the arm64 pools as MIGs (#5, below), runner token secrets, the build
  cache, the GitHub Apps' import-only KMS keys and their federation, #19 below), `dev` (GKE Axion cluster, private COS nodes in a normal, a spot and a looper pool (#7, #95, below), `dev.tacplus.dev` zone,
  `cluster-admin-pipeline` for tacplus-dev/cluster) and `gitlab` (this project's protected main, environments and
  variables from Secret Manager by version; the pools' runners, and the in-cluster `infra` runner, #64, unpaused at the switch-over, #66, which paused the `cluster` and `deploy` pools, and `kick`, #81, `build-report`, #93, `build-light`, #100, and `manager`, #106, runners); the GitLab pipeline (checks on every
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
- **Runner image and readiness (#4):** the pools boot Container-Optimized OS for arm64, pinned by image name in
  `modules/settings` (`cos_arm64_image`, never a family: the module and `ci/policy.sh` refuse one), vanilla
  (`decisions/builds-in-containers-2026-11-03.md`): no startup-script, nothing installed at boot, OS updates off, the
  OS's own Docker. Every pool waits, bounded to ten minutes, until the connecting user's Docker has pulled the helper
  image by digest, each pull bounded to two minutes (`instance_ready_command`; #61: the job's first step through the
  daemon's own path, since #50's HTTPS answer from the VM still let a fresh VM's first job time out pulling it, twice on
  2026-11-14). A pool's `[runners.autoscaler]` but its policy is the manager's build (#61): gitlab-runner 19.5.3 reads it
  once and a reload changes only the policy, so #50's check, pushed in place, was not live until a restart; a change to
  it is now a new manager (runner-manager-9c4d2d4d, a 30-minute handoff at apply). Cloud NAT `runners` logs its errors
  (`ERRORS_ONLY`, #61). No baked image and no bake identity (superseded). Tested against mock providers only (the plan
  tests); not yet seen live: three cloud pipelines in a row passing `tools` on fresh VMs, which the hub reports on #61.
- **Shared pools and the build cache (#5):** three pools (README, The pools): `shared`, one always-on t2a-standard-8
  one always-on t2a-standard-8 (three until #55) with no slots since 2026-11-10 (Jody: every looper runs when it wants; a second VM on demand past 13 jobs since #63; up to 13 jobs a
  VM, each may use the whole VM), on a 154 GB pd-balanced disk since #63 (350 GB pd-standard until then: on 2026-11-15 its IO, at the cap under 24
  jobs, stopped Docker answering `containers/create` and every job placed on the full VM failed `runner_system_failure`; the VM up at the time keeps
  its disk until replaced; the ci stack's test keeps the SSD-backed disks under `SSD_TOTAL_GB` 500, `ci_disks`: 498 at peak), every looper and control job, a tacplus-dev group runner tagged `arm64`,
  `autoscale`, `autoscale-16`; builds on the `build` pool, one on-demand t2a-standard-8 from zero (two until #63; spot until #55), four builds at a time,
  tagged `arm64`, `build` and `build-docker` (#70: the jobs that still need host Docker); `deploy` and `cluster`, protected and on demand. Job containers
  share reused VMs, no privileged mode, no host Docker socket, containers and volumes discarded per job; disk bounded
  per VM, not per job. The cache: `gs://tacplus-ci-build-cache` and the registry `build-cache`, only
  `build-cache@tacplus-ci` holding a role on them, federated from tacplus-dev/build's jobs only; entries deleted
  after 30 days. A pool's group, zonal or regional, replaces its VMs proactively on a template change, no surge
  (#29): one still creating on an old template, which OPPORTUNISTIC retried forever, and a running one on the template
  it booted, both go; all of a pool's VMs may go at once, their jobs with them. Not yet seen live: the first `apply:ci`
  of it sets the policy on the live groups. Plan tests cover the cache's IAM, the federation, the lifecycles, the
  pools' settings and the groups' update policy, against mock providers only.
- **The manager's binaries (#40):** GitLab Runner v19.6.0 (#99, its OpenTelemetry v1.47.0, GHSA-q7gw-24fr-5p69; since
  #44 the release tacplus-dev/cluster runs, cluster#21, which moves to v19.6.0 in cluster#52: until then the cluster runs
  19.5.3) and the fleeting plugin v1.3.1 built here with go1.27.4 and at least x/net v0.62.0, klauspost/compress v1.20.2
  (the runner's own v1.20.3) and go-jose v4.1.6,
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
  19.5.3's source says so) and the kicker starts them again shows only then (since #61, the build it applies is
  runner-manager-9c4d2d4d).
- **The build pool made no VM (#53):** from about 10:25Z on 2026-11-13 every build job logged `unable to acquire
  instance within the configured timeout of 15m0s`, after the 3-hour tacplus full gates lost their VM at 10:26:40Z,
  most likely reclaimed. Not confirmed: nobody but the pipeline reads the ci project's groups. The groups repaired a
  VM they did not stop (GCP's default), recreating a reclaimed spot VM in its own zone, retried there while that zone
  is out, counted by the autoscaler as coming, and the reaper took creations only. Now every group's
  `instance_lifecycle_policy` does nothing on a failure (`DO_NOTHING`, the fleeting plugin's recommendation: it
  deletes the stopped VM and the autoscaler's next one goes where there is room), and the reaper also deletes a VM
  *recreating* on a capacity or quota error (a new manager build, runner-manager-9c4d2d4d since #61: its handoff empties the
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
  runner-manager-3c8d4bad), `tests/ci_test.sh` (the job). Its first live run (2026-11-14, pin b83660e) ran the cut
  jobs it reached again, then failed on GitLab's rate limit (HTTP 429 on 18 calls, #57): it now waits a 429 out
  (`Retry-After`, or backing off) within the job's time limit, asks only about the managers of this handoff (contacted
  since an hour before its pipeline), and reads every page of a manager's failed jobs back to a day before the
  pipeline (it stopped after the first). Not yet seen live: a handoff since #57, and that
  the token may retry jobs on tacplus-dev/looper's protected main and environments.
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
  proxy-based), any rule allowing port 22 in either direction but the runners' internal `runner-manager-to-workers-ssh`
  exactly as it is (it goes with #11), a cluster without private nodes and a pool with public nodes or not
  `COS_CONTAINERD` (README, The network rules). The IAP SSH rule is gone from `ci`. In `dev`, the `arm64` pool is
  replaced by `normal` (3 x c4a-standard-2, on demand, fixed) and `spot` (c4a-standard-4 spot, 0 to 3, label `spot=true`,
  taint `spot=true:NoSchedule`, given in the stack's output `cluster` for tacplus-dev/cluster#6), both private and
  `COS_CONTAINERD`; the control plane was public then (Jody, 2026-11-04), private since #79 (below). `compute.vmExternalIpAccess` (deny all) is on the README's list
  of the host's org policies (since #8 this repository sets none). The drift job runs a live audit (`ci/audit.sh`) of
  `tacplus-ci` and `tacplus-dev` with the same checks, for what no state holds; GKE's own internal `gke-*` rules are not
  reported for port 22. Tested with plan and live fixtures and the stacks' plan tests, against mocks and a stub gcloud
  only; the runner VMs are not spot (moot: they go with #11).
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
- **The looper pool (#95):** looper runs were capped at 12 by the normal pool's room, all full for 30+ minutes on
  2026-11-22. A third pool, `looper` (the decision's addendum of 2026-11-22): c4a-standard-2 on demand (a looper run
  lasts hours; spot would preempt it) in us-central1-a, from 0 to 2 (`total_min_node_count` 0, `total_max_node_count`
  2: at most the $130/month Jody approved; a larger maximum needs Jody's yes), labelled `looper=true` and tainted
  `looper=true:NoSchedule`; the output `cluster` gives the label and taint (`looper_label`, `looper_taint`) for
  tacplus-dev/cluster#47, whose control runner's job pods tolerate it. The quota preferences count it: 40 C4A CPUs
  (6 + 20 + 4 + one c4a-standard-4 being replaced, 34; the issue's 30 left out that node) and 1500 GB of Hyperdisk
  Balanced (11 x 100, 1100): the 40 may wait on Google's review, and 30 (every pool at its maximum, no node being
  replaced) fit the 32 granted. The plan checks and the live audit pass the three pools and still refuse a short
  preference or a public pool; the hub's audit shows an autoscaled pool's minimum 0 (GKE's JSON leaves it out, so it
  showed none). Tested with the dev plan test (mock providers), the policy's, audit's and hub audit's fixtures; not yet
  seen live: `apply:dev` making the pool with 0 nodes, the audit's Node pools table showing it, and a looper run on
  it once tacplus-dev/cluster#47 lands.
- **The build pool to 8 (#96; Jody, 2026-11-23):** on 2026-11-22 `spot` sat at its 5-node maximum with 18 builds
  queued, a tacplus batch candidate waiting 1h17m. Its maximum is now 8 (c4a-standard-4 spot, still from 0, still over
  the region's zones), and the quota preferences follow from it: 48 C4A CPUs (6 + 32 + 4 + 4 = 46, with the looper
  pool's 2 x 2, #95) and 1500 GB of Hyperdisk Balanced (14 x 100 = 1400). Tested with the dev plan test (mock
  providers); not yet seen live: `apply:dev`, Google granting the increase (the pool grows as it is granted), then more
  than 5 build nodes at once.
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
  reader's two variables, and the pools' runners and the `infra` (#64), `kick` (#81), `build-report` (#93), `build-light` (#100) and `manager` (#106) runners with their token versions.
- **The cluster pipeline's rights on dev, by this pipeline (#18):** the dev stack makes the secrets `gitlab-runner-build`,
  `gitlab-runner-control`, `gitlab-runner-infra` (#64), `gitlab-runner-kick` (#81), `gitlab-runner-build-report` (#93), `gitlab-runner-build-light` (#100) and `gitlab-runner-manager` (#106; us-central1, empty; `secretAccessor` for `cluster-admin-pipeline` alone, `secretVersionAdder`
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
  The module's `runners` take an optional `description` (a pool's stays the manager's); the stack's output `runners`
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
- **The switch-over to `infra` (#66; tacplus-dev/cluster#25):** `stacks/gitlab/main.tf` unpauses `infra` and pauses the
  `cluster` and `deploy` pools' runners (`contains(["cluster", "deploy"], k)`); `shared` and `build` take jobs. Tested:
  the gitlab stack's plan test and `tests/gitlab_plan_test.sh` assert which runners are paused. Its `apply:gitlab` on
  main does it; then one cloud and one cluster pipeline green on `infra` (the hub, on #66), then #11 removes the pools'
  runners and VMs. If `infra` takes no job: README, The cluster pipeline, the break-glass.
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
  (discovery), admitting `spiffe://local.dev/system/services/admiral` alone, its audience the provider's own. The ci
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
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none; of the google
  provider's, none since #76 (x/crypto v0.59.0, GO-2026-5932). OpenTofu, tflint and its ruleset carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md). x/net html's GO-2026-6860 and GO-2026-6866 name OpenTofu and the ruleset only since
  tflint 0.66.0 and Trivy 0.76.2 (#62). OpenTelemetry Go < v1.47.0 (GHSA-q7gw-24fr-5p69, MODERATE, no Go vulndb id, so
  the security job does not see it; the nightly scan found it, #99) in OpenTofu, tflint, its ruleset, OSV-Scanner, Trivy
  and the fleeting plugin, whose latest releases still have it: accepted until **2026-12-23** (Jody, #99); GitLab Runner
  is past it (v19.6.0, `tests/security_test.sh` checks its build). GO-2026-6975 (otel < v1.47.0, W3C baggage) in
  OpenTofu, tflint, its ruleset and Trivy, and GO-2026-6984 (saracen/fastzip v0.2.0) in our GitLab Runner v19.6.0 build,
  both published 2026-11-23 with no tool release fixing them, turned the hub's security job red (#103): accepted until
  **2026-12-08**, each entry scoped by `where` to its binary (Jody's decision, CI tooling never blocks).
- **Security job (#10):** `security` (`ci/security.sh`), on every push, merge request and nightly, before `plan:folder`:
  OSV-Scanner on the tree, `govulncheck -mode=binary` on every pinned binary (the tools, the scanners, both providers,
  GitLab Runner and its plugin), gitleaks on the tree and its full history, Trivy on the CI image; looper-scan's policy,
  `security-exceptions.yaml` enforced (an expired entry fails; one with a `where` accepts its id only there, #103); its
  report `security/report.json`, the artifact. Its first run here passes: the CI image's 223 fixable HIGH/CRITICAL findings fixed by its new digest, the scanners'
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
  brotli (GO-2026-6888), GO-2026-6865 in the downloaded OpenTofu and Trivy accepted until **2026-12-06**; GitLab Runner and its plugin, built here (#40), have no entry for it.
  Tested by `tests/security_test.sh` (a planted secret, in the tree and in history, an expired exception, a clean tree,
  the policy, a `where`) with stubs for OSV-Scanner, govulncheck and Trivy; never run in GitLab yet (no pipeline has run).
- **Pinned for the build pipeline (#25; looper#71, #84):** `build.lock` names the CI image by digest (build:2.6's 2026-11-23 rebuild, #97)
  and `gates.yaml` its one set, full (`ci/tools.sh && ci/lint.sh all && ci/checks.sh`), so tacplus-dev/build builds
  this repository in that image, with no Docker, and runs its security checks; `tests/ci_test.sh` refuses a
  `build.lock` that is not the CI file's `default.image`. Builds of main run from the pin and report since
  tacplus-dev/looper#113 (2026-11-15): ca0e523's, pipeline 3070014440, green on the gates full, its security report one
  LOW semgrep finding (`ci/lib.sh:64`, IFS set globally), none failing the policy.
- **tacplus-dev/build's trigger and nightly schedule (#26, #67; looper#71, #84, #164):** the gitlab stack's `build`
  (`modules/gitlab/build.tf`): tacplus-dev/build's `.gitlab-ci.yml`, tacplus-dev/looper's `ci/build.gitlab-ci.yml` at
  `build_ci_commit` (3ed6045 since #92: looper#221's image 790b7849, with looper#207's side-by-side scanners
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
  more than 10 at plan. Tested with the stack's plan tests (mock providers), the stub-API plan with the real provider
  (`tests/gitlab_plan_test.sh`), `tests/build_ci_test.sh` (stub curl) and `tests/expiry_test.sh`; not seen yet:
  `apply:gitlab` on main of #67 (its in-place change, and which of the ten exist live), and the first fan-out nightly.
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
  passes); it now names each attribute that differs, the Console's value and the config's. The third (pipeline
  3066773640, job 18022609528) listed them: the account's and the rule's descriptions, the rule's audience and its token
  lifetime (600, not the default 3600), written as the Console holds them. The fourth (pipeline 3067066143, jobs
  18024991251/2, 2026-11-14) adopted with no change: 3 imported, the membership added. seatrials' rule is now narrowed
  to `workspace:inference` in a commit of its own (an update in place, the same ID), applied by the next pin.
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
