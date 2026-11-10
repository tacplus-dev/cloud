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
  GO-2025-3922, accepted until 2026-12-04, #10), and OpenTofu, Trivy past 0.76.2 and GitLab Runner to a release with
  klauspost/compress >= v1.20.2 (GO-2026-6865, accepted until 2026-12-06, #24), and the CI image to a build:2.6 digest
  whose `gh` has x/net >= v0.62.0 (CVE-2026-78661, accepted until 2026-12-06, #27; tacplus-dev/tacplus#350):
  `default.image` and `build.lock`; `ci/tools.sh` shas and sums, `ci/lock.sh`, `stacks/ci/main.tf`.
  Why: the exceptions expire on 2026-12-03 (Jody's decision on #3: 30 days); after that each needs a bump, a build
  from source like the gitlab provider's, or a new decision.
- **gitleaks and OSV-Scanner on their releases' dependencies again** (looper, #24, 2026-11-07). What: drop the
  `klauspost_compress` and `brotli` requirements of their `gobuild` in `ci/tools.sh` when a gitleaks release past
  v8.30.1 requires klauspost/compress >= v1.20.2 and brotli >= v1.2.7, and an OSV-Scanner release past v2.7.0
  klauspost/compress >= v1.20.2. Meanwhile the same requirement could take gitleaks' xz to v0.5.15 and so drop
  GO-2025-3922's exception (#10) before it expires on 2026-12-04. Why: a build with other dependencies than the
  release's is ours to keep current.
- **Drop the gitlab provider's build from source** (looper, #3). What: when gitlabhq/terraform-provider-gitlab
  releases a version built with go >= 1.26.10 and x/net >= v0.62.0, pin it from the registry again: remove
  `ci/gitlab-provider.sh` and `ci/tofurc.sh`, their calls (`ci/tools.sh`, `ci/lock.sh`, the scripts sourcing tofurc) and
  `tests/providers_test.sh`'s provider checks, and run `ci/lock.sh`. Why: the build costs every `tools` job a Go build
  and a fetch from gitlab.com, and it is ours to keep current; upstream's signed release is the normal path. Upstream
  has not been asked yet: its issues are on gitlab.com (gitlab-org/terraform-provider-gitlab; the GitHub mirror takes
  none), and this run had no gitlab.com account; the request is drafted on #3 for the hub to file.
- **Drop the kubernetes provider's build from source** (looper, #18, 2026-11-05; #23, 2026-11-07). What: when
  hashicorp/terraform-provider-kubernetes releases a version that compiles against github.com/getkin/kin-openapi
  >= v0.149.0, move `ci/kubernetes-provider.sh` to it and drop its kin-openapi override and `ci/kubernetes-provider.patch`
  (Jody's decision on #23); when it is also built with a fixed Go (>= go1.27.3, x/net >= v0.62.0), pin it from the
  registry again: remove `ci/kubernetes-provider.sh`, its patch, its calls (`ci/tools.sh`, `ci/lock.sh`), its entries in
  `ci/tofurc.sh` and `tests/providers_test.sh`, and run `ci/lock.sh`. Why: v3.4.0's kin-openapi v0.111.0 has nine
  advisories (#18, #23) and the fixed releases change its API, so we carry a port of its `manifest/openapi`
  (hashicorp/terraform-provider-kubernetes#2949 and #2741 are open upstream bumps, to v0.144.0 and v0.132.0, both short
  of v0.149.0); the build and the patch are ours to keep current.
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
- **The challenge zone's delegation in a stack** (looper, #6): done by #13 (tacplus.dev's zone in the dev stack
  delegates both; until the registrar names it, the old zone's copies are the hub's: README, The tacplus.dev cutover). What: the NS records of `_acme-challenge.<domain>.` (and
  `dev.tacplus.dev.`'s) made by the pipeline, once tacplus.dev's zone is under the parent folder. Why: today they are hand
  steps in jody1-328023, which the nightly drift does not see.
- **DS records for the delegated zones** (looper, #6). What: the challenge zone's (and the dev zone's) DS record in its
  parent, from the zone's DNSSEC keys. Why: both zones sign, but with NS records only the delegation is insecure, so
  resolvers do not validate their answers. Since #13 the parent is in the same stack, so the DS records can be
  `google_dns_record_set`s from each zone's keys (`google_dns_keys`); they matter once tacplus.dev itself is signed at
  the registry (below, Sign tacplus.dev).
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
  Links: #7 (design and Jody's seven questions on the issue). **Promoted** (ROADMAP, 2026-11-04) and done by #7: the
  runner pools stay on demand and the internal SSH rule stays, admitted by name, until #11 removes the runner VMs.
- **Folder firewall policies on `ci` and `dev`** (looper, #7, 2026-11-04; Jody's Q7 (a), "later"). What: a hierarchical
  firewall policy on each folder denying tcp:22 from anywhere and ingress from outside the networks' private ranges and
  Google's LB and health-check ranges (`130.211.0.0/22`, `35.191.0.0/16`), in the folder stack. Why: the plan checks
  stop only the pipeline and the live audit only reports; a folder policy would enforce the rules against a rule made by
  hand. Its first apply must check that `roles/owner` on the parent folder may set one, and that GKE's own rules still
  work under it.
- **No regional external address in the stacks** (looper, #7, 2026-11-04): done by #13 (with any external address but
  `gateway`, and any external forwarding rule, in a plan and in the live audit). What: `ci/policy.sh plan` refuses a
  `google_compute_address` whose `address_type` is `EXTERNAL` (the default): a proxy-based load balancer takes a global
  address (#13), and Cloud NAT allocates its own (`AUTO_ONLY`). Why: a regional external address is for a VM or a
  passthrough load balancer, both of which the rules exclude; today only `compute.vmExternalIpAccess` and the access-config
  check stand in the way, and they do not see a passthrough LB's forwarding rule.
- **Drop the runners' SSH exception with the runner VMs** (looper, #7, 2026-11-04). What: when #11 removes the runner
  VMs, remove `runner_ssh` from `ci/policy.sh` and its fixture case, and the README's exception. Why: it is admitted by
  name only while those VMs exist.
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
- **A Trivy timeout to fit the CI image** (looper, #22). What: `ci/security.sh` runs `trivy image` with Trivy's default
  `--timeout` of 5m; give it one sized for the image (`--timeout 15m`, say), and `tests/security_test.sh`'s stub the flag.
  Why: the build image is large (Swift's embedded libraries among its layers): a scan of build:2.6.1 took 235 s in a
  4 GiB container, and on 2026-11-06 two of four runs (build:2.5 and 2.6.1) stopped at the deadline ("semaphore acquire:
  context deadline exceeded"), which the job counts as a tool that cannot run, so it fails.
- **One security job for the three apply pipelines** (looper, #10). What: cloud, cluster and fleet-seatrials each run the
  same floor (tacplus-dev/cluster#5, tacplus-dev/fleet-seatrials#36); one shared job file (a GitLab `include` of a
  pinned commit) or looper-scan itself pinned into each `ci/tools.sh`, instead of three copies of the policy. Why: the
  suggestion (`suggestions/2026-11-04-...`) asked for one shared job; `ci/security.sh` copies looper-scan's policy and
  exceptions reader, which can drift from it.
- **A better scan of the tree's dependencies** (looper, #10). What: OSV-Scanner reads no file of this tree (OpenTofu's
  lock files are not a format it knows): the providers are covered by govulncheck on their binaries instead. If a
  manifest it reads is ever added (a go.mod, a Dockerfile), it is scanned with no change. Why: so that nobody reads
  "OSV-Scanner: no finding" as "the providers are clean".
- **Sign tacplus.dev** (looper, #13, 2026-11-04). What: once the cutover is over (README, The tacplus.dev cutover), the
  new zone's DS record (`gcloud dns dns-keys list --zone=tacplus-dev --project=tacplus-dev`, the key-signing key's
  `ds_record`), given by the dev stack as an output, at the registrar: Jody's step, like the name servers. Why: the zone
  signs (DNSSEC on), but the registry has no DS for tacplus.dev (the old zone had none), so resolvers do not validate
  it; adding one during the cutover would break resolution through the old, unsigned zone.
- **IPv6 on the address** (looper, #13, 2026-11-04; revised by #21, 2026-11-06). What: a second global address
  `gateway-v6` (`ip_version = "IPV6"`, `prevent_destroy`), admitted by `ci/policy.sh` beside `gateway`, a forwarding rule
  per listener on it to the same TCP proxies (a global external proxy Network Load Balancer takes an IPv6 address), and
  the hostnames' AAAA records to it. Why: clients on IPv6 only reach tacplus.dev today through NAT64 or not at all. It is
  a second public IP, so it is Jody's call (the decision names one per load balancer).
- **The test IdP on its own port** (looper, #13, 2026-11-04; replaced by #21, 2026-11-06). What: tacplus-dev/fleet-seatrials'
  test IdP (its `test-idp/`, today a GKE Ingress with a load balancer of its own on the global address `test-idp`, whose
  A record its pipeline writes into the zone `tacplus-dev`) served by Keycloak's own TLS on 8443, its Service a
  `ClusterIP` with the NEG `seatrials-test-idp` (README, The public entry), its issuers
  `https://idp.test.tacplus.dev:8443/realms/<realm>`; `test-idp-deploy` loses its write on the zone; then `ready = true`
  for `test-idp` here. Why: the TCP proxy does not route by SNI, so the IdP cannot share 443 with the gateway; a second
  address is a second public IP, SNI routing would be the gateway's, and no L7 path is allowed (#21). A
  fleet-seatrials change, with its retarget to the new cluster.
- **`ready` when the NEGs exist** (looper, #21, 2026-11-06). What: a commit setting `ready = true` for `gateway` once
  tacplus-dev/operator#22 renders seatrials' gateway Service in the dev cluster and GKE has made `seatrials-gateway`, and
  for `test-idp` once fleet-seatrials does. Why: the API refuses a backend naming a missing NEG, so the backends wait for
  the Services; until then the address answers nothing on those ports.
- **The client's address through the TCP proxy** (looper, #21, 2026-11-06). What: `proxy_header = "PROXY_V1"` on the
  gateway's target TCP proxy once the tacplus gateway reads the PROXY protocol (a tacplus-dev/gateway change first: with
  the header on and the gateway not reading it, every TLS handshake fails). Why: the gateway sees Google's proxies'
  addresses, not the client's, so per-client limits and logs see one of a few Google addresses.
- **A regional cluster's NEGs** (looper, #21, 2026-11-06). What: one backend per zone of the cluster, each the NEG of the
  same name in that zone, if the dev cluster becomes regional. Why: today it is zonal (`us-central1-a`), and the backend
  is that zone's NEG only.
- **The live audit of the load balancers** (looper, #21, 2026-11-06). What: `ci/audit.sh` also lists the projects'
  forwarding rules (global and regional), target proxies, URL maps, SSL policies and certificates (Compute's and
  Certificate Manager's) and runs the plan checks on them. Why: the plan checks refuse an L7 load balancer, a certificate
  or a forwarding rule off the address `gateway` from the pipeline, but one made by hand is in no state, and the audit
  lists only firewall rules, instances, templates, addresses and clusters today.
- **The DNS check against both zones during the cutover** (looper, #13, 2026-11-04). What: `ci/dns.sh` also lists the
  zone in jody1-328023, while it exists, and reports a record the two zones do not share. Why: until the registrar's
  change has propagated, resolvers may ask either zone; today the hub keeps them alike by hand, and a difference shows
  only once a resolver answers from the old one. The drift job's identity has no read on jody1-328023, so this needs
  that grant, or the check run by the hub.
- **The caller-counted APIs without a bootstrap run** (looper, #16, 2026-11-05). What: let the folder stack enable, in
  `tacplus-bootstrap`, the APIs `tests/apis_test.sh` classes as the caller's (`google_project_service`, which
  `cloud-admin-pipeline`'s owner role on the parent folder allows), or move to per-project quota: the google provider's
  `user_project_override`. Why: today a new caller-counted API needs Jody to run the bootstrap again before the
  pipeline can use it. `user_project_override` was not chosen for #16: with a provider-wide `billing_project` every call
  carries it, the project's own creation included, so a build from nothing would name a quota project that does not
  exist yet; without one, `google_project_service` sends the new project itself, whose Service Usage and IAM may not have
  reached it, before any gate can run. Either way it goes with **The bootstrap's own resources under the pipeline**.
- **Record the gitlab stack's fixture from gitlab.com** (looper, #17, 2026-11-05). What: a read-only script (the
  routes `tests/stubapi` logs, GETs only, with the gitlab stack's token, in a job with it) that rewrites
  `tests/fixtures/gitlab/api.json` from the real answers for tacplus-dev/cloud, its protected main and
  `GCP_WIF_PROVIDER`, keeping the IDs; and the same stub for the drift's plan of the stack's other first-apply
  surprises (a protected environment or a variable the hub made by hand, which a create would collide with). Why: #17's
  fixture is built from the API's documented answers, not recorded (the looper cannot read the project's settings), so
  an attribute the hub set differently (`raw`, `masked`, the description, `unprotect_access_levels`) still shows only
  at the first `plan:gitlab`.
- **tacplus-dev/cluster's README: steps 4 and 7 are the cloud pipeline's** (looper, #18, 2026-11-05). What: a pull
  request there saying that the ClusterRoleBinding of `cluster-admin-pipeline` and the secrets `gitlab-runner-build` and
  `gitlab-runner-control` are made by this pipeline's dev stack (README, The cluster pipeline), and that the hub only
  adds the tokens' versions, as the account of `GCP_RUNNER_TOKEN_ADDERS` (README, hosting note). Why: its README still
  lists both as the hub's, which since 2026-11-04 nobody can do by hand.
- **Refuse every role that can delete the cluster** (looper, #18, 2026-11-05). What: `ci/policy.sh`'s refusal of
  `roles/owner` and `roles/container.admin` to a service account widened to `roles/editor` and
  `roles/container.clusterAdmin`, which hold `container.clusters.delete` too. Why: #18 named the two; the others break
  the same rule, and no service account here holds them today.
- **The runners' token adders' account** (looper, #18, 2026-11-05). What: confirm on the first `apply:dev` that the
  host's `iam.allowedPolicyMemberDomains` admits the account of `GCP_RUNNER_TOKEN_ADDERS` (the dev stack's
  `runner_token_adders`), and that it is the account of **Readers' accounts**, above. Why: a write grant to a person,
  the one exception to only the pipelines changing things: narrow (add only, on two secrets) but unverified until the
  apply.
- **The importer role on each import job itself** (looper, #19, 2026-11-05). What: `roles/cloudkms.importer` bound on
  each import job once the google provider has import job IAM resources, instead of the key ring's binding conditioned
  on the import jobs' names (README, The GitHub Apps' keys). Why: #19 asks for it on each import job; google 8.9.0 has
  no `google_kms_key_ring_import_job_iam_*`, and a condition on `resource.name` grants the same, but only an apply shows
  that KMS evaluates it as expected (Jody's import is the test).
- **The reader's other signers moved** (looper, #19, 2026-11-05; #30, 2026-11-09). What: #30 imports the reader's key
  in tacplus-ci and moves this repository's drift job (its own pool's binding), and admits tacplus-dev/cluster's jobs
  (through the dev project's pool) and fleet-seatrials' (`fleet-seatrials-reader`), whose variables then change;
  tacplus-dev/kernel's prepare, if it still signs in jody1-328023 (its default branch names no reader key), exchanges its
  id_token for the provider `gitlab-com` of `gitlab-loopers` in `tacplus-ci`, or becomes a `projects` entry. tacplus-dev/build holds a key as a file variable, generated on the app: it
  becomes a signer here too, or that key is deleted on the app with the old one. Why: the old key is revoked on the app
  only once nothing signs with it (README, The GitHub Apps' keys), and jody1-328023 is closing.
- **One signing path for fleet-seatrials' reader token** (looper, #30, 2026-11-09). What: once a seatrials job has
  minted a token through `fleet-seatrials-reader@tacplus-ci`, fleet-seatrials drops its `.github-reader`'s first,
  direct, attempt (fleet-seatrials PROPOSALS, One signing path): the new key admits its federated principal only as
  that account, so the direct call is always refused, and logged. Why: one KMS call per job, and no refusal in every log.
- **tacplus-dev/looper's README: its keys and federation are in tacplus-ci** (looper, #19, 2026-11-05). What: a pull
  request there replacing "Only the manager writes main, Setting it up" steps 2 and 3 (the keys, the import jobs, the
  provider and the bindings in jody1-328023) with this repository's README, The GitHub Apps' keys, and the variables
  from the ci stack's `looper_variables` (location `us-central1`, not `us`). Why: jody1-328023 is closing (#15); its
  steps would build them there by hand.
- **A looper job without an environment cannot federate** (looper, #19, 2026-11-05). What: confirm with the probe
  that every looper job that exchanges its id_token has a GitLab environment, or map `attribute.role` with a default
  (`assertion.environment` may be absent). Why: the provider's mapping is the looper README's, and a mapping that
  reads a missing claim fails the exchange; the jobs that sign all name one today, by the README.
- **A cleanup policy for the deploy registry that keeps what is deployed** (looper, #20, 2026-11-07). What: delete the
  `seatrials` registry's versions that no deployed tag (`local`, say, or the `fp-` tags `fleet.lock` names) references,
  once fleet-seatrials says which tags mark what runs. Why: #20 gave it no cleanup policy, so nothing deployed is ever
  deleted (#20: a policy by age alone would delete a running fleet's images); every build's images stay until then.
- **Drop Cloud Build when builds move to the cluster** (looper, #20, 2026-11-07; Jody, 2026-11-06). What: once
  tacplus-dev/looper#84 lands, remove `images`' Cloud Build roles, the builds' account and the bucket (the bucket's
  `force_destroy` set first, or emptied), and the `cloudbuild` API; the registry stays, written by the build pool's
  identity. Why: Cloud Build is for now, by Jody's decision on #20.
- **cluster-admin-pipeline's clusterViewer conditioned on the cluster** (looper, #20, 2026-11-07). What: the same
  condition the deployments' get-credentials has (`resource.name == "projects/tacplus-dev/locations/us-central1-a/clusters/dev"`).
  Why: #20 says "as cluster-admin-pipeline has it", but its grant has no condition; with one cluster in the project it
  changes nothing today, and it would keep a second cluster out of its reach.
- **The test IdP's environment protected, in the federation** (looper, #20, 2026-11-07). What: join
  `assertion.environment_protected` into `attribute.project_environment`, so only a protected `test-idp` admits its jobs.
  Why: fleet-seatrials' docs make `test-idp` protected (deployable by Maintainers), but the federation trusts any job
  of protected main in an environment of that name; protected main already limits who pushes, the environment's
  protection would also limit who runs its manual job.
- **Rotate the build trigger with no commit** (looper, #26, 2026-11-07). What: today `BUILD_TRIGGER_TOKEN` rotates when
  a commit changes its `rotate_by` (the drift's expiry check asks for it 30 days before); a scheduled rotation job
  could make that commit itself (a date 90 days on, landed like any other change), or the stack could key the
  rotation on the plan's date, which would make a plan no longer the commit's alone. Why: the secrets-by-pipeline
  decision wants rotation on a schedule with no person; a renewal commit is still someone's (or a looper's) step.
- **tacplus-dev/looper's README on the build project's setup** (looper, #26, 2026-11-07). What: its Build pipeline and
  Credentials sections say the hub copies `ci/build.gitlab-ci.yml` by hand and that `BUILD_TRIGGER_TOKEN`'s trigger is
  owned by the build project's bot user; since #26 the cloud gitlab stack writes the file (from a pinned looper commit,
  `ci/build-ci.sh update`) and owns the trigger as the user of its `gitlab-token`, and the nightly schedules are its
  `stacks/gitlab/nightly-builds.yaml`. A looper issue to say so, and that a change of `ci/build.gitlab-ci.yml` reaches
  tacplus-dev/build through a bump here. Why: otherwise a hand copy there is reverted by this pipeline's next apply.
- **Protected environments on gitlab.com Free** (looper, #28, 2026-11-09). What: check whether `apply:gitlab` can
  create this project's protected environments (`folder`, `ci`, `dev`, `gitlab`; #17) on tacplus-dev's tier, and if
  not, drop them or make the guard a protected branch alone, saying so in the README; the same for fleet-seatrials'
  `init-secrets` environment. Why: gitlab.com documents protected environments as Premium and Ultimate
  (https://docs.gitlab.com/ci/environments/protected_environments/), and tacplus-dev is on Free (#12, #28). Without them,
  any Maintainer who can run a job on protected `main` in `init-secrets` becomes `seatrials-init-secrets`; the
  environment scopes which jobs, not who runs them. Not checked against gitlab.com: the looper has no GitLab API token.
- **Version hygiene of the fleet secrets** (looper, #28, 2026-11-09). What: once fleet-seatrials#44 has run, decide
  whether `fleet-ca-<deployment>` and `fleet-crypto-<deployment>` get a version-destroy TTL or a rotation, and
  whether the drift job reports a secret with no version or more than one enabled. Why: the CA and crypto file are made
  once and never rotated today; a second version added by mistake would be read as `latest`.
