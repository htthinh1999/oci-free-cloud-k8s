# wattvn Rename and Frontend Deploy Implementation Plan

> **For agentic workers:** This plan's cluster-mutating tasks (2-7) touch a
> live production cluster with real user data and MUST be executed directly
> by the controller, one task at a time, in order — NOT dispatched via
> superpowers:subagent-driven-development. This is an explicit decision in
> the approved design (`docs/superpowers/specs/2026-07-27-wattvn-rename-and-frontend-deploy-design.md`),
> not an oversight. Task 1 (pure git, no cluster mutation) may be executed
> the same way. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `gitops/core/wattvn-api/` to `gitops/core/wattvn/` — including
the Kubernetes Namespace, HelmRelease/releaseName, and every namespaced
resource — to reflect that the app repo's Helm chart (bumped to `0.3.0`) now
deploys both the `wattvn-api` backend and a new `wattvn-web` PWA frontend from
one release, while migrating the DataProtection encryption key ring so no
already-encrypted data (the one real EVN account's password + cached token)
is lost.

**Architecture:** A new `gitops/core/wattvn/` GitOps component is added
alongside the existing `gitops/core/wattvn-api/` (both live simultaneously
during migration). The new component's Helm values start the API side at
`replicaCount: 0` so it never touches a throwaway key ring. Two temporary
`busybox` debug pods bridge a `tar`-piped copy of the DataProtection key files
from the old PVC to the new PVC (the app's chiseled runtime image has no
shell, confirmed empirically, so the copy can't run inside the real app pod).
Once the new API pod is verified decrypting real data correctly, traffic cuts
over via a single HTTPRoute swap, followed by a soak period, followed by
deletion of the old namespace.

**Tech Stack:** FluxCD (`Kustomization`, `HelmRepository`/`HelmRelease`,
`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`), Gateway API
(`HTTPRoute`), `external-secrets.io` (`ExternalSecret`/`ClusterSecretStore`),
Kustomize, `kubectl` against context `teleport.keycodemon.org-oci`.

## Global Constraints

- Cluster context for every `kubectl` command in this plan: `teleport.keycodemon.org-oci`.
- The app's Helm chart (`chart/templates/_helpers.tpl` in the `wattvn` app
  repo) derives resource names directly from `.Release.Name`:
  `wattvn.api.fullname` = bare `{{ .Release.Name }}` (so with
  `releaseName: wattvn`, the API Deployment/Service is named `wattvn` and its
  PVC — from `api-deployment.yaml` — is `wattvn-dataprotection-keys`);
  `wattvn.web.fullname` = `{{ .Release.Name }}-web` (so the web
  Deployment/Service is `wattvn-web`). These exact names are load-bearing for
  every HTTPRoute `backendRef` and the PVC migration in this plan.
- Chart identity: `Chart.yaml` `name: wattvn`, `version: 0.3.0` (confirmed in
  the app repo at `/Users/thinhhuynh/Projects/wattvn/chart/Chart.yaml`).
- Live cluster state as of this plan (confirmed via `kubectl` against the
  namespace `wattvn-api`): Deployment image `ghcr.io/htthinh1999/wattvn-api:15`,
  HelmRelease `wattvn-api` on chart `wattvn-api@0.2.3`, `releaseName: wattvn-api`,
  PVC `wattvn-api-dataprotection-keys` (Bound, 256Mi, longhorn, RWO), a single
  running pod, ImageRepository has scanned 14 numeric tags. No `wattvn`
  namespace exists yet.
- `ghcr.io/htthinh1999/wattvn-web` is tagged by
  `.github/workflows/docker-publish.yml`'s `build-and-push-web` job with the
  same `:latest` + `:${{ github.run_number }}` scheme as the API image.
  CI run number `16` (`build-and-push-api` and `build-and-push-web`, both
  `success`) published `ghcr.io/htthinh1999/wattvn-api:16` and
  `ghcr.io/htthinh1999/wattvn-web:16` — confirmed via
  `gh run view 30286834271 --json jobs` before Task 1 was executed.
- **Naming granularity** (per approved design): only resources representing
  "the release as a whole" become bare `wattvn` — `Namespace`, top-level
  `Kustomization`, `HelmRepository`, `HelmRelease`/`releaseName`,
  `wattvn-api-secrets` → `wattvn-secrets`. Resources scoped to one app/image
  stay app-specific: the two `HTTPRoute`s, the two `ImageRepository`/
  `ImagePolicy` pairs, and the `ServiceMonitor` (stays named `wattvn-api` —
  nginx exposes no Prometheus metrics endpoint). One `ImageUpdateAutomation`
  covers both images' markers (Flux automation operates per git path, not per
  image).
