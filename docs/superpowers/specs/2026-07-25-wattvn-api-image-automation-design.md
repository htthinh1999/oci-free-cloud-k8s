# Flux Image Automation for wattvn-api

## Context

`gitops/core/wattvn-api/helm.yaml` currently has a manually-bumped `values.image.tag`, with an explicit comment noting this is a placeholder: "bumped manually per push - matches the run-number tag from docker-publish.yml. Flux Image Automation is a deliberate later follow-up, not wired in here." This spec is that follow-up.

`docker-publish.yml` (in the `wattvn` repo) tags every push to `main` with both `latest` and `${{ github.run_number }}` (a plain incrementing integer, e.g. `4`).

Flux's `image-automation-controller` and `image-reflector-controller` are **already deployed** — they're part of `instance.components` in `terraform/config/modules/fluxcd/flux.tf`'s `flux-instance` Helm release, alongside dedicated resource-limit patches for both. No Terraform/cluster-bootstrap change is needed; only the CRDs (`ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation`) need to be added to `gitops/core`.

Git write-back uses the same GitHub App credentials already configured for Flux's main sync (`flux-instance-config` secret: `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`), confirmed to already have "Contents: Read and write" permission.

## Decisions

Confirmed with the user before writing this spec:

1. **Direct commit to `main`** — the standard/intended Flux Image Automation behavior. Flux's "Setters" write-back mechanism can only ever rewrite the single scalar value carrying a matching `$imagepolicy` marker comment, nothing else in the repo, which keeps the blast radius of an autonomous, unattended git push acceptably small.
2. **GitHub App write access confirmed already enabled** — no separate credential/App-permission change needed.

## Components

### `ImageRepository` + `ImagePolicy` — `gitops/core/wattvn-api/image-policy.yaml` (new)

Namespace-scoped to `wattvn-api` (via that directory's `kustomization.yaml` top-level `namespace: wattvn-api`), so the `ImageRepository` can reuse the existing `ghcr-pull-secret` `dockerconfigjson` Secret directly — Flux requires `ImageRepository.spec.secretRef` to be same-namespace, and this secret already exists there for the kubelet image pull and the `HelmRepository` chart pull.

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: wattvn-api
  namespace: wattvn-api
spec:
  image: ghcr.io/htthinh1999/wattvn-api
  interval: 5m
  secretRef:
    name: ghcr-pull-secret
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: wattvn-api
  namespace: wattvn-api
spec:
  imageRepositoryRef:
    name: wattvn-api
  policy:
    numerical:
      order: asc
  filterTags:
    pattern: '^[0-9]+$'
```

`filterTags.pattern` restricts candidates to plain-numeric tags only — `latest` (and anything else non-numeric) is never a candidate, so it can never be misread as "the newest version." Field names (`policy.numerical.order`, `filterTags.pattern`, `image.toolkit.fluxcd.io/v1`) were confirmed directly against this cluster's live CRD schema (`kubectl explain imagepolicy.spec --recursive` / `imagerepository.spec` / `imageupdateautomation.spec`), not assumed from memory.

### `ImageUpdateAutomation` — `gitops/core/fluxcd-addons/image-update-automation.yaml` (new)

Placed in `fluxcd-addons` (namespace `flux-system` via that directory's `kustomization.yaml`), which already holds other Flux-level (not app-level) configuration — `Provider`/`Alert`/`Receiver` for notifications. An `ImageUpdateAutomation` is repo-level tooling, not an app resource, so it belongs there rather than in `wattvn-api/`.

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: wattvn-api
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@users.noreply.github.com
      messageTemplate: |
        Automated image update

        {{range .Updated.Images}}{{println .}}{{end}}
  update:
    path: ./gitops/core/wattvn-api
    strategy: Setters
```

`git.push` is deliberately omitted — with no override, Flux pushes back to the same branch it checked out (`main`), which is exactly the confirmed direct-to-main behavior. `update.path` is scoped to `./gitops/core/wattvn-api` only, not the whole repo, so the Setters scan has no reason to ever touch anything outside that directory.

### `helm.yaml` marker comment (modified)

```yaml
  values:
    image:
      # Auto-updated by the wattvn-api ImageUpdateAutomation - do not bump by hand.
      tag: '4' # {"$imagepolicy": "wattvn-api:wattvn-api:tag"}
```

The `:tag` suffix on the marker tells Flux to substitute only this scalar (the tag), not the combined `repo:tag` form — required because `repository` and `tag` are separate Helm values fields here, not a single `image:` string.

### Kustomization registrations (modified)

- `gitops/core/wattvn-api/kustomization.yaml` — add `image-policy.yaml` to `resources`.
- `gitops/core/fluxcd-addons/kustomization.yaml` — add `image-update-automation.yaml` to `resources`.

No changes to either component's `flux.yaml` `Kustomization` (interval/dependsOn/sourceRef) — both files simply become part of what those existing Kustomizations already reconcile.

## Data flow

CI pushes `wattvn-api:<run_number>` to GHCR → `ImageRepository` observes the new tag within 5m → `ImagePolicy` recomputes the highest numeric tag → `ImageUpdateAutomation` (polling every 5m) finds the change, rewrites the marked scalar in `helm.yaml`, commits with the templated message, and pushes to `main` → the existing `wattvn-api` `Kustomization`/`HelmRelease` reconciles that commit exactly like any human-authored one — no changes needed there.

## Error handling / safety

- **Blast radius**: the Setters mechanism can only rewrite the exact scalar carrying the matching marker comment — nothing else in the repository, regardless of what the `ImagePolicy` ever matches.
- **Bad tag protection**: `filterTags.pattern` excludes non-numeric tags (`latest`) from ever being considered a candidate version.
- **Failure visibility**: the existing `wattvn-api` `Kustomization`'s `healthChecks` (on `Deployment/wattvn-api`) already reports not-ready if a rollout from an auto-bumped tag fails to become healthy — this is an existing safety net, not something new added here.
- **Rollback**: a normal `git revert` of the automation's commit (or manually editing the tag back) if an auto-applied tag ever needs to be undone.

## Out of scope

- No change to `docker-publish.yml`'s tagging scheme.
- No PR-based review step for tag bumps (explicitly decided: direct-to-main).
- No image automation for any other component's image (only `wattvn-api` has one right now).
- No Terraform/cluster-bootstrap changes — the controllers already exist.
