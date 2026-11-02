# Roadmap: cloud

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
Nothing built yet. The design is approved (tacplus-dev/roadmap#2, 2026-11-02).

## Next
- The cloud pipeline, first cut: the bootstrap script, the organization and org policies, the folders and the `bootstrap`, `ci` and `dev` projects, GitLab settings, `plan` on every change, Jody's protected `apply` per environment, nightly drift (#1). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/cloud-pipeline-2026-11-02.md`).

## Later
- `prod`: its project, the `cloud-prod-pipeline` identity and the `apply-prod` gate, when Jody says production is next (`tacplus-dev/roadmap:PRODUCTION.md`).
- Moving dev off jody1-328023: runners, the cluster, DNS, KMS and buckets; then jody1-328023 is drained (Jody deletes it).

## Not doing
- Importing jody1-328023: the new projects are built fresh.
- Standing write access for people or the hub.
- Fleet workloads and anything inside a cluster: tacplus-dev/cluster and the fleets own those.
