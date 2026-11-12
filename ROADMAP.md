# Roadmap: cloud

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
Nothing built yet. The design is approved (tacplus-dev/roadmap#2, 2026-11-02).

## Next
- The cloud pipeline, first cut: the bootstrap script, the organization and org policies, the folders and the `bootstrap`, `ci` and `dev` projects, GitLab settings, `plan` on every change, Jody's protected `apply` per environment, nightly drift (#1). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/cloud-pipeline-2026-11-02.md`).
- Runner pools in `ci` boot a baked image and wait for readiness (looper#43), one VM per job (#4). Agent, hub's call under Jody's deterministic-deployments rule, 2026-11-03.
- ci: the shared build cache, pools whose job containers share VMs, one always-on VM (#5). Agent, at Jody's request, 2026-11-03 (`tacplus-dev/roadmap:decisions/looper-job-per-issue-2026-11-03.md`).
- Certificate secrets per deployment and a delegated _acme-challenge zone, written only by the deployment pipeline (#6). Agent, at Jody's request, 2026-11-03 (`tacplus-dev/roadmap:decisions/certificates-by-pipeline-2026-11-03.md`).
- Run in a folder that a host organization hands to it (today seabeam.net's `tacplus-dev`), with no organization of its own: the bootstrap and the stacks take a parent folder (#8). Agent, at Jody's request, 2026-11-03 (`tacplus-dev/roadmap:decisions/cloud-org-seabeam-2026-11-03.md`).
- Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, an enforced security-exceptions.yaml (#10). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-the-deterministic-security-checks-in-the-pipelines-that-apply-infrastructure.md`).
- No VMs outside GKE: the runner manager, runner pools, templates, MIGs and SSH rules removed from the stacks; a plan check refuses any (#11). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- The 2026-11-03 network and node-pool rules in the stacks, with plan checks that refuse violations: no external IPs (org policy), no 0.0.0.0/0 ingress, no SSH, private COS nodes, a normal pool of 3 x c4a-standard-2 and a spot build pool of c4a-standard-4 from 0 to 3, a nightly live audit (#7). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/network-exposure-2026-11-03.md`, `cluster-node-pools-2026-11-03.md`).
- gitlab stack: a read-only project token on tacplus-dev/build for the nightly recap, rotated, in Secret Manager (#12). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-let-the-recap-see-the-build-pipeline.md`).
- dev: a reserved global static IP for the gateway's load balancer, the tacplus.dev zone written only by the pipeline in seabeam.net, and a TTL-first cutover with Jody's registrar name-server change (#13). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- dev: the in-cluster runners' token secrets (accessor for the cluster pipeline, version adder for Jody) and the cluster pipeline's cluster-admin binding on dev, made by this pipeline (#18). Agent, at Jody's request, 2026-11-05 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- ci: the looper Apps' import-only signing keys, their one-time import, and the looper project's federation and per-environment signer bindings, in seabeam.net (#19; tacplus-dev/looper#83). Agent, at Jody's request, 2026-11-05.
- dev: global TCP proxy LB on the gateway address, TLS passed through to the tacplus gateway's NEGs, nodes open only to Google's proxy ranges (#21). Agent, at Jody's request, 2026-11-05 (`tacplus-dev/roadmap:decisions/network-exposure-2026-11-03.md`, addendum: we terminate TLS).
- tacplus-dev/build's BUILD_TRIGGER_TOKEN and one nightly build schedule per pinned repository, from the gitlab stack (#26). Agent, at Jody's request, 2026-11-06 (`tacplus-dev/roadmap:suggestions/2026-11-06-pin-every-repository-so-the-build-pipeline-and-its-security-checks-run-anywhere.md`).
- dev: seatrials' deploy registry, Cloud Build (until looper#84 moves builds to the cluster's build pool) and build bucket, get-credentials on dev, and the test IdP's deploy account (#20). Agent, at Jody's request, 2026-11-06 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- gitlab stack: fleet-seatrials' CA and crypto file in Secret Manager, written by its init-secrets job through WIF, no GitLab token (#28; Jody, 2026-11-08, option D). Agent, at Jody's request, 2026-11-07 (`tacplus-dev/roadmap:decisions/secrets-by-pipeline-2026-11-05.md`).
- ci: the tacplus-reader App's key and fleet-seatrials-reader move to tacplus-ci, import-only like #19 (#30). Agent, at Jody's request, 2026-11-08 (off thescottsweb.com).
- dev: the test IdP's certificate and seed secrets, its challenge zone, its listener ready (#32). Agent, at Jody's request, 2026-11-09 (fleet-seatrials#27).
- Anthropic workload identity for llmproxy (issuer, rule, service account) owned by the pipeline; the hand-made seatrials entries adopted, design first (#34). Agent, at Jody's request, 2026-11-09.

## Later
- `prod`: its project, the `cloud-prod-pipeline` identity and the `apply-prod` gate, when Jody says production is next (`tacplus-dev/roadmap:PRODUCTION.md`).
- Moving dev off jody1-328023: runners, the cluster, DNS, KMS and buckets; then jody1-328023 is drained (Jody deletes it).
- A spot overflow pool for looper reports (Jody, 2026-11-04): its own pool, separate from the build pool and tainted differently, on the cheapest Arm spot machine that fits the report pods (chosen with prices when it is built). Reports prefer the normal pool and land here only when it is full (the autoscaler adds a node for pending reports); the kicker and the managers never run here. Its maximum starts at 0 and is raised on Jody's word from the recap's wait numbers. Agent, at Jody's request.
- dev: the secret google-signin-seatrials (no version; seatrials-deploy its only reader) for fleet-seatrials#46 (#37). Agent, at Jody's request, 2026-11-10.
- ci: GitLab Runner and its fleeting plugin built here with go1.27.4, pinned by SHA-256, served to the manager from a private bucket; nothing the VMs run comes from upstream at boot (#40). Agent, at Jody's request, 2026-11-11 (cloud#39, option A).
- dev: the test-idp listener ready once the NEG seatrials-test-idp exists (#42, split from #32). Agent, at Jody's request, 2026-11-11 (fleet-seatrials#27).
- ci: cloud#40's GitLab Runner build and helper pin move to v19.5.3, in step with tacplus-dev/cluster (#44). Agent, at Jody's request, 2026-11-12 (cluster#21, hub under Jody's security delegation).
- dev: a private Artifact Registry repository ci-images for cluster's own GitLab Runner images, cluster-admin-pipeline its only writer (#45). Agent, at Jody's request, 2026-11-12 (cluster#21).

## Not doing
- Importing jody1-328023: the new projects are built fresh.
- Standing write access for people or the hub.
- Fleet workloads and anything inside a cluster: tacplus-dev/cluster and the fleets own those.
