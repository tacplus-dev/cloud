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
- **Readers' accounts** (looper, #1). What: tacplus.dev accounts for Jody's daily use, the hub and the loopers, and
  their `readers` entries. Why: domain-restricted sharing admits only the organization's directory, so the gmail
  accounts and jody1-328023's service accounts used today cannot be readers; until then nobody but the pipeline and
  break-glass sees the organization.
- **Remove the organization's default grants** (looper, #1). What: Google gives the whole domain `projectCreator` and
  `billingAccountCreator` on a new organization; remove them, so only the pipeline creates projects. Why: standing
  write access for people is what the design forbids. A removal is a deletion of access: Jody's decision.
- **The in-cluster grant of cluster-admin-pipeline in dev** (looper, #1). What: its ClusterRoleBinding of
  `cluster-admin` on the dev cluster, made by a pipeline (a kubernetes-provider stack here, or tacplus-dev/cluster's
  bootstrap) rather than by the hub by hand. Why: today GCP grants it only `container.clusterViewer`; the binding is the
  hand step tacplus-dev/cluster's README lists, which the move of the cluster to dev would repeat.
- **Secret values out of plans and state** (looper, #1). What: the gitlab stack's variables and the runner tokens
  through write-only attributes or ephemeral resources, once both providers offer them for these resources. Why: today
  the values are in the saved plan (an artifact, members only) and the state (the bootstrap bucket).
- **Data Access audit logs on the organization** (looper, #1). What: an org-level audit config for IAM and Secret
  Manager reads. Why: break-glass and the pipeline's secret reads are then traced beyond Admin Activity.
- **Deterministic security checks in this pipeline** (nightly scan, 2026-11-03). What: a `security` job, run on every
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
  fleeting-plugin-googlecloud past v1.3.1 (x/net >= v0.60.0); `ci/tools.sh` shas, `ci/lock.sh`, `stacks/ci/main.tf`.
  Why: the exceptions expire on 2026-12-03 (Jody's decision on #3: 30 days); after that each needs a bump, a build
  from source like the gitlab provider's, or a new decision.
- **Drop the gitlab provider's build from source** (looper, #3). What: when gitlabhq/terraform-provider-gitlab
  releases a version built with go >= 1.26.10 and x/net >= v0.62.0, pin it from the registry again: remove
  `ci/gitlab-provider.sh` and `ci/tofurc.sh`, their calls (`ci/tools.sh`, `ci/lock.sh`, the scripts sourcing tofurc) and
  `tests/providers_test.sh`'s provider checks, and run `ci/lock.sh`. Why: the build costs every `tools` job a Go build
  and a fetch from gitlab.com, and it is ours to keep current; upstream's signed release is the normal path. Upstream
  has not been asked yet: its issues are on gitlab.com (gitlab-org/terraform-provider-gitlab; the GitHub mirror takes
  none), and this run had no gitlab.com account; the request is drafted on #3 for the hub to file.
- **Enforce the exceptions' expiry** (looper, #3). What: the security job of the deterministic checks above fails on
  an expired `security-exceptions.yaml` entry, as looper-scan does; today `tests/providers_test.sh` checks only its
  form. Why: an expiry nothing enforces is a note, and a date check in `ci/checks.sh` would make the same commit pass
  one day and fail the next, which the plan and apply gates should not.
- **The bake opens its bump** (looper, #4, 2026-11-03). What: tacplus-dev/looper's `runner-image` job, after it
  publishes, opens an issue here (or a merge request running `ci/runner-image.sh <name> <its commit>`) naming the
  image and the looper commit it baked from. Why: the hub's decision on #4 has each bake's job ask for its bump;
  tacplus-dev/looper#67 asks only that it print the name, so today the bump waits for someone to read the job's log.
  It is looper's code: a feature for its roadmap there.
- **Never delete the pinned image** (looper, #4). What: `runner-image build` keeps the newest `RUNNER_IMAGE_KEEP` (3)
  of the family and deletes older ones, whether or not a template still boots one; the bake should keep the images
  labelled as pinned (a label this repository's apply sets, or a list it reads), or the ci stack should protect the
  pinned one (an image's `deprecated` state, or a check in `plan:ci` that it exists). Why: after four bakes with no bump,
  the pools' template names a deleted image and no VM can be created; a revert is then no rollback.
