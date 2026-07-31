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

## Wiring it into the cluster

Once this is running and reachable from the OKE cluster over Tailscale, set
the Helm value in the `wattvn` repo's `chart/values.yaml`:

```yaml
api:
  env:
    evnBackupBaseUrl: "http://100.101.201.71:8080"
```

## Verifying reachability

From a pod in the `wattvn` namespace (or via `kubectl exec` into the
`wattvn-api` container, which shares its network namespace with the
`tailscale` sidecar):

```bash
curl -sS http://100.101.201.71:8080/api/cskh/user/login -o /dev/null -w '%{http_code}\n'
```

A `4xx`/`5xx` from EVN CPC's actual API (not a connection error) confirms the
proxy is up and correctly forwarding - this is verifying reachability, not a
real login attempt.
