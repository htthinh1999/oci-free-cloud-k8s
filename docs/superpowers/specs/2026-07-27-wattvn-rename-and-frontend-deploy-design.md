# Rename gitops/core/wattvn-api/ to wattvn/, deploy the frontend — Design

Date: 2026-07-27

## Summary

The `wattvn` app repo's Helm chart was restructured to deploy both the
`wattvn-api` backend and a new `wattvn-web` PWA frontend from one unified
chart (bumped to version `0.3.0`). This repo's `gitops/core/wattvn-api/`
folder currently only manages the API alone, still pinned to chart `0.2.3`
with a flat `values.image.tag` override. This work: (1) renames the folder
and its umbrella-level GitOps resources to `wattvn` to reflect that one
release now deploys both apps, (2) bumps the chart to `0.3.0` and
restructures the values override to match its new `api:`/`web:` nesting,
and (3) adds the frontend's own GitOps resources (HTTPRoute, image
tracking). Live cluster state as of this design: 5 users, 5 houses, 1 EVN
account with an encrypted password + cached token — real data, small scale.

## Decisions

- **The Kubernetes Namespace itself gets renamed** (`wattvn-api` → `wattvn`),
  per explicit confirmation — even though namespace names are invisible to
  end users and this is the riskier of the two rename options considered
  (the safer alternative, keeping the namespace and only renaming the
  release, was proposed and declined). This means every namespaced object
  (Deployment, Service, PVC, Secrets) gets recreated under the new
  namespace — there is no in-place namespace rename in Kubernetes.
- **The DataProtection-keys PVC requires an explicit migration**, not a
  fresh start. The app's Helm chart computes this PVC's name as
  `{{ .Release.Name }}-dataprotection-keys` — a namespace change forces a
  new PVC object regardless of naming, and losing the existing key ring
  would permanently invalidate the one real EVN account's already-encrypted
  password and cached token in Postgres (there is no "update EVN
  credentials" endpoint in the API — the only recovery from a lost key ring
  is deleting and recreating that house). Data is small (a handful of small
  XML key files), so a direct copy is the right tool, not a bulk backup
  system.
