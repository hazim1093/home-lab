# Paperless-ngx

`https://paperless.${LOCAL_DOMAIN}` — scales 0↔1 on demand via KEDA HTTP
(`httpscaledobject.yaml`); first request after idle is slow.

## First-time setup

1. Create an R2 bucket + a scoped API token, then fill in the placeholders:
   ```bash
   sops kubernetes/apps/paperless/backup-secret.yaml
   ```
   `RESTIC_REPOSITORY`: `s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>`
2. Log in with the credentials in `secret.yaml` (`sops -d kubernetes/apps/paperless/secret.yaml`).

## Backups

Nightly, `paperless-backup` exports Paperless and pushes it to R2 via restic
(7 daily / 4 weekly / 12 monthly snapshots). A Grafana alert fires if none
succeeds in 36h.

Manual run:
```bash
kubectl -n paperless create job --from=cronjob/paperless-backup paperless-backup-manual
```

List snapshots:
```bash
kubectl -n paperless run restic-cli --rm -it --restart=Never \
  --image=restic/restic:0.19.1 \
  --overrides='{"spec":{"containers":[{"name":"restic-cli","image":"restic/restic:0.19.1","envFrom":[{"secretRef":{"name":"paperless-backup-secret"}}],"stdin":true,"tty":true,"command":["sh"]}]}}' \
  -- sh -c 'restic snapshots'
```

## Restore

1. Pin it down (KEDA owns `replicas` directly): `kubectl -n paperless patch httpscaledobject paperless --type merge -p '{"spec":{"replicas":{"min":0,"max":0}}}'`
2. Restic-restore the chosen snapshot into the `paperless-export` PVC.
3. Run `document_importer /usr/src/paperless/export` in a one-off pod with
   `data`/`media`/`export` mounted and `paperless-config`/`paperless-secrets` as env.
4. Restore normal scaling: `kubectl -n paperless patch httpscaledobject paperless --type merge -p '{"spec":{"replicas":{"min":0,"max":1}}}'`

Test this after the first successful backup — an untested backup isn't one.
