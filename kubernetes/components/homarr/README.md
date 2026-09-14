# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — the app
inventory is synced from HTTPRoutes by [homarr-controller](../homarr-controller/) instead.

## Homarr v2 beta (current image)

The HelmRelease runs the v2 beta preview, which upstream publishes as
`ghcr.io/homarr-labs/homarr-test:v2` — the `ghcr.io/homarr-labs/homarr:v2.0.0` in the
[upgrade docs](https://v2.preview.homarr.dev/docs/getting-started/upgrade-v2) isn't on the registry
yet. v2 migrates the existing SQLite database in place on first start, so the PVC, `database.type`
and `db-encryption-key` stay as they were. Build validated on this cluster:
`sha256:5f9d0344b6383870fea84212db5f1840aa3bd19f3c2e3e76b9d1b4c9fd3a01da` (linux/amd64).

**Backup before the first v2 start.** Homarr's own *Management → Tools → Backup* ZIP; the v1 export
taken before this upgrade is at `/opt/data/backups/homarr-v1-backup-20260914.zip` on the Hermes host
(it contains `db.sqlite` and the `SECRET_ENCRYPTION_KEY` needed to decrypt its integration secrets).

**Rollback:** v1 cannot read a database v2 has migrated — revert the image *and* restore the backup.
Restoring into v2 (v2 applies the backup's migrations itself) is the cleaner path.

Caveats while on the beta:

- `homarr-controller` drives Homarr's internal tRPC API and v2 replaces categories/sections with
  Containers, so the HTTPRoute sync likely stops working. Harmless if it does: existing tiles are
  then maintained in the board editor, and new routes have to be added by hand.
- `WORKSHOP_API_URL` (hosted custom-widget Workshop) is commented out in `helmrelease.yaml`;
  enabling it makes the pod call `v2.preview.homarr.dev`.
- `tag: "v2"` is a floating beta tag with `pullPolicy: IfNotPresent`, so a node that already has the
  image won't re-pull it — delete the pod to pick up a newer beta build.

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
