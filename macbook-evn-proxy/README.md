# MacBook EVN CPC proxy (backup egress path)

Not a k8s manifest — this machine isn't a cluster node, so it isn't reconciled
by Flux or applied by Terraform. Kept here purely for version history and
reproducibility, same as `nuc/`.

Backup egress path for `wattvn-api`'s EVN CPC calls (see
`docs/superpowers/specs/2026-07-31-evn-proxy-failover-design.md` in the
`wattvn` repo) for when the home NUC's proxy (`nuc/evn-proxy/`) is
unreachable. Identical behavior to that proxy - forwards to EVN CPC's real
API with the right Host/SNI headers - just run directly via Docker instead
of as a k8s Deployment, since this machine isn't a cluster node.

## Running it

From this directory, on the MacBook (Tailscale IP `100.101.201.71`):

```bash
docker run -d \
  --name macbook-evn-proxy \
  --restart unless-stopped \
  -p 8080:80 \
  -v "$(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:alpine
```

`--restart unless-stopped` keeps it running across a Docker Desktop restart
or a reboot, for as long as Docker Desktop itself is set to start on login -
this needs to be running continuously (not started ad hoc during an outage)
for `wattvn-api`'s automatic failover to have anything to fail over to.

**`--restart unless-stopped` does not survive macOS sleep** - a sleeping
container host still isn't reachable over Tailscale, restart policy or not.
Prevent the Mac from sleeping while it's acting as the backup: under System
Settings > Energy Saver (or Battery), disable sleep while plugged in, or run
`caffeinate -s` in a background terminal for the duration. A closed lid or a
sleeping Mac means the backup is not actually available, regardless of what
the restart policy says - this is the single biggest way this "automatic"
failover silently stops being automatic.

Also spot-check the tailnet's Tailscale ACLs for peer-to-peer reachability
between this MacBook and the cluster's Tailscale nodes when first setting
this up - the tailnet is expected to have no restrictive ACLs today, but that
hasn't been explicitly verified for this specific MacBook-to-cluster path.

## Wiring it into the cluster

Once this is running and reachable from the OKE cluster over Tailscale, set
the Helm value as an override in **this repo's**
[`gitops/core/wattvn/helm.yaml`](../gitops/core/wattvn/helm.yaml), in the
`HelmRelease`'s `values:` block - not in the `wattvn` repo's
`chart/values.yaml` directly (that's the chart's own default, and changing it
would additionally require bumping the chart version and republishing it,
which isn't the right path for a per-deployment operator setting like this).
Add `evnBackupBaseUrl` alongside the existing `corsAllowedOrigin` override:

```yaml
    api:
      env:
        corsAllowedOrigin: "http://localhost:5173,https://wattvn.keycodemon.org"
        evnBackupBaseUrl: "http://100.101.201.71:8080"
```

## Verifying reachability

From a pod in the `wattvn` namespace, exec into the `tailscale` sidecar (not
the main `wattvn-api` container - its image,
`mcr.microsoft.com/dotnet/runtime-deps:8.0-jammy-chiseled`, has no shell and
no `curl`, so execing into it fails with an opaque runtime error; the
`tailscale` container shares the same pod network namespace and does have a
shell):

```bash
kubectl exec -it deploy/wattvn -c tailscale -- curl -sS http://100.101.201.71:8080/api/cskh/user/login -o /dev/null -w '%{http_code}\n'
```

(The deployment is named `wattvn`, not `wattvn-api` - the release name, not
the project folder name. Double-check both the deployment and container
names against `chart/templates/api-deployment.yaml` in the `wattvn` repo if
this ever changes.)

A `4xx`/`5xx` from EVN CPC's actual API (not a connection error) confirms the
proxy is up and correctly forwarding - this is verifying reachability, not a
real login attempt.
