# Paperless-ngx

Document management at `https://paperless.${LOCAL_DOMAIN}`. SQLite database, single replica.
Deployed via [bjw-s/app-template](https://github.com/bjw-s-labs/helm-charts) (`helmrelease.yaml`)
— the generic chart the home-operations/homelab community uses instead of a paperless-specific
chart (none is officially maintained). Two controllers in that one release: `paperless` (the app)
and `paperless-redis` (a dedicated Valkey broker, no persistence — nothing in it is worth backing
up). The HTTPRoute, NetworkPolicy and backup CronJob are plain manifests alongside the release,
not part of the chart values.

Backed by four `local-path` PVCs (single node, no redundancy — see **Backups** below for
the actual offsite copy):

| PVC | Created by | Contents |
|---|---|---|
| `paperless-data` | HelmRelease (`persistence.data`) | SQLite DB, search index, classifier model, Swedish tessdata |
| `paperless-media` | HelmRelease (`persistence.media`) | Documents (originals + generated archives + thumbnails) — the important one |
| `paperless-consume` | HelmRelease (`persistence.consume`) | Drop folder for new documents |
| `paperless-export` | `pvc.yaml` (standalone) | Scratch space for the nightly export (see below), not a backup by itself — used only by the backup CronJob, not mounted by the app |

## First-time setup

1. Fill in the R2 credentials (see **Backups**).
2. Log in at `https://paperless.${LOCAL_DOMAIN}` with the username/password from
   `secret.yaml` (`sops -d kubernetes/components/paperless/secret.yaml`).

## Adding documents

- Upload via the web UI, or
- Drop a file into the consume PVC:
  ```bash
  kubectl -n paperless cp ./scan.pdf $(kubectl -n paperless get pod -l app.kubernetes.io/controller=paperless -o jsonpath='{.items[0].metadata.name}'):/usr/src/paperless/consume/scan.pdf
  ```
  Paperless polls the consume folder every 60s (`PAPERLESS_CONSUMER_POLLING`) and removes
  the file once it's been consumed into `media`.

## Swedish OCR

`swe.traineddata` is fetched once by the `fetch-tessdata` init container onto the
`paperless-data` PVC (`tessdata/swe.traineddata`) and mounted over the bundled tessdata
directory as a single file. This avoids `PAPERLESS_OCR_LANGUAGES=swe`, which would
`apt-get install` the language pack on every pod start.

If Paperless is bumped to an image built on a different Debian base and the
`verify-tessdata-path` init container starts failing, the tessdata directory has moved.
Find the new path and update both the `verify-tessdata-path` check and the `subPath`
mount in `helmrelease.yaml` (`persistence.data.advancedMounts`):
```bash
kubectl -n paperless run tessdata-check --rm -it --restart=Never \
  --image=ghcr.io/paperless-ngx/paperless-ngx:<tag> -- find / -xdev -name eng.traineddata
```

## Backups

Nightly at 02:30 Europe/Stockholm, the `paperless-backup` CronJob:

1. Runs Paperless's own `document_exporter` into the `paperless-export` PVC — a portable
   dump (documents + thumbnails + a JSON manifest of the DB contents) that's restorable
   with `document_importer` on any Paperless version, independent of DB engine.
2. Runs `restic backup` on that export directory, pushing to a Cloudflare R2 bucket.
   Retention: 7 daily / 4 weekly / 12 monthly snapshots, pruned after each run. A
   `restic check --read-data-subset=5%` integrity check runs every Sunday.

A Grafana alert (`grafana-alert-paperless-backup.yaml`) fires to Slack if no backup has
succeeded in 36 hours.

### One-time setup (not in Git)

1. In Cloudflare: create an R2 bucket (e.g. `paperless-backup`) and an API token scoped
   to **that bucket only**, with Object Read & Write.
2. Fill in the placeholders:
   ```bash
   sops kubernetes/components/paperless/backup-secret.yaml
   ```
   - `RESTIC_REPOSITORY`: `s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>`
   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`: the R2 token's key pair
   - `RESTIC_PASSWORD` is already generated — **save it in your password manager**. Without
     it, the backups in R2 cannot be decrypted, even with the R2 credentials.
3. Commit and push (the file stays SOPS-encrypted).

### Trigger a backup manually

```bash
kubectl -n paperless create job --from=cronjob/paperless-backup paperless-backup-manual
kubectl -n paperless logs -f job/paperless-backup-manual -c restic
```

### List snapshots

```bash
kubectl -n paperless run restic-cli --rm -it --restart=Never \
  --image=restic/restic:0.19.1 \
  --overrides='{"spec":{"containers":[{"name":"restic-cli","image":"restic/restic:0.19.1","envFrom":[{"secretRef":{"name":"paperless-backup-secret"}}],"stdin":true,"tty":true,"command":["sh"]}]}}' \
  -- sh
# inside the pod:
restic snapshots
```

### Restore

Restoring rebuilds Paperless from a snapshot. Do a **test restore** after the first
successful backup — an untested backup is not a backup.

1. Scale Paperless down (SQLite must not be written to during restore). The chart names
   the Deployment after the release/controller, but use the label selector to be safe:
   ```bash
   kubectl -n paperless scale deploy -l app.kubernetes.io/controller=paperless --replicas=0
   ```
2. Restore the chosen snapshot into the export PVC with a one-off restic pod (mount
   `paperless-export` at `/export`, `paperless-backup-secret` via `envFrom`):
   ```bash
   restic restore <snapshot-id> --target / --include /export
   ```
3. Run `document_importer` against the restored export, targeting empty `data`/`media`
   PVCs (fresh PVCs on a full disaster-recovery rebuild; on a partial restore, clear them
   first):
   ```bash
   kubectl -n paperless run paperless-import --rm -it --restart=Never \
     --image=ghcr.io/paperless-ngx/paperless-ngx:3.2.1 \
     --overrides='<mount data, media, export PVCs; envFrom paperless-config + paperless-secrets>' \
     -- document_importer /usr/src/paperless/export --no-progress-bar
   ```
4. Scale Paperless back up:
   ```bash
   kubectl -n paperless scale deploy -l app.kubernetes.io/controller=paperless --replicas=1
   ```

### Full disaster recovery (new cluster)

1. Restore the SOPS age key (`.age/key.txt`) and re-bootstrap Flux — see the repo root
   `README.md`.
2. Flux recreates the namespace, empty PVCs, and all the Paperless resources.
3. Follow **Restore** above against the latest R2 snapshot.

## Notes

- `.sops.yaml` encrypts to both the primary and the `hermes-agent` age keys, so the
  Hermes agent can decrypt `secret.yaml` and `backup-secret.yaml` like every other secret
  in this repo.
- No Tika/Gotenberg: only PDFs and images are OCR'd, no Office docs or `.eml` files.
- The `helmrelease.yaml` values weren't dry-run rendered against the live `app-template`
  chart before merge (no `helm` in the environment this was written in). After Flux
  reconciles for the first time, sanity-check with `flux get helmrelease -n paperless` and
  `kubectl -n paperless get deploy,svc,pvc,pods` — in particular confirm both controllers
  came up (`paperless` and `paperless-redis`) and that the tessdata `subPath` mount landed
  correctly (`kubectl -n paperless exec deploy/... -- tesseract --list-langs` should list
  `eng` and `swe`).
