# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — the app
inventory is synced from HTTPRoutes by [homarr-controller](../homarr-controller/) instead.

## Files

- `helmrelease.yaml` — the dashboard itself (SQLite on a 1Gi PVC, read-only Kubernetes cluster view)
- `httproute.yaml` — exposed on `traefik-gateway`, with gatus health check and `homarr.dev/*` annotations

The login is applied from the SOPS secret by [homarr-bootstrap](../homarr-bootstrap/) (a separate
component, so a failed bootstrap cannot gate the dashboard).

## First-time setup

1. **Login** — set `admin-username` / `admin-password` in `secret.yaml` and re-run the bootstrap Job;
   the exact commands are in [homarr-bootstrap/README.md](../homarr-bootstrap/README.md).
2. **API key for the sync** — Homarr has no way to create one from code: UI → *Manage → Tools → API →
   create*, then

   ```bash
   printf '"%s"' '<id>.<token>' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["api-key"]'
   ```

Until the API key is set, `homarr-controller` logs failed API calls and adds nothing.

## Notes

- `rbac.enabled: true` turns on Homarr's read-only cluster view; the chart's ClusterRole also reads
  secrets cluster-wide (its design) — set it to `false` if you don't want that.
