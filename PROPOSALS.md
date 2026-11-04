# Proposals: cloud

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

- **The bootstrap's own resources under the pipeline** (looper, #1, 2026-11-03). What: `import` blocks bringing the
  folder `bootstrap`, `tacplus-bootstrap`, the state bucket, `cloud-admin-pipeline`, its WIF pool and provider and its
  rights into a stack. Why: today the nightly drift does not see them, so a hand change to the pipeline's own identity
  would go unnoticed; the bootstrap script stays the way they are first made.
- **Pin the dev cluster's GKE version** (looper, #1). What: an explicit `min_master_version` and node version, or a
  maintenance exclusion, with upgrades as commits; and, once the version is known to be 1.36.4 or later, create the
  cluster without a default pool (`initial_node_count = 0`) instead of `remove_default_node_pool`, which google 8.x
  deprecates. Why: the release channel picks the version at creation and upgrades it unasked, which the
  deterministic-deployments rule does not allow for what we deploy on it.
- **Restart the runner manager when a token changes** (looper, #1). What: the manager reads its pools' tokens from
  Secret Manager at boot only; a re-registered runner (the gitlab stack replaces the token's version) needs the
  manager's config re-rendered: a systemd timer comparing versions, or the gitlab stack resetting the VM. Why: otherwise
  a re-registration leaves the pool on a dead token until someone reboots it by hand.
- **Readers' accounts** (looper, #1; since #8, of the host's directory). What: accounts for Jody's daily use, the hub
  and the loopers in a directory the host organization's domain-restricted sharing admits, and their `readers` entries
  (`stacks/folder`). Why: the gmail accounts and jody1-328023's service accounts used today cannot be readers; until
  then nobody but the pipeline and break-glass sees the parent folder.
- **Remove the organization's default grants** (looper, #1): the host organization's job since #8 (README, What the
  host organization provides); nothing to do here.
