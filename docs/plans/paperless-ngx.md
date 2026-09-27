# Plan: Paperless-ngx with offsite backup

Status: **draft, pending approval**. Once approved, implement on branch `claude/paperless-backup-setup-lqk5gl`.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Deploy pattern | **Pattern A** (raw manifests in `kubernetes/apps/paperless/`) | No maintained official Helm chart. Pattern A gets SOPS decryption and `${LOCAL_DOMAIN}` substitution from the `apps` Flux Kustomization, the same way `hermes` does. |
| Database | **SQLite** | One user, low concurrency. Saves running a Postgres pod and a second thing to back up. The backup uses Paperless's own exporter, which doesn't depend on the database engine, so moving to Postgres later is just an export and import. |
| Broker | **Valkey** (Redis-compatible), no persistence | Paperless requires it for Celery. It only holds the task queue, so there's nothing to back up. |
| Office/email parsing | **None** (no Tika or Gotenberg) | PDFs and images only. Can be added later. |
| OCR | `eng+swe` | Swedish isn't bundled in the image. `PAPERLESS_OCR_LANGUAGES=swe` installs it when the container starts, so startup needs network access. |
| Timezone | `Europe/Stockholm` | Matches homarr, hajimari and hallon. |
| Hostname | `paperless.${LOCAL_DOMAIN}` via the `websecure` listener | external-dns creates the PiHole record from the HTTPRoute. |
| Storage | `local-path` PVCs | Cluster default. The PVs are pinned to a node, so the backup Job lands on the same node as the app. |
| Backup method | Nightly `document_exporter` into an export PVC, then **restic** to a **Cloudflare R2** bucket | The exporter gives a consistent, version-portable dump (documents, thumbnails, metadata and DB contents as a manifest) that `document_importer` can restore. restic adds encryption, dedup and retention. R2 is already used for Terraform state. |
| Backup monitoring | Grafana alert on stale or failed backups (kube-state-metrics metrics) | Uses the existing Grafana Cloud setup and its Slack contact point. |

## Files to create

### `kubernetes/apps/paperless/`

```
kustomization.yaml
namespace.yaml
pvc.yaml                  # paperless-data 2Gi, paperless-media 30Gi, paperless-consume 2Gi, paperless-export 30Gi
configmap.yaml            # shared non-secret env (paperless-config)
secret.yaml               # SOPS: PAPERLESS_SECRET_KEY, PAPERLESS_ADMIN_USER, PAPERLESS_ADMIN_PASSWORD
redis.yaml                # Deployment + Service "paperless-redis" (valkey, pinned tag, no PVC)
deployment.yaml           # paperless webserver
service.yaml              # "paperless" :8000
httproute.yaml            # paperless.${LOCAL_DOMAIN}, websecure, gatus + homarr annotations
networkpolicy.yaml        # ingress limited to: same ns, traefik, gatus, homarr
backup-secret.yaml        # SOPS: RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
backup-cronjob.yaml       # nightly export + restic
README.md                 # operations and restore runbook
```

Then add `- paperless` to `kubernetes/apps/kustomization.yaml`.

### Details

**configmap.yaml** (`paperless-config`), used by both the Deployment and the CronJob:
- `PAPERLESS_REDIS=redis://paperless-redis.paperless.svc.cluster.local:6379`
- `PAPERLESS_URL=https://paperless.${LOCAL_DOMAIN}` (needed for CSRF behind Traefik)
- `PAPERLESS_TIME_ZONE=Europe/Stockholm`
- `PAPERLESS_OCR_LANGUAGE=eng+swe`
- `PAPERLESS_DATA_DIR`, `PAPERLESS_MEDIA_ROOT`, `PAPERLESS_CONSUMPTION_DIR`: leave at the image defaults (`/usr/src/paperless/{data,media,consume}`).
- `PAPERLESS_CONSUMER_POLLING=60`, because inotify doesn't work reliably on every volume type. Harmless on local-path.

**deployment.yaml**
- Image `ghcr.io/paperless-ngx/paperless-ngx:<latest 2.x release, pinned>`. Look up the current release; don't use `latest`.
- `replicas: 1` and `strategy: Recreate` (SQLite and RWO volumes).
- `annotations: reloader.stakater.com/auto: "true"`, following hermes.
- `envFrom`: `paperless-config` ConfigMap and `paperless-secrets` Secret. Also set `PAPERLESS_OCR_LANGUAGES=swe` here only, not in the CronJob.
- Mounts: data, media, consume, and export at `/usr/src/paperless/export`.
- Port 8000. Readiness and liveness via `httpGet /` on 8000, with `initialDelaySeconds` of about 60, because the first start runs migrations and the apt install.
- Resources: requests `cpu: 100m, memory: 512Mi`; limit `memory: 2Gi`. OCR is memory-hungry.
- `enableServiceLinks: false`. Otherwise the `PAPERLESS_*` env vars Kubernetes injects for a Service named `paperless` collide with Paperless's own config variables. Same issue hermes hit.

**httproute.yaml**: copy hermes's structure:
- gatus: `url: http://paperless.paperless.svc.cluster.local:8000`, `[STATUS] == 200`
- homarr: `enabled`, `category: "Homelab Apps"`, `name: "Paperless"`, `url: https://paperless.${LOCAL_DOMAIN}`, `icon: "paperless-ngx"`, `ping-url` pointing at the in-cluster service.

