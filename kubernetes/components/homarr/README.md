# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — the app
inventory is synced from HTTPRoutes by [homarr-controller](../homarr-controller/) instead.

## Files

- `helmrelease.yaml` — the dashboard itself (SQLite on a 1Gi PVC, read-only Kubernetes cluster view)
- `httproute.yaml` — exposed on `traefik-gateway`, with gatus health check and `homarr.dev/*` annotations

The first user and the sync's API key are one-time manual steps (below) — Homarr offers no env var or
API for either, so neither can be applied from Git.

## First-time setup

1. **Login** — open `https://homarr.<LOCAL_DOMAIN>` and create the admin user on the welcome screen,
   using `admin-username` / `admin-password` from `secret.yaml`. Seeding it from a one-shot Job does
   not work: the bundled recovery CLI hangs in a fresh container, because the image's logger opens a
   Redis connection unless `DISABLE_REDIS_LOGS=true`, and Redis is only started by the app container's
   own entrypoint.
2. **API key for the sync** — Homarr has no way to create one from code: UI → *Manage → Tools → API →
   create*, then

   ```bash
   printf '"%s"' '<id>.<token>' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["api-key"]'
   ```

Until the API key is set, `homarr-controller` logs failed API calls and adds nothing.

## Notes

- `rbac.enabled: true` turns on Homarr's read-only cluster view; the chart's ClusterRole also reads
  secrets cluster-wide (its design) — set it to `false` if you don't want that.
