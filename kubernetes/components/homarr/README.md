# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — the app
inventory is synced from HTTPRoutes by [homarr-controller](../homarr-controller/) instead.

## Files

- `helmrelease.yaml` — the dashboard itself (SQLite on a 1Gi PVC, read-only Kubernetes cluster view)
- `admin-bootstrap-job.yaml` — one-shot Job that creates the login from the SOPS secret (see below)
- `httproute.yaml` — exposed on `traefik-gateway`, with gatus health check and `homarr.dev/*` annotations

## First-time setup (two one-time steps)

1. **Login** — put your chosen credentials in the secret and apply them:

   ```bash
   printf '"%s"' 'youruser' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["admin-username"]'
   printf '"%s"' 'yourpassword' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["admin-password"]'
   kubectl delete job -n homarr homarr-admin-bootstrap   # so it runs again with the new secret
   flux reconcile kustomization homarr -n flux-system --with-source   # or wait for the 10m interval
   ```

   The Job is one-shot by design (no TTL, so Flux cannot re-run it in a loop and log you out), which is
   why deleting it is how changed credentials get applied — same for a later rotation. While the password
   is still the `CHANGEME` placeholder the Job logs a hint and exits 0, so merging this as-is is safe:
   no UI onboarding is needed once a user exists.

2. **API key for the sync** — Homarr has no way to create one from code: UI → *Manage → Tools → API →
   create*, then

   ```bash
   printf '"%s"' '<id>.<token>' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["api-key"]'
   ```

Until the API key is set, `homarr-controller` logs failed API calls and adds nothing.

## Notes

- `rbac.enabled: true` turns on Homarr's read-only cluster view; the chart's ClusterRole also reads
  secrets cluster-wide (its design) — set it to `false` if you don't want that.
- The bootstrap Job uses Homarr's own CLI (`homarr recreate-admin` / `homarr update-password`), which
  upstream describes as a recovery tool: it should not run while the app is serving heavy traffic. The
  Job waits for the database, applies credentials once and stays `Completed` (no TTL, so Flux does not
  re-run it in a loop).
