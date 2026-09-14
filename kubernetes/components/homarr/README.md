# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — the tile
inventory comes from annotations on the HTTPRoutes and is reconciled by an in-repo CronJob (below).

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

- `WORKSHOP_API_URL` (hosted custom-widget Workshop) is commented out in `helmrelease.yaml`;
  enabling it makes the pod call `v2.preview.homarr.dev`.
- `tag: "v2"` is a floating beta tag with `pullPolicy: IfNotPresent`, so a node that already has the
  image won't re-pull it — delete the pod to pick up a newer beta build.
- Widgets and containers live in the *Base* layout only unless they are also placed in the Mobile
  layout (board settings → Layout).

## Annotations (the tile inventory)

| Annotation | Notes |
|---|---|
| `homarr.dev/enabled` | `"true"` to manage the route |
| `homarr.dev/name` | app + tile name (required) |
| `homarr.dev/url` | link target, `https://<host>.${LOCAL_DOMAIN}` (required) |
| `homarr.dev/icon` | dashboard-icons slug (`gatus`, `pi-hole`, …) or a full image URL |
| `homarr.dev/description` | app description (optional) |
| `homarr.dev/ping-url` | in-cluster URL for the tile's status dot (copied from the gatus endpoint) |
| `homarr.dev/category` | container that files the tile: `Homelab Components` or `Homelab Apps` |

Routes without `homarr.dev/enabled: "true"` are ignored — `hermes-gateway`, `ha-mcp` and
`screener-api` are deliberately not on the board.

## Tile sync (`homarr-httproute-sync`)

`sync-cronjob.yaml` runs `sync.py` (from `sync-configmap.yaml`) every 10 minutes. It lists HTTPRoutes
cluster-wide using its own ServiceAccount and the `httproutes` read granted in `sync-rbac.yaml`, then
reconciles Homarr with the API key from `homarr-secrets`:

- creates a missing app (`POST /api/apps`) and a tile for it, filed in the container named by
  `homarr.dev/category`
- updates an app when name, icon, url, description or ping-url drift from the annotations
  (`PATCH /api/apps/{id}`)
- moves a managed tile whose category names a different container (`ENFORCE_CATEGORY=true`, default)
- placement uses the same `board.getBoardByName` / `board.saveBoard` calls as the board editor, and
  only items it created itself (`managed-<appId>`) — manual tiles, widgets and rail items are untouched,
  and a tile's position *inside* its container is never changed
- never deletes: a managed tile whose route lost its annotations is only logged (`PRUNE=false`, default)

Run it by hand with `kubectl create job --from=cronjob/homarr-httproute-sync homarr-sync-now -n homarr`
(delete the finished Job afterwards); `DRY_RUN=true` logs the plan without writing anything.

This replaced the community `homarr-controller` (removed in #112). That controller drove Homarr's
*internal* tRPC board API, which the v2 upgrade changed, so every reconcile had been failing with
`400 invalid_union` and writing nothing. Homarr's own Kubernetes integration is a read-only inventory
view — its docs state "Kubernetes resources are not converted into Homarr apps or integrations" — and
its Docker discovery does not apply to a k3s cluster.

Tiles without an HTTPRoute (external services, or the Homarr docs links) are added by hand in the board
editor.

## Files

- `helmrelease.yaml` — the dashboard itself (SQLite on a 1Gi PVC, read-only Kubernetes cluster view)
- `httproute.yaml` — exposed on `traefik-gateway`, with gatus health check and the `homarr.dev/*` annotations
- `sync-rbac.yaml` / `sync-configmap.yaml` / `sync-cronjob.yaml` — the tile sync (see above)

The first user and the API key are one-time manual steps (below) — Homarr offers no env var or API for
either, so neither can be applied from Git.

## First-time setup

1. **Login** — open `https://homarr.<LOCAL_DOMAIN>` and create the admin user on the welcome screen,
   using `admin-username` / `admin-password` from `secret.yaml`. Seeding it from a one-shot Job does
   not work: the bundled recovery CLI hangs in a fresh container, because the image's logger opens a
   Redis connection unless `DISABLE_REDIS_LOGS=true`, and Redis is only started by the app container's
   own entrypoint.
2. **API key** — Homarr has no way to create one from code: UI → *Manage → Tools → API → create*, then

   ```bash
   printf '"%s"' '<id>.<token>' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["api-key"]'
   ```

   Needed by the tile sync, by any `ApiKey:` API call, and by Homarr's MCP endpoint at `/api/mcp`.

## Notes

- `rbac.enabled: true` turns on Homarr's read-only cluster view; the chart's ClusterRole also reads
  secrets cluster-wide (its design) — set it to `false` if you don't want that.