- **The in-cluster grant of cluster-admin-pipeline in dev** (looper, #1). What: its ClusterRoleBinding of
  `cluster-admin` on the dev cluster, made by a pipeline (a kubernetes-provider stack here, or tacplus-dev/cluster's
  bootstrap) rather than by the hub by hand. Why: today GCP grants it only `container.clusterViewer`; the binding is the
  hand step tacplus-dev/cluster's README lists, which the move of the cluster to dev would repeat.
- **Secret values out of plans and state** (looper, #1). What: the gitlab stack's variables and the runner tokens
  through write-only attributes or ephemeral resources, once both providers offer them for these resources. Why: today
  the values are in the saved plan (an artifact, members only) and the state (the bootstrap bucket).
- **Data Access audit logs on the parent folder** (looper, #1; the folder's since #8). What: a folder-level audit
  config (`google_folder_iam_audit_config` on the parent folder) for IAM and Secret Manager reads, in the folder stack,
  unless the host sets it above. Why: break-glass and the pipeline's secret reads are then traced beyond Admin
  Activity.
- **Deterministic security checks in this pipeline** (nightly scan, 2026-11-03): done by #10 (the `security` job,
  `ci/security.sh`; the runners' default image is not scanned: the runners go with #11). What: a `security` job, run on every
  push and nightly, applying tacplus-dev/looper#49's floor to what this repository pins: `govulncheck -mode=binary` of
  the tools (`ci/tools.sh`), both providers (from the lock files), GitLab Runner and its fleeting plugin; Trivy on the CI
  image and the runners' default image; a checked-in `security-exceptions.yaml` with expiries; its JSON report as an
  artifact; and a "Security checks" section in the README. Why: cloud runs its own GitLab pipeline, not
  tacplus-dev/build's, so looper#49's checks never reach it; today only the nightly agent scan sees these, and it
  found 23 known vulnerabilities in the gitlab provider alone (#3).
- **Track and bump the pins with known vulnerabilities** (looper, #3, 2026-11-03). What: move each to the first
  upstream release that fixes its `security-exceptions.yaml` entries, and remove them: OpenTofu past 1.13.2 (x/net
  >= v0.62.0, grpc >= v1.83.2, x/mod >= v0.40.0, x/crypto past v0.58.0), the `google` provider past 8.9.0 and tflint past
  0.65.0 with its ruleset past 0.41.0 (x/net >= v0.62.0, x/crypto), GitLab Runner past v19.5.2 and
  fleeting-plugin-googlecloud past v1.3.1 (x/net >= v0.60.0), gitleaks past v8.30.1 (github.com/ulikunitz/xz >= v0.5.15,
  GO-2025-3922, accepted until 2026-12-04, #10); `ci/tools.sh` shas and sums, `ci/lock.sh`, `stacks/ci/main.tf`.
  Why: the exceptions expire on 2026-12-03 (Jody's decision on #3: 30 days); after that each needs a bump, a build
  from source like the gitlab provider's, or a new decision.
- **Drop the gitlab provider's build from source** (looper, #3). What: when gitlabhq/terraform-provider-gitlab
  releases a version built with go >= 1.26.10 and x/net >= v0.62.0, pin it from the registry again: remove
  `ci/gitlab-provider.sh` and `ci/tofurc.sh`, their calls (`ci/tools.sh`, `ci/lock.sh`, the scripts sourcing tofurc) and
  `tests/providers_test.sh`'s provider checks, and run `ci/lock.sh`. Why: the build costs every `tools` job a Go build
  and a fetch from gitlab.com, and it is ours to keep current; upstream's signed release is the normal path. Upstream
  has not been asked yet: its issues are on gitlab.com (gitlab-org/terraform-provider-gitlab; the GitHub mirror takes
  none), and this run had no gitlab.com account; the request is drafted on #3 for the hub to file.
- **Enforce the exceptions' expiry** (looper, #3): done by #10 (the `security` job, not `ci/checks.sh`). What: the security job of the deterministic checks above fails on
  an expired `security-exceptions.yaml` entry, as looper-scan does; today `tests/providers_test.sh` checks only its
  form. Why: an expiry nothing enforces is a note, and a date check in `ci/checks.sh` would make the same commit pass
  one day and fail the next, which the plan and apply gates should not.
- **The bake opens its bump; never delete the pinned image** (looper, #4, 2026-11-03): superseded 2026-11-03 by
  `decisions/builds-in-containers-2026-11-03.md` (no baked image: the pools boot pinned Container-Optimized OS).
- **No host Docker socket in the pools' jobs** (looper, #4, 2026-11-03): done by #5 (the socket is gone from every pool). What: drop
  `/var/run/docker.sock:/var/run/docker.sock` from `files/config.toml.tftpl`'s volumes once looper's build jobs replace
  `looper-docker` and the host-socket gates. Why: `decisions/builds-in-containers-2026-11-03.md` gives an agent
  container no container runtime and no host socket, and image builds run in rootless BuildKit; today every job of
  every pool can still drive the VM's Docker. Kept for now: the jobs that use it change first (the decision's
  follow-up issues), and the pools stay paused until the runners move.
- **Tell when the pinned COS has a newer build** (looper, #4). What: the nightly drift job also lists `cos-cloud`'s
  images of the pin's LTS family (`cos-arm64-<milestone>-lts`) and files an issue when a newer build than
  `cos_arm64_image` exists, naming it and its release notes. Why: COS's security fixes ship as new builds; with the pin
  by name (and updates off), the workers keep the old kernel and runtime until someone bumps it, and nothing says when.
- **Per-job disk limits** (looper, #5, 2026-11-03; option (b) on #5). What: an XFS data disk for Docker's
  `/var/lib/docker`, mounted with `pquota` at boot (cloud-init on COS), and the readiness gate also checking the backing
  filesystem, so the runners' `storage_opt size` gives each job a disk limit. Why: today the disk is bounded per VM, so
  a job that fills it fails the jobs beside it; the decision on #5 kept the VM vanilla for now.
- **Reused VMs collect images** (looper, #5). What: bound what a reused VM keeps: a large `max_use_count` on the shared
  pool (the VM replaced after N jobs), or a pruning step the manager runs between jobs. Why: the always-on VM is never
  replaced, so every image a job pulls stays on its disk until it fills; the 50 GB set aside for images is a guess.
- **Replace the always-on VM on a bump** (looper, #5). What: a COS bump (or a change to the pool's template) also
  replaces the shared pool's running VM: the instance group's update policy, or a step in the apply. Why: with VMs
  reused, a VM already up keeps the image it booted, so the bump does not reach the always-on VM until it goes.
- **The rest of the job containers' hardening** (looper, #5). What: `cap_drop = ["ALL"]`, a non-root user and a
  read-only root where the jobs allow (`decisions/looper-job-per-issue-2026-11-03.md`: no capabilities, non-root,
  read-only root where possible), once the jobs' images are checked against them. Why: #5 removed the privileged mode
  and the host socket; Docker's default capabilities remain, which the decision asks to drop.
- **GitLab's own `cache:` in the build cache** (looper, #5). What: a `[runners.cache]` on the GCS bucket, so a job's
  `cache:` keyword survives its VM's volumes being discarded. Why: with `disable_cache`, a job's `cache:` is lost
  when the job ends, as it was with one job per VM; it would need an identity of its own on the manager, which the
  rule that only the build identity holds a role on the cache does not allow: a decision.
- **The move of seatrials' certificates to tacplus-dev** (looper, #6, 2026-11-03). What: when seatrials moves off
  jody1-328023, its pipeline switches to `seatrials-deploy@tacplus-dev`; the interim secrets' current versions are
  copied into `tacplus-dev`'s (the hub grants the new identity `secretAccessor` on the interim secrets for the copy, a
  pipeline job copies, the grant goes); `_acme-challenge.tacplus.dev.`'s NS records move to the new zone's name
  servers; the interim secrets and zone are deleted. Why: a zone and a secret cannot move between projects, and a new
  order would spend Let's Encrypt's duplicate-certificate budget (tacplus-dev/fleet-seatrials#4); written as a runbook
  with the move, or the dev stack's apply printing the steps.
- **The challenge zone's delegation in a stack** (looper, #6). What: the NS records of `_acme-challenge.<domain>.` (and
  `dev.tacplus.dev.`'s) made by the pipeline, once tacplus.dev's zone is under the parent folder. Why: today they are hand
  steps in jody1-328023, which the nightly drift does not see.
- **DS records for the delegated zones** (looper, #6). What: the challenge zone's (and the dev zone's) DS record in its
  parent, from the zone's DNSSEC keys. Why: both zones sign, but with NS records only the delegation is insecure, so
  resolvers do not validate their answers.
- **The 2026-11-03 network and node-pool rules in the stacks, and plan checks that refuse violations** (looper, #7,
  2026-11-03). What: the org policy `compute.vmExternalIpAccess` denied to all (since #8, the host organization's to
  set: README, What the host organization provides, lists it once it does); the IAP SSH rule removed from `ci` (the
  manager-to-workers rule: Jody's call, #7 Q1); the runner pools' templates on spot; in `dev`, the `arm64` pool
  replaced by `normal` (3 x c4a-standard-2, on-demand) and `spot` (spot, from 0, labelled and tainted `spot`), both
  `COS_CONTAINERD`; and `ci/policy.sh plan` refusing any instance or template with an access config, any 0.0.0.0/0
  ingress, any rule allowing port 22 and any cluster or pool without private nodes, with fixtures and stack tests. A
  tofu drift plan sees only what is in state, so hand-made additions need folder firewall policies or a live audit in
  the drift job (#7 Q7). Why: `decisions/network-exposure-2026-11-03.md` and `cluster-node-pools-2026-11-03.md` were
  applied by hand in jody1-328023; the pipeline must be the only agent of change, and `ci` and `dev` are built fresh.
  Links: #7 (design and Jody's seven questions on the issue).
- **`GCP_PARENT_FOLDER` adopted by the gitlab stack** (looper, #8, 2026-11-03). What: the gitlab stack manages the
  protected variable `GCP_PARENT_FOLDER` (from its own `parent_folder`, with an import block, as `GCP_WIF_PROVIDER`).
  Why: today the hub sets it by hand (README, Before the first pipeline) and the nightly drift does not see it.
- **The host's org policies checked, not only relied on** (looper, #8, 2026-11-03). What: the drift job reads the
  effective policies on the parent folder (`gcloud resource-manager org-policies describe --effective --folder`; if
  `roles/owner` on the folder does not read them, `orgpolicy.policyViewer` on it, a host's grant) and reports any
  that is not the README's set, without setting one. Why: since #8 the guardrails are the host organization's
  (decided: option B), so a change there would reach these projects unseen; the host's own drift check covers its side
  only.
- **Trivy on each platform of the CI image** (looper, #10). What: `ci/security.sh` scans the CI image's index for the
  runner's platform only (Trivy's default); scan each platform the index holds (`--platform linux/arm64`, then
  `linux/amd64`). Why: the jobs run on one platform today (arm64), but the image is multi-platform, and a job moved to
  the other would run in an image never scanned.
- **One security job for the three apply pipelines** (looper, #10). What: cloud, cluster and fleet-seatrials each run the
  same floor (tacplus-dev/cluster#5, tacplus-dev/fleet-seatrials#36); one shared job file (a GitLab `include` of a
  pinned commit) or looper-scan itself pinned into each `ci/tools.sh`, instead of three copies of the policy. Why: the
  suggestion (`suggestions/2026-11-04-...`) asked for one shared job; `ci/security.sh` copies looper-scan's policy and
  exceptions reader, which can drift from it.
- **A better scan of the tree's dependencies** (looper, #10). What: OSV-Scanner reads no file of this tree (OpenTofu's
  lock files are not a format it knows): the providers are covered by govulncheck on their binaries instead. If a
  manifest it reads is ever added (a go.mod, a Dockerfile), it is scanned with no change. Why: so that nobody reads
  "OSV-Scanner: no finding" as "the providers are clean".
