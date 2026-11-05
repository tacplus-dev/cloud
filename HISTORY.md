# History: cloud

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-11-03 looper issue Build the cloud pipeline: bootstrap script, org policies, bootstrap/ci/dev projects, GitLab settings; plan on change, Jody applies the saved plan (#1, ee7f468)
- 2026-11-03 looper issue Runner default image is alpine:3.22; the latest line is 3.24 (#2, 095d6de)
- 2026-11-03 looper issue Pinned tools, providers and runner carry known Go vulnerabilities (gitlab provider built on go1.26.5); no patched upstream release yet (#3, a15e1e9)
- 2026-11-03 looper issue ci stack: runner pools boot a baked image and wait for readiness (looper#43), one VM per job (#4, 6ded61d)
- 2026-11-03 looper issue ci: shared build cache (bucket and registry, build jobs write); pools share VMs between job containers; one always-on VM (#5, f1ee103)
- 2026-11-03 looper issue Certificate secrets per deployment and a delegated _acme-challenge zone; only the deployment pipeline writes them (#6, da9e0e6)
- 2026-11-03 looper issue Run in a folder handed to it, not an organization of its own: bootstrap and stacks take a parent folder (#8, 814594b)
- 2026-11-04 looper issue Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, with an enforced security-exceptions.yaml (#10, 1cf15ed)
- 2026-11-04 looper issue bootstrap.sh: gcloud lists the folder by bare ID, so the bootstrap cannot see the folder it created and refuses on re-run (Jody's bootstrap stopped) (#14, 5acf3f7)
- 2026-11-04 looper issue Encode the 2026-11-03 rules: only LBs public, no internet ingress, no SSH, private COS nodes, normal plus spot pools; plan tests that refuse violations (#7, f47a4ea)
- 2026-11-04 looper issue dev: a reserved global static IP for the gateway's LB, the tacplus.dev zone under the pipeline in seabeam.net, and a TTL-first cutover with Jody's registrar NS change (#13, 44dc21e)
- 2026-11-04 looper issue gitlab stack: a read-only (Reporter, read_api) project token on tacplus-dev/build for the looper's nightly recap, rotated, in Secret Manager (#12, c4b0c4a)
- 2026-11-05 looper issue First apply stopped: KMS counted against tacplus-bootstrap (API not enabled), and a new project's IAM not yet propagated when its WIF pool is created (#16, f80b41a)
- 2026-11-05 looper issue gitlab stack: branch protection uses push_access_level/merge_access_level, which the provider refuses on gitlab.com Free; plan:gitlab fails (#17, 39dd4cb)
- 2026-11-05 looper issue dev: the runners' token secrets (accessor for the cluster pipeline, version adder for Jody) and the cluster pipeline's cluster-admin binding on dev, made by this pipeline (#18, af9577d)
