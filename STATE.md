# State: cloud

Overwritten to stay current (loopers and agents). Last updated: 2026-11-03 by the looper (#4).

- **Version / line:** unreleased (main); no tacplus floor (OpenTofu and shell, no tacplus build). CI image
  `ghcr.io/tacplus-dev/tacplus/build:2.5` by digest; OpenTofu 1.13.2, providers `google` 8.9.0 and `gitlab` 19.5.0 (lock
  files), tflint 0.65.0 (google ruleset 0.41.0), shellcheck 0.11.0, all pinned by checksum (`ci/tools.sh`). The `gitlab`
  provider is our own reproducible build of its v19.5.0 tag with go1.26.10 and x/net v0.62.0 (`ci/gitlab-provider.sh`,
  #3), installed only from `bin/providers` (`ci/tofurc.sh`) and locked by its own hashes.
- **Works (#1):** `bootstrap/bootstrap.sh` (the domain's TXT record and the organization, the folder and project
  `bootstrap`, the state bucket, `cloud-admin-pipeline` with its rights and its WIF from `tacplus-dev/cloud`'s protected
  main, the empty secrets; idempotent, refuses what differs, `--dry-run`); the stacks `org` (org policies, folders `ci`
  and `dev`, readers), `ci` (runner manager VM, five arm64 pools as MIGs at size 0 with no-role or no accounts, runner
  token secrets, build bucket, import-only KMS key for the reader app), `dev` (GKE Axion cluster, `dev.tacplus.dev` zone,
  `cluster-admin-pipeline` for tacplus-dev/cluster) and `gitlab` (this project's protected main, environments and
  variables from Secret Manager by version; the pools' runners, registered paused); the GitLab pipeline (checks on every
  push, plan per stack saved, apply of exactly that plan automatically on main, nightly drift filing an issue, never
  applying); `ci/policy.sh` (no service-account key, nothing public, nothing a commit does not fix) on the source and on
  every plan. Tests green (`ci/lint.sh all && ci/checks.sh`), here and in the CI image: each stack's plan against mock
  providers, the pipeline's rules, the plan/apply script, the policy, and the bootstrap against a stub gcloud.
- **Runner image and readiness (#4):** the pools boot Container-Optimized OS for arm64, pinned by image name in
  `modules/settings` (`cos_arm64_image`, never a family: the module and `ci/policy.sh` refuse one), vanilla
  (`decisions/builds-in-containers-2026-11-03.md`): no startup-script, nothing installed at boot, OS updates off, the
  OS's own Docker. Every pool waits, bounded to ten minutes, until `docker info` answers the connecting user
  (`instance_ready_command`), one job per VM. No baked image and no bake identity (superseded). Tested against mock
  providers only.
- **Known vulnerabilities (#3):** `govulncheck -mode=binary` of the gitlab provider build: none. OpenTofu, the google
  provider, tflint and its ruleset, GitLab Runner and the fleeting plugin carry x/net, x/crypto/openpgp, x/mod and grpc
  findings with no fixed upstream release: accepted in `security-exceptions.yaml` until **2026-12-03**; bump each pin
  when its fix ships (PROPOSALS.md). No job here runs the scan yet (PROPOSALS.md).
- **Released / deployed:** nothing applied. No pipeline has run.
- **Known gaps:** never run against real GCP or GitLab: the plans are tested against mock providers only, so an API's
  refusal (a role missing, a name taken) shows only in the first pipeline. The GitLab project `tacplus-dev/cloud`, its
  runner (tag `cloud`), `GCP_WIF_PROVIDER`, the reader app's install and KMS grant, and the schedule are the hub's
  (README, Before the first pipeline); the dev zone's delegation is a record in jody1-328023 (README). The runners are
  registered paused and the cluster is empty until the later move off jody1-328023. Follow-ups in PROPOSALS.md.
- **Blocked on:** Jody's bootstrap run (README, What Jody runs, in order), then the hub's steps (no issue). #4's
  acceptance (`runner-image measure 20`, no first-job image-pull failure) waits for the runners' move off jody1-328023.