**backup-cronjob.yaml** (`paperless-backup`)
- `schedule: "30 2 * * *"`, `timeZone: Europe/Stockholm`, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`, `backoffLimit: 1`, `restartPolicy: Never`.
- **initContainer `export`**: same Paperless image, same `envFrom`. It mounts data, media and export (consume isn't needed) and runs `document_exporter /usr/src/paperless/export --delete --no-progress-bar`. `--delete` removes files from the export dir that no longer exist in Paperless. Unchanged files aren't rewritten, so restic sees a small diff each night.
  - Check that the image entrypoint runs a passed command. Upstream documents `docker compose run --rm webserver document_exporter ../export`, so passing `args` should work. If it doesn't, fall back to `command: ["python3", "manage.py", "document_exporter", ...]` with `workingDir: /usr/src/paperless/src`.
- **container `restic`**: `restic/restic:<pinned>` with `envFrom: paperless-backup-secret` and a restic cache on an `emptyDir` (`RESTIC_CACHE_DIR`). Script, `set -eu`:
  ```sh
  restic cat config >/dev/null 2>&1 || restic init
  restic backup /export --host paperless --tag paperless
  restic forget --host paperless --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
  # weekly integrity check (Sunday)
  [ "$(date +%u)" = 7 ] && restic check --read-data-subset=5% || true
  ```
  The export PVC is mounted read-only here.
- `RESTIC_REPOSITORY` format: `s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>`. It goes in the encrypted secret because the account ID shouldn't sit in a public repo in plaintext.

**Secrets (public repo: must be SOPS-encrypted before commit)**
- Install `sops`. Encrypting only needs the public age recipients from `.sops.yaml`, not the private key.
- Generate `PAPERLESS_SECRET_KEY`, `PAPERLESS_ADMIN_PASSWORD` and `RESTIC_PASSWORD` locally with `openssl rand`. Write them straight into the file and encrypt in place. **Never print them** to stdout, logs or commit messages.
- `PAPERLESS_ADMIN_USER`: `admin`.
- R2 values (`RESTIC_REPOSITORY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`): use `REPLACE_WITH_...` placeholders, then encrypt. The user fills them in after merge with `sops kubernetes/apps/paperless/backup-secret.yaml`.
- Note: `.sops.yaml` also encrypts to the `hermes-agent` recipient, so the Hermes agent will be able to decrypt these secrets. Flag this to the user rather than changing `.sops.yaml`.

### Monitoring: `kubernetes/components/grafana-resources/grafana-alert-paperless-backup.yaml`

A `GrafanaAlertRuleGroup` shaped like `grafana-alert-hermes-openrouter-limit.yaml` (receiver `slack`, folder `alerts`), containing one rule:
- `time() - max(kube_cronjob_status_last_successful_time{namespace="paperless", cronjob="paperless-backup"}) > 36*3600`, which means no successful backup in 36h. `noDataState: Alerting`, so an alert fires if a backup has never succeeded.
- Find the Prometheus datasource UID first (probably `grafanacloud-prom`; check the Grafana instance and datasources). Also confirm that kube-state-metrics/alloy ship `kube_cronjob_*` metrics. If they don't, say so and skip the alert rather than guess.
- Add the file to `grafana-resources/kustomization.yaml`.

### Renovate

The `kubernetes` manager currently only matches `kubernetes/components/**`. Add `"/^kubernetes\\/apps\\/paperless\\/.+\\.yaml$/"` to `kubernetes.managerFilePatterns` so the Paperless, Valkey and restic image tags get update PRs. Scope it to `paperless/` only, so hermes's kustomize `newTag` SHA stays untouched.

## Manual steps for the user (not automatable from the repo)

1. Cloudflare: create an R2 bucket (for example `paperless-backup`) and an R2 API token with **Object Read & Write** scoped to that bucket only.
2. `sops kubernetes/apps/paperless/backup-secret.yaml`: replace the three `REPLACE_WITH_...` values.
3. Copy the `RESTIC_PASSWORD` into a password manager (`sops -d ...`). Without it the backups can't be decrypted. It's also in git encrypted with the age key, but that means recovery depends on the age key backup.
4. After the first nightly run, or a manual one (`kubectl -n paperless create job --from=cronjob/paperless-backup backup-manual`), do a **test restore** as described in the README.

## README.md (runbook) contents

- Where the data lives (PVCs), and how the consume folder works (upload via the web UI, or `kubectl cp` into the consume PVC).
- Trigger a manual backup; list snapshots (`kubectl run` a restic pod with the backup secret, then `restic snapshots`).
- **Restore**:
  1. `kubectl -n paperless scale deploy/paperless --replicas=0`
  2. Run a one-off restic pod that restores the chosen snapshot into the export PVC (`restic restore <id> --target / --include /export`).
  3. Run a one-off Paperless pod with data/media/export mounted that runs `document_importer /usr/src/paperless/export`. It must run against empty data/media, so on a full rebuild the PVCs are fresh anyway.
  4. Scale back to 1.
- Disaster recovery from scratch: age key, then Flux, then the PVCs are recreated empty, then run the restore above.

## Verification before pushing

- `kubectl kustomize kubernetes/apps` builds cleanly (install `kubectl` or `kustomize` if needed).
- `grep -rL 'ENC\[' kubernetes/apps/paperless/*secret*.yaml` returns nothing, meaning every secret file is encrypted.
- Run gitleaks, or at least grep the diff for the real domain, IPs or keys. There must be no plaintext secrets and no real domain.
- `git diff` read through once for `${LOCAL_DOMAIN}` usage and pinned image tags.

## Out of scope (possible follow-ups)

- Tika + Gotenberg for Office and email files
- Email/IMAP ingestion, and an SMB share for a scanner drop folder
- Cluster-wide PVC backup (VolSync) for Home Assistant, Hermes and others
- Moving to Postgres
