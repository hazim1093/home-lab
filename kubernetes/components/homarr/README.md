# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Config lives in its own SQLite database, not in YAML — board tiles
are added in the board editor, or through Homarr's own API (see *Board tiles* below).

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

## Board tiles

Tiles come from the `homarr.dev/*` annotations on the HTTPRoutes (`name`, `url`, `icon`,
`description`, `ping-url`, `category`) — they are the inventory of what belongs on the board, and the
matching lines to copy when adding a tile by hand.

Nothing consumes those annotations automatically. `homarr-controller` (the community
[adamancini controller](https://github.com/adamancini/homarr-kubernetes-dashboard-controller)) was
removed in favour of the v2 API: it drives Homarr's *internal* tRPC board API, which v2 changed, so
every reconcile had been failing with `400 invalid_union` since the upgrade — it could no longer write
tiles at all. Homarr's own Kubernetes integration is a read-only inventory view and, per its docs,
"Kubernetes resources are not converted into Homarr apps or integrations", and its Docker discovery
does not apply to a k3s cluster. So a new service in this lab is added to the board the same way as any
other edit:

- by hand in the board editor (drag/drop, resize, move into a container), or
- via the API, e.g. create the app and then place it on the board:

  ```bash
  curl -s -X POST -H "ApiKey: $HOMARR_API_KEY" -H 'Content-Type: application/json' \
    -d '{"name":"My App","iconUrl":"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/my-app.png",
         "href":"https://my-app.<LOCAL_DOMAIN>"}' \
    https://homarr.<LOCAL_DOMAIN>/api/apps
  ```

  (`GET /api/openapi` lists the full surface; placing the tile on a board is
  `POST /api/boards/items` with `{"boardId":<id>,"kind":"app","options":{"appId":<app id>}}`, which
  drops it on the canvas — drag it into a container afterwards, or edit the board JSON via
  `board.saveBoard`.)

If the annotation-driven sync is wanted again, the option is an in-repo CronJob as before #99 — the
[git history](https://github.com/hazim1093/home-lab/commit/e9bfc00) has that implementation
(ServiceAccount + ClusterRole listing `httproutes`, ConfigMap script, CronJob calling the REST API);
it needs the two v2 API calls above instead of the v1 ones.

## Files

- `helmrelease.yaml` — the dashboard itself (SQLite on a 1Gi PVC, read-only Kubernetes cluster view)
- `httproute.yaml` — exposed on `traefik-gateway`, with gatus health check and `homarr.dev/*` annotations

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

   Needed for API/automation access (`ApiKey:` header) and for Homarr's MCP endpoint at `/api/mcp`.

## Notes

- `rbac.enabled: true` turns on Homarr's read-only cluster view; the chart's ClusterRole also reads
  secrets cluster-wide (its design) — set it to `false` if you don't want that.
