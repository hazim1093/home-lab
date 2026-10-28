# Obsidian vault backup

Encrypted, versioned backup of the Obsidian vault to R2. `livesync-cli` (official headless
CLI) materializes CouchDB into plaintext markdown; `restic` backs that up.

## CronJobs

| Job | Schedule | Does |
|---|---|---|
| `obsidian-vault-materialize` | hourly | decrypt CouchDB → plaintext on `obsidian-vault-data` |
| `obsidian-vault-backup` | daily 03:00 | `restic backup` to R2 |
| `obsidian-vault-backup-retention` | weekly | `restic forget --prune` |
| `obsidian-vault-backup-verify` | weekly | `restic check` |

## Set the secrets (one time)

```bash
sops kubernetes/apps/obsidian-vault-backup/livesync-settings-secret.yaml   # livesync password + E2EE passphrase
sops kubernetes/apps/obsidian-vault-backup/secret.yaml                      # restic password + R2 creds
```

## One-time manual steps

```bash
# restic init must be run manually — never automate init, it can silently
# recreate an empty repo if the real one becomes unreachable.
kubectl run restic-init --rm -it --restart=Never -n obsidian \
  --image=restic/restic:0.17.3 --overrides='{"spec":{"containers":[{"name":"restic-init","image":"restic/restic:0.17.3","args":["init"],"envFrom":[{"secretRef":{"name":"obsidian-vault-backup-restic"}}],"stdin":true,"tty":true}]}}'
```

Run a restore drill (`restic snapshots` / `restic restore`) once set up — an untested
backup is a hypothesis.

## Risk

`obsidian-vault-data` is `ReadWriteOnce`, shared by the materializer and restic jobs —
works only on a single-node cluster.
