# wattvn-api Flux Image Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Have Flux automatically bump `gitops/core/wattvn-api/helm.yaml`'s `values.image.tag` whenever CI publishes a new `wattvn-api` image, replacing the current manual bump.

**Architecture:** Add an `ImageRepository` + `ImagePolicy` (image-reflector-controller) scoped to the `wattvn-api` namespace, reusing the existing `ghcr-pull-secret`, plus an `ImageUpdateAutomation` (image-automation-controller) in `fluxcd-addons`/`flux-system` that rewrites a marker-commented scalar in `helm.yaml` and pushes directly to `main`. Both controllers are already deployed (part of `flux-instance`'s `instance.components`); only the CRD manifests are new.

**Tech Stack:** FluxCD `image.toolkit.fluxcd.io/v1` (`ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation`), Kustomize.

## Global Constraints

- Field names must match this cluster's live CRD schema (confirmed via `kubectl explain imagepolicy.spec --recursive` etc. against context `teleport.keycodemon.org-oci`): API group/version is `image.toolkit.fluxcd.io/v1`; `ImagePolicy.spec.policy.numerical.order` (not `numeric`); `ImageRepository.spec.secretRef` must be same-namespace as the `ImageRepository`.
- Direct commit to `main` — no separate review branch (confirmed decision). Achieved by omitting `spec.git.push` entirely (defaults to pushing back to the checked-out branch).
- `ImagePolicy.spec.filterTags.pattern: '^[0-9]+$'` — the `latest` tag must never be a candidate; only `docker-publish.yml`'s plain-integer `${{ github.run_number }}` tags are eligible.
- `ImageUpdateAutomation.spec.update.path` must be scoped to `./gitops/core/wattvn-api` — not the whole repo.
- YAML formatting: `yamlfmt` (150 char max line length) must pass on every new/changed file — neither new file falls under the `.yamlfmt` excludes (`gitops/flux/flux-system/`, `**/grafana/dashboards/*.yaml`).
- No Terraform changes — the controllers are already deployed.

---

### Task 1: Author and register the Flux image automation manifests

**Files:**
- Create: `gitops/core/wattvn-api/image-policy.yaml`
- Modify: `gitops/core/wattvn-api/kustomization.yaml`
- Modify: `gitops/core/wattvn-api/helm.yaml`
- Create: `gitops/core/fluxcd-addons/image-update-automation.yaml`
- Modify: `gitops/core/fluxcd-addons/kustomization.yaml`

**Interfaces:**
- Produces: an `ImagePolicy` named `wattvn-api` in namespace `wattvn-api` (referenced by the marker comment `{"$imagepolicy": "wattvn-api:wattvn-api:tag"}` added to `helm.yaml` in this same task — both sides must match exactly: policy name `wattvn-api`, policy namespace `wattvn-api`).

- [ ] **Step 1: Create `gitops/core/wattvn-api/image-policy.yaml`**

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

- [ ] **Step 2: Register it in `gitops/core/wattvn-api/kustomization.yaml`**

Current content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wattvn-api
resources:
  - namespace.yaml
  - secret.yaml
  - helm.yaml
  - httproute.yaml
  - servicemonitor.yaml
```

Replace with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wattvn-api
resources:
  - namespace.yaml
  - secret.yaml
  - helm.yaml
  - image-policy.yaml
  - httproute.yaml
  - servicemonitor.yaml
```

- [ ] **Step 3: Add the marker comment to `gitops/core/wattvn-api/helm.yaml`**

Current content:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: wattvn-api
  namespace: wattvn-api
spec:
  interval: 5m
  type: oci
  url: oci://ghcr.io/htthinh1999/charts
  secretRef:
    name: ghcr-pull-secret
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: wattvn-api
  namespace: wattvn-api
spec:
  interval: 10m
  timeout: 5m
  chart:
    spec:
      chart: wattvn-api
      version: '0.2.1' # bumped manually when Chart.yaml's version changes
      sourceRef:
        kind: HelmRepository
        name: wattvn-api
      interval: 5m
  releaseName: wattvn-api
  values:
    image:
      tag: '4' # bumped manually per push - matches the run-number tag from
        # docker-publish.yml. Flux Image Automation is a deliberate later
        # follow-up, not wired in here.
```

Replace the whole `values:` block at the end with:

```yaml
  values:
    image:
      # Auto-updated by the wattvn-api ImageUpdateAutomation - do not bump by hand.
      tag: '4' # {"$imagepolicy": "wattvn-api:wattvn-api:tag"}
```

(Everything above `values:` in the file is unchanged.)

- [ ] **Step 4: Create `gitops/core/fluxcd-addons/image-update-automation.yaml`**

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

- [ ] **Step 5: Register it in `gitops/core/fluxcd-addons/kustomization.yaml`**

Current content:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
resources:
  - flux.yaml
  - secret.yaml
  - receiver.yaml
  - provider.yaml
  - alert.yaml
  - podmonitor.yaml
  - httproute.yaml
```

Replace with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
resources:
  - flux.yaml
  - secret.yaml
  - receiver.yaml
  - provider.yaml
  - alert.yaml
  - podmonitor.yaml
  - httproute.yaml
  - image-update-automation.yaml
```

- [ ] **Step 6: Validate both Kustomize directories build cleanly**

Run: `kubectl kustomize gitops/core/wattvn-api`
Expected: builds without error; output includes the new `ImageRepository`/`ImagePolicy` resources and `helm.yaml`'s `HelmRelease` with the `# {"$imagepolicy": ...}` comment preserved on the `tag:` line.

Run: `kubectl kustomize gitops/core/fluxcd-addons`
Expected: builds without error; output includes the new `ImageUpdateAutomation` resource.

- [ ] **Step 7: Format and lint**

Run: `yamlfmt gitops/core/wattvn-api/image-policy.yaml gitops/core/wattvn-api/kustomization.yaml gitops/core/wattvn-api/helm.yaml gitops/core/fluxcd-addons/image-update-automation.yaml gitops/core/fluxcd-addons/kustomization.yaml`
Expected: exits 0 (reformats in place if needed — re-run `git diff` afterward to see if anything changed).

Run: `pre-commit run --all-files`
Expected: all hooks pass (or auto-fix trivial issues like trailing whitespace — re-stage if so).

- [ ] **Step 8: Commit**

```bash
git add gitops/core/wattvn-api/image-policy.yaml gitops/core/wattvn-api/kustomization.yaml gitops/core/wattvn-api/helm.yaml gitops/core/fluxcd-addons/image-update-automation.yaml gitops/core/fluxcd-addons/kustomization.yaml
git commit -m "Add Flux image automation for wattvn-api

ImageRepository/ImagePolicy scan ghcr.io/htthinh1999/wattvn-api for the
highest numeric tag (docker-publish.yml's run-number scheme; latest is
excluded via filterTags). ImageUpdateAutomation writes the resolved tag
into helm.yaml's marked scalar and pushes directly to main, replacing
the manual tag bump."
```

---

### Task 2: Push and verify live in the cluster

**Files:** none (verification only).

**Interfaces:**
- Consumes: the 5 files from Task 1, already committed.

- [ ] **Step 1: Push**

```bash
git push origin main
```

- [ ] **Step 2: Confirm Flux picked up the new resources**

Run: `kubectl --context=teleport.keycodemon.org-oci get kustomization -n flux-system wattvn-api flux-addons`
Expected: both show `READY: True` after their next reconcile (up to their `interval` — force it sooner if needed with `flux reconcile kustomization wattvn-api` / `flux reconcile kustomization flux-addons`, or `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/wattvn-api -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite` if the `flux` CLI isn't available).

- [ ] **Step 3: Confirm the ImageRepository is scanning successfully**

Run: `kubectl --context=teleport.keycodemon.org-oci get imagerepository -n wattvn-api wattvn-api -o yaml`
Expected: `status.conditions` includes a `Ready: "True"` condition (not a pull-auth error); `status.lastScanResult.tagCount` is nonzero.

- [ ] **Step 4: Confirm the ImagePolicy resolves to the currently-deployed tag**

Run: `kubectl --context=teleport.keycodemon.org-oci get imagepolicy -n wattvn-api wattvn-api -o jsonpath='{.status.latestRef.tag}'`
Expected: prints `4` (the tag already live in `helm.yaml` before this change) or a higher number if CI has published since — either way, a plain integer, never `latest`.

- [ ] **Step 5: Confirm the ImageUpdateAutomation is healthy**

Run: `kubectl --context=teleport.keycodemon.org-oci get imageupdateautomation -n flux-system wattvn-api -o yaml`
Expected: `status.conditions` includes `Ready: "True"`. If `status.latestRef`/`status.observedPolicies` (or the equivalent status fields on this Flux version) shows the resolved tag already matches `helm.yaml`, no new commit is expected — this is the correct outcome when nothing changed, not a failure.

- [ ] **Step 6: Run this repo's own pre-push SonarQube checklist**

Run the `sonarqube` MCP tool `analyze_file_list` on the 5 changed files from Task 1. Fix anything real it flags.

Then follow `CLAUDE.md`'s "Before pushing / finishing a session" section: wait for the `SonarQube Scan` GitHub Actions run on this commit, then query project key `htthinh1999_oci-free-cloud-k8s_450a287e-11d2-40b7-8ebb-126f1cbf6fd8` via `get_project_quality_gate_status`, `search_sonar_issues_in_projects` (`issueStatuses: [OPEN, CONFIRMED]`), `search_security_hotspots`. Fix any OPEN issue with a real change and triage any hotspot (`FIXED`/`SAFE`/`ACKNOWLEDGED`) before considering this done.