- `gitops/core/grafana/kustomization.yaml`'s `wattvn-api-grafana-dashboards`
  ConfigMap generator name is explicitly OUT OF SCOPE — do not touch it.
- YAML formatting: `yamlfmt` (150 char max line length, `retain_line_breaks: true`)
  must pass on every new/changed file (none of this plan's files fall under
  `.yamlfmt`'s excludes). Run `pre-commit run --all-files` before every
  commit in this plan.
- Direct commits to `main` — this repo has no PR workflow (single-user,
  confirmed via `git branch -a`/`git log`; every prior gitops change here is
  a direct commit to `main`).
- No Terraform changes anywhere in this plan.
- Tasks 5 and 7 are hard checkpoints: do not proceed past them without an
  explicit human go-ahead in chat, regardless of how routine the intervening
  verification looked.
- Before considering the whole plan done, follow this repo's own
  `CLAUDE.md` "Before pushing / finishing a session" checklist (SonarQube
  project key `htthinh1999_oci-free-cloud-k8s_450a287e-11d2-40b7-8ebb-126f1cbf6fd8`)
  against every file this plan touches.

---

### Task 1: Create `gitops/core/wattvn/` alongside the existing `wattvn-api/`

**Files:**
- Create: `gitops/core/wattvn/namespace.yaml`
- Create: `gitops/core/wattvn/kustomization.yaml`
- Create: `gitops/core/wattvn/flux.yaml`
- Create: `gitops/core/wattvn/secret.yaml`
- Create: `gitops/core/wattvn/helm.yaml`
- Create: `gitops/core/wattvn/image-policy.yaml`
- Create: `gitops/core/wattvn/image-update-automation.yaml`
- Create: `gitops/core/wattvn/httproute.yaml` (web route only — the API route
  is added later, at cutover in Task 5)
- Create: `gitops/core/wattvn/servicemonitor.yaml`
- Modify: `gitops/core/kustomization.yaml`

**Interfaces:**
- Produces: a `wattvn` namespace with `HelmRelease wattvn` deploying the
  `wattvn` chart at `api.replicaCount: 0` (no API pod, so no throwaway key
  ring gets generated) and `web.replicaCount` at its chart default (1, so the
  frontend goes live immediately). The old `wattvn-api` namespace, its
  Kustomization, and every one of its resources are left completely
  untouched by this task — do not edit or delete anything under
  `gitops/core/wattvn-api/` in this task.

- [ ] **Step 1: Create `gitops/core/wattvn/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: wattvn
```

- [ ] **Step 2: Create `gitops/core/wattvn/secret.yaml`**

Same 3 `ExternalSecret`s as `gitops/core/wattvn-api/secret.yaml`, same vault
refs (no vault data migration needed — these re-fetch fresh from
`oracle-vault` on apply), renamed `wattvn-api-secrets` → `wattvn-secrets`
per the naming-granularity rule; `ghcr-pull-secret` and
`wattvn-tailscale-authkey` keep their names:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: wattvn-secrets
  namespace: wattvn
spec:
  refreshInterval: 3m
  secretStoreRef:
    kind: ClusterSecretStore
    name: oracle-vault
  target:
    name: wattvn-secrets
    creationPolicy: Owner
    deletionPolicy: Delete
    template:
      engineVersion: v2
      data:
        ConnectionStrings__Postgres: "Host=wattvn-postgres-rw.wattvn-postgres.svc.cluster.local;Port=5432;\
          Database=wattvn;Username=wattvn;Password={{ .pgPassword }}"
        Jwt__Secret: "{{ .jwtSecret }}"
        Internal__SyncSecret: "{{ .internalSyncSecret }}"
  data:
    - secretKey: pgPassword
      remoteRef:
        # SAME vault key as gitops/core/wattvn-postgres/secret.yaml - single
        # source of truth for the app-user password.
        key: wattvn-postgres-app-password
        version: CURRENT
        decodingStrategy: None
    - secretKey: jwtSecret
      remoteRef:
        key: wattvn-jwt-secret
        version: CURRENT
        decodingStrategy: None
    - secretKey: internalSyncSecret
      remoteRef:
        key: wattvn-internal-sync-secret
        version: CURRENT
        decodingStrategy: None
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ghcr-pull-secret
  namespace: wattvn
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: oracle-vault
  target:
    name: ghcr-pull-secret
    creationPolicy: Owner
    deletionPolicy: Delete
    template:
      engineVersion: v2
      type: kubernetes.io/dockerconfigjson
      data:
        # Serves two consumers: this chart's Deployment imagePullSecrets (for
        # kubelet pulling the private image) and helm.yaml's HelmRepository
        # secretRef (for Flux pulling the private chart) - both just need a
        # same-namespace dockerconfigjson Secret, so one suffices.
        .dockerconfigjson: |
          {{ printf `{"auths":{"ghcr.io":{"username":"htthinh1999","password":"%s","auth":"%s"}}}` .token (printf "htthinh1999:%s" .token | b64enc) }}
  data:
    - secretKey: token
      remoteRef:
        key: ghcr-pull-token
        version: CURRENT
        decodingStrategy: None
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: wattvn-tailscale-authkey
  namespace: wattvn
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: oracle-vault
  target:
    name: wattvn-tailscale-authkey
    creationPolicy: Owner
    deletionPolicy: Delete
    template:
      engineVersion: v2
      data:
        authkey: "{{ .authkey }}"
  data:
    - secretKey: authkey
      remoteRef:
        key: wattvn-tailscale-authkey
        version: CURRENT
        decodingStrategy: None
```

- [ ] **Step 3: Create `gitops/core/wattvn/helm.yaml`**

`existingSecretName` must be overridden here since the chart's default
(`wattvn-api-secrets`, see `chart/values.yaml` in the app repo) no longer
matches the renamed Secret from Step 2. `api.replicaCount: 0` is the load
-bearing safety line for this whole migration — do not start it at `1`.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: wattvn
  namespace: wattvn
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
  name: wattvn
  namespace: wattvn
spec:
  interval: 10m
  timeout: 5m
  chart:
    spec:
      chart: wattvn
      version: '0.3.0' # bumped manually when Chart.yaml's version changes
      sourceRef:
        kind: HelmRepository
        name: wattvn
      interval: 5m
  releaseName: wattvn
  values:
    api:
      # Kept at 0 until the DataProtection key-ring migration (Task 3) is
      # verified (Task 4) - an API pod running before then would generate a
      # throwaway key ring and start actively serving requests with it.
      # Bumped to 1 only in Task 4.
      replicaCount: 0
      existingSecretName: wattvn-secrets
      image:
        # Auto-updated by the wattvn ImageUpdateAutomation - do not bump by hand.
        tag: '16' # {"$imagepolicy": "wattvn:wattvn-api:tag"}
    web:
      image:
        # Auto-updated by the wattvn ImageUpdateAutomation - do not bump by hand.
        tag: '16' # {"$imagepolicy": "wattvn:wattvn-web:tag"}
```

- [ ] **Step 4: Create `gitops/core/wattvn/image-policy.yaml`**

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: wattvn-api
  namespace: wattvn
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
  namespace: wattvn
spec:
  imageRepositoryRef:
    name: wattvn-api
  policy:
    numerical:
      order: asc
  filterTags:
    pattern: '^[0-9]+$'
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: wattvn-web
  namespace: wattvn
spec:
  image: ghcr.io/htthinh1999/wattvn-web
  interval: 5m
  secretRef:
    name: ghcr-pull-secret
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: wattvn-web
  namespace: wattvn
spec:
  imageRepositoryRef:
    name: wattvn-web
  policy:
    numerical:
      order: asc
  filterTags:
    pattern: '^[0-9]+$'
```

- [ ] **Step 5: Create `gitops/core/wattvn/image-update-automation.yaml`**

One resource covers both images' markers — Flux automation operates per git
path (`update.path`), not per image:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: wattvn
  namespace: wattvn
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
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

        Automation name: {{ .AutomationObject }}

        Files:
        {{ range $filename, $_ := .Changed.FileChanges -}}
        - {{ $filename }}
        {{ end -}}

        Objects:
        {{ range $resource, $changes := .Changed.Objects -}}
        - {{ $resource.Kind }} {{ $resource.Name }}
          Changes:
        {{- range $_, $change := $changes }}
            - {{ $change.OldValue }} -> {{ $change.NewValue }}
        {{ end -}}
        {{ end -}}
  update:
    path: ./gitops/core/wattvn
    strategy: Setters
```

- [ ] **Step 6: Create `gitops/core/wattvn/httproute.yaml` (web route only)**

The API route is intentionally NOT added here — it would conflict with the
still-live old route on the same hostname. It's added in Task 5, at cutover.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wattvn-web
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
spec:
  parentRefs:
    - name: envoy
      namespace: envoy-gateway
  hostnames:
    - "wattvn.keycodemon.org"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/"
      backendRefs:
        - name: wattvn-web
          port: 80
```

- [ ] **Step 7: Create `gitops/core/wattvn/servicemonitor.yaml`**

Stays named `wattvn-api` per the naming-granularity rule (nginx exposes no
metrics endpoint, so there's nothing for a `wattvn-web` ServiceMonitor to
scrape):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: wattvn-api
  namespace: wattvn
  labels:
    # Required for kube-prometheus-stack's Prometheus to pick this up - confirmed
    # live against the cluster's Prometheus object
    # (spec.serviceMonitorSelector.matchLabels).
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: wattvn-api
      app.kubernetes.io/instance: wattvn
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 8: Create `gitops/core/wattvn/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wattvn
resources:
  - namespace.yaml
  - secret.yaml
  - helm.yaml
  - image-policy.yaml
  - image-update-automation.yaml
  - httproute.yaml
  - servicemonitor.yaml
```

- [ ] **Step 9: Create `gitops/core/wattvn/flux.yaml`**

Health-checks both Deployments the chart creates (`wattvn` for the API,
`wattvn-web` for the frontend):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: wattvn
  namespace: flux-system
spec:
  interval: 1h
  path: ./gitops/core/wattvn
  prune: true
  dependsOn:
    - name: wattvn-postgres
    - name: external-secrets
    - name: envoy-gateway
  sourceRef:
    kind: GitRepository
    name: flux-system
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: wattvn-web
      namespace: wattvn
```

Note: `wattvn` (the API Deployment) is intentionally NOT in `healthChecks`
yet — at `replicaCount: 0` it has no pods, so a health check would never
report ready and would block this Kustomization's `Ready` condition forever.
Add it back in Task 4 once `api.replicaCount` goes to `1`.

- [ ] **Step 10: Register the new component in `gitops/core/kustomization.yaml`**

Current content has `- wattvn-api/flux.yaml` as its last resource (line 22).
Add the new one immediately after it — do NOT remove `wattvn-api/flux.yaml`
in this task:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
resources:
  - external-secrets/flux.yaml
  - external-dns/flux.yaml
  - cert-manager/flux.yaml
  - cert-manager/issuer/flux.yaml
  - origin-ca-issuer/flux.yaml
  - dex/flux.yaml
  - grafana/flux.yaml
  - longhorn/flux.yaml
  - kube-prometheus-stack/flux.yaml
  - teleport/flux.yaml
  - metrics-server/flux.yaml
  - fluxcd-addons/flux.yaml
  - envoy-gateway/flux.yaml
  - envoy-gateway/resources/flux.yaml
  - sonarqube/flux.yaml
  - cloudnative-pg/flux.yaml
  - wattvn-postgres/flux.yaml
  - wattvn-api/flux.yaml
  - wattvn/flux.yaml
```

- [ ] **Step 11: Validate the new Kustomize directory builds cleanly**

Run: `kubectl kustomize gitops/core/wattvn`
Expected: builds without error; output includes 13 objects total: 1
`Namespace`, 3 `ExternalSecret`s, 1 `HelmRepository`, 1 `HelmRelease`, 2
`ImageRepository`s + 2 `ImagePolicy`s, 1 `ImageUpdateAutomation`, 1
`HTTPRoute`, 1 `ServiceMonitor`; `api.replicaCount: 0` and
`existingSecretName: wattvn-secrets` present under
`HelmRelease.spec.values.api`, and both `# {"$imagepolicy": ...}` marker
comments preserved on their `tag:` lines.

Run: `kubectl kustomize gitops/core`
Expected: builds without error; output includes both `wattvn-api/flux.yaml`'s
and `wattvn/flux.yaml`'s `Kustomization` objects.

- [ ] **Step 12: Format and lint**

Run: `yamlfmt gitops/core/wattvn/*.yaml gitops/core/kustomization.yaml`
Expected: exits 0 (reformats in place if needed — re-run `git diff`
afterward to see if anything changed).

Run: `pre-commit run --all-files`
Expected: all hooks pass (or auto-fix trivial issues like trailing
whitespace — re-stage if so).

- [ ] **Step 13: Commit**

```bash
git add gitops/core/wattvn/ gitops/core/kustomization.yaml
git commit -m "Add gitops/core/wattvn/ alongside wattvn-api/ for the api+web rename

New component deploys the unified wattvn chart (0.3.0) into a new 'wattvn'
namespace, api.replicaCount held at 0 until the DataProtection key-ring
migration (see docs/superpowers/specs/2026-07-27-wattvn-rename-and-frontend-deploy-design.md)
is verified. The old wattvn-api/ component is untouched and still live."
```

---

### Task 2: Push and verify the new namespace reconciles healthy

**Files:** none (verification only).

**Interfaces:**
- Consumes: the files from Task 1, already committed.

- [ ] **Step 1: Push**

```bash
git push origin main
```

- [ ] **Step 2: Confirm the new Kustomization reconciled**

Run: `kubectl --context=teleport.keycodemon.org-oci get kustomization -n flux-system wattvn`
Expected: `READY: True` after its next reconcile — force it sooner if
needed: `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/wattvn -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.

- [ ] **Step 3: Confirm the new namespace and its resources exist**

Run: `kubectl --context=teleport.keycodemon.org-oci get all,externalsecret,helmrelease,imagerepository,imagepolicy,imageupdateautomation,httproute,servicemonitor -n wattvn`
Expected: a `wattvn-web` Deployment/Service/pod (1 replica, Running); a
`wattvn` Deployment/Service present but **0/0** replicas (no pods — this is
correct, not a failure); a `wattvn-dataprotection-keys` PVC bound; all 3
`ExternalSecret`s show `SecretSynced`/`True`; `helmrelease.helm.toolkit.fluxcd.io/wattvn`
shows `Ready: True`.

- [ ] **Step 4: Confirm the new empty PVC exists and is truly empty**

Run: `kubectl --context=teleport.keycodemon.org-oci get pvc -n wattvn wattvn-dataprotection-keys`
Expected: `Bound`, `256Mi`, `RWO`, `longhorn` — matching the old PVC's spec.
This PVC has never been mounted by a running pod yet (0 replicas), so it's
guaranteed empty — no key ring has been generated into it.

- [ ] **Step 5: Confirm the web HTTPRoute resolves**

Run: `curl -sS -o /dev/null -w '%{http_code}\n' https://wattvn.keycodemon.org/`
Expected: `200` (the frontend's `nginx` serving `index.html`).

Run: `kubectl --context=teleport.keycodemon.org-oci get httproute -n wattvn wattvn-web -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'`
Expected: `True`.

- [ ] **Step 6: Confirm both ImageRepositories are scanning successfully**

Run: `kubectl --context=teleport.keycodemon.org-oci get imagerepository -n wattvn wattvn-api wattvn-web -o wide`
Expected: both `READY: True`, nonzero tag counts, no pull-auth errors.

- [ ] **Step 7: Confirm the old `wattvn-api` namespace is completely untouched**

Run: `kubectl --context=teleport.keycodemon.org-oci get pod,pvc -n wattvn-api`
Expected: identical to before Task 1 — the same single running pod, the
same `wattvn-api-dataprotection-keys` PVC, unaffected by anything in Task 1
or this task.

---

### Task 3: Migrate the DataProtection key ring

**Files:** none (imperative cluster operations only — no GitOps files
change in this task).

**Interfaces:**
- Consumes: `wattvn-api-dataprotection-keys` PVC in namespace `wattvn-api`
  (source, has the real key ring); `wattvn-dataprotection-keys` PVC in
  namespace `wattvn` (destination, confirmed empty in Task 2 Step 4).

- [ ] **Step 1: Create a temporary debug pod mounting the OLD PVC**

```bash
kubectl --context=teleport.keycodemon.org-oci run keys-migrate-src -n wattvn-api \
  --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl --context=teleport.keycodemon.org-oci wait --for=condition=Ready pod/keys-migrate-src -n wattvn-api --timeout=60s
```

Then patch it to mount the PVC (busybox has no built-in way to specify a
volume via `kubectl run`, so apply a manifest instead of the two commands
above):

```bash
cat <<'EOF' | kubectl --context=teleport.keycodemon.org-oci apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: keys-migrate-src
  namespace: wattvn-api
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: keys
          mountPath: /keys
  volumes:
    - name: keys
      persistentVolumeClaim:
        claimName: wattvn-api-dataprotection-keys
EOF
kubectl --context=teleport.keycodemon.org-oci wait --for=condition=Ready pod/keys-migrate-src -n wattvn-api --timeout=60s
```

- [ ] **Step 2: Create a temporary debug pod mounting the NEW PVC**

```bash
cat <<'EOF' | kubectl --context=teleport.keycodemon.org-oci apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: keys-migrate-dst
  namespace: wattvn
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: keys
          mountPath: /keys
  volumes:
    - name: keys
      persistentVolumeClaim:
        claimName: wattvn-dataprotection-keys
EOF
kubectl --context=teleport.keycodemon.org-oci wait --for=condition=Ready pod/keys-migrate-dst -n wattvn --timeout=60s
```

- [ ] **Step 3: List the source files before copying (for later comparison)**

Run: `kubectl --context=teleport.keycodemon.org-oci exec -n wattvn-api keys-migrate-src -- ls -la /keys`
Expected: one or more `key-*.xml` files (ASP.NET Core Data Protection's key
ring format) plus possibly a lock file. Note the file count and names.

- [ ] **Step 4: Pipe a tar stream from the source pod to the destination pod**

```bash
kubectl --context=teleport.keycodemon.org-oci exec -n wattvn-api keys-migrate-src -- tar -cf - -C /keys . \
  | kubectl --context=teleport.keycodemon.org-oci exec -i -n wattvn keys-migrate-dst -- tar -xf - -C /keys
```

- [ ] **Step 5: Verify the file listings match**

Run: `kubectl --context=teleport.keycodemon.org-oci exec -n wattvn-api keys-migrate-src -- ls -la /keys`
Run: `kubectl --context=teleport.keycodemon.org-oci exec -n wattvn keys-migrate-dst -- ls -la /keys`
Expected: identical file names and byte sizes on both sides (timestamps may
differ — that's fine).

- [ ] **Step 6: Delete both debug pods**

```bash
kubectl --context=teleport.keycodemon.org-oci delete pod keys-migrate-src -n wattvn-api
kubectl --context=teleport.keycodemon.org-oci delete pod keys-migrate-dst -n wattvn
```

---

### Task 4: Scale the new API up and verify it decrypts real data

**Files:**
- Modify: `gitops/core/wattvn/helm.yaml`
- Modify: `gitops/core/wattvn/flux.yaml`

**Interfaces:**
- Consumes: the migrated key ring from Task 3, now sitting on
  `wattvn-dataprotection-keys` (unmounted by any running pod since Task 3's
  debug pod was deleted).

- [ ] **Step 1: Bump `api.replicaCount` to 1 in `gitops/core/wattvn/helm.yaml`**

Change:

```yaml
    api:
      # Kept at 0 until the DataProtection key-ring migration (Task 3) is
      # verified (Task 4) - an API pod running before then would generate a
      # throwaway key ring and start actively serving requests with it.
      # Bumped to 1 only in Task 4.
      replicaCount: 0
```

to:

```yaml
    api:
      replicaCount: 1
```

(Leave `existingSecretName` and `image.tag` as-is from Task 1.)

- [ ] **Step 2: Add the API Deployment back into `gitops/core/wattvn/flux.yaml`'s health checks**

```yaml
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: wattvn
      namespace: wattvn
    - apiVersion: apps/v1
      kind: Deployment
      name: wattvn-web
      namespace: wattvn
```

- [ ] **Step 3: Format, lint, commit, push**

```bash
yamlfmt gitops/core/wattvn/helm.yaml gitops/core/wattvn/flux.yaml
pre-commit run --all-files
git add gitops/core/wattvn/helm.yaml gitops/core/wattvn/flux.yaml
git commit -m "Scale up the new wattvn API deployment after key-ring migration

DataProtection key ring migrated in the prior manual step (see the
migration runbook in docs/superpowers/specs/2026-07-27-wattvn-rename-and-frontend-deploy-design.md).
api.replicaCount 0 -> 1, and the API Deployment is added back to this
Kustomization's health checks."
git push origin main
```

- [ ] **Step 4: Wait for reconcile and the new pod to become Ready**

Run: `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/wattvn -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`
Run: `kubectl --context=teleport.keycodemon.org-oci get pod -n wattvn -l app.kubernetes.io/name=wattvn-api -w`
Expected: a new pod reaches `2/2 Running` (app container + Tailscale
sidecar) within a few minutes — the startup probe alone allows up to ~5
minutes per `chart/values.yaml`'s `api.probes.startup`.

- [ ] **Step 5: Confirm no DataProtection warning in the new pod's logs**

Run: `kubectl --context=teleport.keycodemon.org-oci logs -n wattvn deploy/wattvn -c wattvn-api --since=5m | grep -i "encryptor\|dataprotection"`
Expected: no output, or only informational lines — specifically, no "No XML
encryptor configured" warning (which would mean the migrated key ring
wasn't found/loaded and a fresh throwaway one was generated instead).

- [ ] **Step 6: Trigger a manual internal sync against the NEW pod specifically and confirm it decrypts real data**

Get the internal sync secret and port-forward directly to the new pod (not
through the Service, which still only has the one new pod as an endpoint
anyway, but this way there's no ambiguity):

```bash
INTERNAL_SECRET=$(kubectl --context=teleport.keycodemon.org-oci get secret wattvn-secrets -n wattvn -o jsonpath='{.data.Internal__SyncSecret}' | base64 -d)
kubectl --context=teleport.keycodemon.org-oci port-forward -n wattvn deploy/wattvn 18080:8080 &
sleep 2
curl -sS -X POST http://localhost:18080/internal/sync -H "X-Internal-Secret: $INTERNAL_SECRET"
kill %1
```

Expected JSON response: `{"totalAccounts":1,"succeededCount":1}` — the one
real EVN account synced successfully, proving the migrated key ring
decrypts its stored password and/or cached token correctly. A
`succeededCount` of `0` means the migration failed (stale password
decrypts to garbage, or an unrelated EVN CPC issue) — do not proceed to
Task 5 if this happens; investigate before continuing.

---

### Task 5 (CHECKPOINT): Cut over the API's HTTPRoute

**Do not start this task without an explicit human go-ahead in chat first.**
Everything in Tasks 1-4 is reversible with zero effect on production traffic
(the old namespace has been serving `wattvn-api.keycodemon.org` the whole
time, untouched). This task is the first one that changes what production
traffic hits.

**Files:**
- Modify: `gitops/core/wattvn/httproute.yaml` (add the API route)
- Modify: `gitops/core/wattvn-api/httproute.yaml` (remove the API route)
- Modify: `gitops/core/wattvn-api/kustomization.yaml` (drop the now-empty
  `httproute.yaml` from the resource list)

**Interfaces:**
- Consumes: the `wattvn` Service in namespace `wattvn` (verified Ready and
  decrypting correctly by Task 4).

- [ ] **Step 1: Ask for explicit go-ahead**

Post in chat: "Ready to cut over `wattvn-api.keycodemon.org` from the old
namespace to the new one. This is the first traffic-affecting change in
this migration. Proceed?" Wait for an explicit yes before continuing.

- [ ] **Step 2: Add the API route to `gitops/core/wattvn/httproute.yaml`**

Append as a second document in the same file (`backendRefs.name: wattvn` —
the API Service's new bare-fullname):

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wattvn-api
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
spec:
  parentRefs:
    - name: envoy
      namespace: envoy-gateway
  hostnames:
    - "wattvn-api.keycodemon.org"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/"
      backendRefs:
        - name: wattvn
          port: 80
```

- [ ] **Step 3: Delete `gitops/core/wattvn-api/httproute.yaml`**

```bash
git rm gitops/core/wattvn-api/httproute.yaml
```

- [ ] **Step 4: Remove `httproute.yaml` from `gitops/core/wattvn-api/kustomization.yaml`**

Change:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wattvn-api
resources:
  - namespace.yaml
  - secret.yaml
  - helm.yaml
  - image-policy.yaml
  - image-update-automation.yaml
  - httproute.yaml
  - servicemonitor.yaml
```

to:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wattvn-api
resources:
  - namespace.yaml
  - secret.yaml
  - helm.yaml
  - image-policy.yaml
  - image-update-automation.yaml
  - servicemonitor.yaml
```

- [ ] **Step 5: Format, lint, commit, push (single atomic commit for the whole cutover)**

```bash
yamlfmt gitops/core/wattvn/httproute.yaml gitops/core/wattvn-api/kustomization.yaml
pre-commit run --all-files
git add gitops/core/wattvn/httproute.yaml gitops/core/wattvn-api/httproute.yaml gitops/core/wattvn-api/kustomization.yaml
git commit -m "Cut over wattvn-api.keycodemon.org to the new wattvn namespace

Single atomic change: the old namespace's HTTPRoute is removed at the same
time the new namespace's HTTPRoute for the same hostname is added, so the
hostname is never claimed by both or neither. Same-namespace resources
(Deployment, Service, PVC, Secrets, HelmRelease) in wattvn-api are left
running and untouched - they're deleted separately in Task 7, after a soak
period."
git push origin main
```

- [ ] **Step 6: Wait for reconcile and verify traffic is served from the new namespace**

Run: `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/wattvn -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`
Run: `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/wattvn-api -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`

Run: `curl -sS https://wattvn-api.keycodemon.org/health`
Expected: the same healthy response as before the cutover — the domain
itself doesn't change, only which namespace answers it.

Run: `kubectl --context=teleport.keycodemon.org-oci get httproute -n wattvn wattvn-api -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'`
Expected: `True`.

Run: `kubectl --context=teleport.keycodemon.org-oci get httproute -n wattvn-api 2>&1`
Expected: `No resources found` (or a "not found" error) — confirms the old
route is gone and can no longer claim the hostname.

---

### Task 6: Soak period

**Files:** none.

**Interfaces:** none — pure observation.

- [ ] **Step 1: Watch the new pod's logs and the app's own sync-failure signal for errors**

Run (leave running, or repeat periodically): `kubectl --context=teleport.keycodemon.org-oci logs -n wattvn deploy/wattvn -c wattvn-api -f`
Watch for unhandled exceptions, repeated `AuthFailed`/`Error` sync results,
or crash-looping.

- [ ] **Step 2: Ask the human how long to soak**

Duration is explicitly the human's call per the approved design — do not
pick a duration unilaterally and do not proceed to Task 7 until they say so.

---

### Task 7 (CHECKPOINT): Delete the old `wattvn-api` namespace

**Do not start this task without an explicit human go-ahead in chat first.**
After this task, there is no rollback path — the old namespace's Deployment,
Service, PVC, Secrets, HelmRelease, HelmRepository, and image-automation
resources are all gone for good. This is safe specifically because Task 4
already proved the migrated key ring decrypts real production data
correctly, and Task 6's soak period found nothing wrong.

**Files:**
- Delete: `gitops/core/wattvn-api/` (entire directory)
- Modify: `gitops/core/kustomization.yaml`

**Interfaces:** none — this only removes resources.

- [ ] **Step 1: Ask for explicit go-ahead**

Post in chat: "Soak period is done and clean. Ready to permanently delete
the old `wattvn-api` namespace and everything in it (old Deployment,
Service, PVC, Secrets, HelmRelease). This is not reversible. Proceed?" Wait
for an explicit yes before continuing.

- [ ] **Step 2: Remove `wattvn-api/flux.yaml` from `gitops/core/kustomization.yaml`**

Change:

```yaml
  - wattvn-postgres/flux.yaml
  - wattvn-api/flux.yaml
  - wattvn/flux.yaml
```

to:

```yaml
  - wattvn-postgres/flux.yaml
  - wattvn/flux.yaml
```

- [ ] **Step 3: Delete the whole `gitops/core/wattvn-api/` directory**

```bash
git rm -r gitops/core/wattvn-api/
```

- [ ] **Step 4: Format, lint, commit, push**

```bash
yamlfmt gitops/core/kustomization.yaml
pre-commit run --all-files
git add gitops/core/kustomization.yaml
git commit -m "Delete the old wattvn-api namespace

Cutover (see prior commits) and its soak period are both complete. Flux's
prune:true on this Kustomization cascades the delete: old Deployment,
Service, PVC, ExternalSecrets, HelmRelease, HelmRepository, ImageRepository/
ImagePolicy, and ImageUpdateAutomation in the wattvn-api namespace are all
removed. The migrated DataProtection key ring already lives on in the new
wattvn namespace's PVC, verified working in an earlier commit."
git push origin main
```

- [ ] **Step 5: Wait for reconcile and verify the old namespace is fully gone**

Run: `kubectl --context=teleport.keycodemon.org-oci annotate kustomization/flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`
(or wait up to the parent Kustomization's own `interval`)

Run: `kubectl --context=teleport.keycodemon.org-oci get ns wattvn-api`
Expected: `Error from server (NotFound)`.

Run: `kubectl --context=teleport.keycodemon.org-oci get kustomization -n flux-system`
Expected: no `wattvn-api` entry; `wattvn` shows `READY: True`.

- [ ] **Step 6: Final confirmation that production is unaffected**

Run: `curl -sS https://wattvn-api.keycodemon.org/health` and
`curl -sS -o /dev/null -w '%{http_code}\n' https://wattvn.keycodemon.org/`
Expected: both healthy — the namespace deletion only removed resources
that were already fully replaced by the `wattvn` namespace back in Task 5.

- [ ] **Step 7: Run the repo's pre-push SonarQube/quality checklist**

Follow `CLAUDE.md`'s "Before pushing / finishing a session" section (project
key `htthinh1999_oci-free-cloud-k8s_450a287e-11d2-40b7-8ebb-126f1cbf6fd8`)
against every file changed across all commits in this plan. Fix any OPEN
issue with a real change and triage any hotspot before considering this
plan complete.
