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
