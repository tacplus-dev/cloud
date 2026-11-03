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
