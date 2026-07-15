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

There are no application tests, linters beyond `pre-commit`, or CI workflows in this repo.

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
