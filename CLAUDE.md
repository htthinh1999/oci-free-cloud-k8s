# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal infrastructure-as-code for a Kubernetes cluster (OKE) running on Oracle Cloud's
Always Free tier (2 oCPU / 12GB, ARM `VM.Standard.A1.Flex` nodes — **arm64 only, no x86**).
There is no application source code here — this is Terraform + FluxCD GitOps config.
It's a personal/playground setup, loosely documented and opinionated; changes should fit the
existing patterns rather than introduce new tooling or abstractions.

## Repository layout

* `terraform/infra/` — provisions everything up to a working k8s API endpoint (VCN, subnets,
  security lists, the OKE cluster and node pool). Must be applied first.
* `terraform/config/` — k8s-level config that depends on a live API server (via `modules/`:
  `external-secrets`, `fluxcd`, `grafana`, `ingress`). Applied after `infra`.
* `gitops/core/` — one directory per component, reconciled by FluxCD (not `terraform apply`).
  Editing files under `gitops/` changes cluster state only after Flux reconciles from git —
  there's no local "build" step to run.

These two Terraform roots and the gitops tree are intentionally decoupled (separate state files,
separate providers) to keep runs fast and avoid provider coupling. Never merge them.

## GitOps component structure (`gitops/core/<name>/`)

Every component follows the same file convention — when adding a new one, copy this shape:

* `namespace.yaml` — namespace definition
* `flux.yaml` — the `HelmRepository`/`GitRepository` + `HelmRelease`, OR (at the `gitops/core/`
  level) the `Kustomization` that points Flux at this component's path
* `helm.yaml` — `HelmRepository` + `HelmRelease` (chart, version, values)
* `secret.yaml` — `ExternalSecret` pulling from the OCI Vault via the `oracle-vault`
  `ClusterSecretStore` (see `gitops/core/external-secrets/`)
* `httproute.yaml` — Gateway API `HTTPRoute` (envoy-gateway), when the component is exposed
* `securitypolicy.yaml` — OIDC/auth protection on the `HTTPRoute` via envoy-gateway
  `SecurityPolicy`, when applicable
* `kustomization.yaml` — lists the above as `resources`; the top-level
  `gitops/core/kustomization.yaml` lists every component's `flux.yaml`

New components must be registered in `gitops/core/kustomization.yaml` and typically declare
`dependsOn: [external-secrets]` in their `Kustomization` (in `flux.yaml`) since most components
pull secrets from the vault.

Ingress uses **Gateway API** (envoy-gateway), not `nginx-ingress` — use `HTTPRoute`, not
`Ingress` resources, for anything new.

## Commands

```bash
# format all yaml (gitops manifests) - excludes flux-system and grafana dashboards, see .yamlfmt
yamlfmt

# run all pre-commit hooks (yamlfmt, case/merge-conflict checks, private-key detection, etc.)
pre-commit run --all-files

# terraform — run from terraform/infra/ or terraform/config/ (never the repo root)
terraform init
terraform plan
terraform apply
```

There are no application tests. Linting is `pre-commit` for repo conventions, plus a SonarQube scan (`.github/workflows/sonarqube.yml`) of the infra code itself — the generic scanner is the right choice here (unlike in `wattvn`) since this repo has no C#/compiled code, just Terraform and YAML.

### Terraform specifics

* State is stored remotely using Terraform's native `oci` backend (requires Terraform **>= 1.12**);
  see `_terraform.tf` in each of `infra/` and `config/` for the bucket/namespace/key.
* `terraform/config` needs a private (untracked) `*.tfvars` with secrets like `compartment_id`,
  a GitHub fine-grained PAT, etc. Some variables are only available from `terraform/infra` output
  or the OCI web console.
* First-time `terraform apply` in `config/` is expected to fail creating the `ClusterSecretStore`
  (it depends on `external-secrets` being deployed by Flux first) — just re-apply afterward.
* Kubernetes cluster access after `infra` apply comes from the generated `.kube.config` file in
  `terraform/infra/`; see the Teleport section of `README.md` for the regulated-access path.

## Conventions

* YAML formatting is enforced by `yamlfmt` (150 char max line length, line breaks retained) — run
  it (or `pre-commit run --all-files`) before committing gitops changes.
* Renovate manages dependency updates for `terraform` and Flux `HelmRelease`/`HelmRepository`
  files matching `helm.yaml`; grouped into a single weekly PR (Monday before 3am, Europe/Berlin).
  Docker image updates are disabled.
* Secrets are never committed in plaintext — they're pulled from the OCI Vault via
  `ExternalSecret`/`ClusterSecretStore` (`secret.yaml` in each component), or passed through
  Terraform variables backed by untracked `*.tfvars` files.

## Before pushing / finishing a session

Check SonarQube before considering a push or a session done:

1. **Before pushing**, run the `sonarqube` MCP tool `analyze_file_list` (SonarQube for IDE's
  local engine — no push/CI round-trip needed) on every file you changed. Fix anything real
  it flags, same as step 4 below. It won't know about hotspots already triaged on the server
  (they'll still show up locally — expected, not a regression).
2. Push, then wait for the `SonarQube Scan` GitHub Actions run on that commit to finish.
3. Query the `sonarqube` MCP tools for project key
  `htthinh1999_oci-free-cloud-k8s_450a287e-11d2-40b7-8ebb-126f1cbf6fd8`:
  `get_project_quality_gate_status`, `search_sonar_issues_in_projects`
  (`issueStatuses: [OPEN, CONFIRMED]`), `search_security_hotspots`.
4. Fix every OPEN issue with a real change, then re-validate as appropriate
  (`kubectl kustomize <dir>`, `terraform validate`, `yamlfmt`) before treating it as fixed.
5. Triage every security hotspot explicitly via `change_security_hotspot_status`
  (`FIXED` / `SAFE` / `ACKNOWLEDGED`, with a comment explaining the reasoning) — never leave
  one at `TO_REVIEW`.
6. Push any fixes and repeat from step 2 until the quality gate is `OK`, zero open issues,
  and no un-triaged hotspots remain.
