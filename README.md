# cloud

The pipeline that owns tacplus-dev's cloud accounts. Every change to GCP and GitLab configuration is a commit here, applied
by a pipeline. People, the hub included, have read-only access.

Design: tacplus-dev/roadmap#2 and `tacplus-dev/roadmap:decisions/cloud-pipeline-2026-11-02.md` (approved by Jody, 2026-11-02).
The list of what must be done before production is `tacplus-dev/roadmap:PRODUCTION.md`.

Work arrives as issues; see github.com/tacplus-dev/looper.

## What it manages
- **A GCP organization** on tacplus.dev (Cloud Identity Free, admins' Google accounts only; we are not an IdP), with its org
  policies.
- **Folders and projects:**
  - `bootstrap`: this pipeline's state and identity;
  - `ci`: runners and builds;
  - `dev`: the dev cluster and its services.
  - `prod` is designed but **not built**: see PRODUCTION.md.
- **GitLab settings:** projects, protected branches and environments, protected project variables (values from Secret
  Manager, never in this repository), runner registrations.

## How it runs
OpenTofu with the `google` and `gitlab` providers; state in a GCS bucket in `bootstrap`. CI runs in the GitLab project of
the same path:
- `plan` on every change;
- `apply` per environment is a protected manual job that only Jody plays;
- a nightly drift `plan` opens an issue and never applies.

The pipeline signs in as `cloud-admin-pipeline` through Workload Identity Federation from this project's protected `main`.
There are no keys anywhere.

## Bootstrap
One reviewed script that Jody runs once with his own account: verify the domain and create the organization, create
`bootstrap` with its state bucket, and create `cloud-admin-pipeline` with its WIF binding. Everything after that goes
through the pipeline.