- **The app's chiseled runtime image has no shell** (confirmed: `kubectl
  exec` into it fails outright, even for `ls`) — the key-file copy cannot
  run inside the actual API pod. Two temporary `busybox` debug pods (one
  per namespace, each mounting the relevant PVC) bridge the copy via a
  piped `tar` stream over `kubectl exec`, then get deleted.
- **Cutover is staged, not atomic-with-migration.** The new namespace's
  resources are applied and verified (scaled to 0 during key migration,
  then scaled up and confirmed decrypting correctly) *before* the
  `wattvn-api.keycodemon.org` HTTPRoute is switched over — the frontend's
  new `wattvn.keycodemon.org` HTTPRoute has no such constraint and can be
  added immediately, since it's a brand-new domain with nothing to migrate.
  The old `wattvn-api` namespace is deleted only as a final, separate,
  explicitly-confirmed step after a soak period — not bundled into the
  same change that cuts over traffic, so there's a rollback window.
- **Chart version bump and values restructure are bundled with the rename**,
  not split into a separate change first, since the current `0.2.3`
  flat-values `helm.yaml` can't deploy the frontend at all — there's no
  meaningful "just rename, deploy the old chart version" intermediate
  state worth stopping at.
- **Naming granularity**: only resources that represent "the release as a
  whole" become bare `wattvn` (`Namespace`, `Kustomization`,
  `HelmRepository`, `HelmRelease`/`releaseName`, `wattvn-api-secrets` →
  `wattvn-secrets`). Resources inherently scoped to one app or one image
  stay app-specific: the two `HTTPRoute`s (different hostnames), the two
  `ImageRepository`/`ImagePolicy` pairs (different container images), and
  the `ServiceMonitor` (stays `wattvn-api` — nginx doesn't expose
  Prometheus metrics, so there's nothing for a `wattvn-web` ServiceMonitor
  to scrape). One `ImageUpdateAutomation` resource covers both images'
  `{"$imagepolicy": ...}` markers, since Flux automation operates per git
  path, not per image.
- **`gitops/core/grafana/kustomization.yaml`'s `wattvn-api-grafana-dashboards`
  ConfigMap generator name is left unchanged** — purely cosmetic, no
  functional coupling to the app's own namespace/release naming, not worth
  the churn.
- **Executed directly, with explicit checkpoints — not delegated to a
  subagent workflow.** Given the live-production, real-user-data stakes,
  the controller (not a dispatched subagent) runs every cluster-mutating
  step directly, pausing for explicit human go-ahead before the HTTPRoute
  cutover and again before the final old-namespace deletion.

## File changes (`gitops/core/wattvn/`, renamed from `wattvn-api/`)

- `namespace.yaml` — `Namespace` name → `wattvn`.
- `kustomization.yaml` — same file list, `namespace: wattvn`.
- `helm.yaml` — `HelmRepository`/`HelmRelease` name → `wattvn`;
  `releaseName: wattvn`; `chart.spec.version: '0.3.0'`; `values:`
  restructured from flat `image.tag` to nested `api.image.tag` /
  `web.image.tag`, each with its own `{"$imagepolicy": "wattvn:wattvn-api:tag"}`
  / `{"$imagepolicy": "wattvn:wattvn-web:tag"}` marker comment.
- `secret.yaml` — `wattvn-api-secrets` → `wattvn-secrets` (same 3 keys,
  same vault refs, no data migration needed — ExternalSecrets re-fetch
  fresh). `ghcr-pull-secret` and `wattvn-tailscale-authkey` unchanged.
- `httproute.yaml` — existing API route moves to the new namespace,
  hostname unchanged; new `HTTPRoute` added for `wattvn.keycodemon.org` →
  the chart's `wattvn-web` Service.
- `image-policy.yaml` — existing `wattvn-api` `ImageRepository`/
  `ImagePolicy` moves to the new namespace; new `wattvn-web` pair added
  (image `ghcr.io/htthinh1999/wattvn-web`, same numerical-tag policy shape).
- `image-update-automation.yaml` — moves to the new namespace, `update.path`
  → `./gitops/core/wattvn`, updates both image markers via the existing
  Setters strategy.
- `servicemonitor.yaml` — moves to the new namespace, name/labels unchanged.
- `gitops/core/kustomization.yaml` — `wattvn-api/flux.yaml` →
  `wattvn/flux.yaml`.

## Migration runbook (imperative, run against the live cluster)

1. Apply the new `gitops/core/wattvn/` resources (Namespace, Secrets,
   HelmRepository/HelmRelease) via the GitOps flow, *excluding* the API's
   HTTPRoute for now (hostname conflict with the still-live old route). The
   new `wattvn-web` HTTPRoute has no such conflict and can go in immediately.
2. Scale the new API Deployment to 0 replicas as soon as its (empty)
   DataProtection PVC exists, before it does any real work with a
   throwaway key ring.
3. Spin up two temporary `busybox` debug pods — one in `wattvn-api` mounting
   the old PVC, one in `wattvn` mounting the new PVC — and pipe a `tar`
   stream between them via `kubectl exec`. Verify file listings match on
   both sides. Delete both debug pods.
4. Scale the new Deployment back to 1 replica. Verify: no "No XML
   encryptor configured" warning in its logs, and the one real EVN
   account's data still decrypts (e.g. a manual sync doesn't fail on
   decryption).
5. **Checkpoint — explicit go-ahead required.** Cut over the API's
   HTTPRoute: remove the old one, add the new one, same hostname, one
   atomic change.
6. Soak period — watch for sync failures/errors. Duration is the human's
   call.
7. **Checkpoint — explicit go-ahead required.** Delete the old
   `wattvn-api` namespace (cascades: old Deployment, Service, PVC, Secrets,
   HelmRelease, HelmRepository, image-automation resources).

**Rollback:** trivial before step 5 (don't apply the HTTPRoute swap).
Between steps 5–7, revert the HTTPRoute back to the old namespace's
Service — the old namespace and its resources are still fully intact.
After step 7, no rollback exists, but by then the migrated key ring was
already verified working in step 4, so step 7 itself adds no new risk
beyond "was the soak period long enough."

## Out of scope

- Renaming `gitops/core/grafana/kustomization.yaml`'s dashboard
  ConfigMap generator name.
- Adding a ServiceMonitor for the frontend (nginx exposes no metrics
  endpoint today).
- Any change to Postgres itself — it lives in a separate `wattvn-postgres`
  namespace, entirely unaffected by this migration.
- Automating the migration runbook as a reusable script — this is a
  one-time cutover, executed by hand with verification at each step.
