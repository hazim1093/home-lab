# CouchDB

Generic CouchDB instance. Currently used as the sync backend for Obsidian's
Self-hosted LiveSync plugin — notes are end-to-end encrypted by the client,
so this database stores ciphertext only.

- URL: `https://couchdb.<TAILNET>` (ClusterIP-only, tailnet is the only route in)
- Fauxton: `https://couchdb.<TAILNET>/_utils`
- Credentials: `sops --decrypt kubernetes/apps/couchdb/secret.yaml` — use `livesync`, not `admin`, in any client.
- Setup runbook: [`docs/obsidian-livesync-manual-steps.md`](../../../docs/obsidian-livesync-manual-steps.md)

The `obsidian` database is created automatically (`autoSetup.defaultDatabases`). The
`livesync` user and its `_security` grant on that database are **not** automated —
create them once, manually. Set these from `sops --decrypt kubernetes/apps/couchdb/secret.yaml`:

```bash
export COUCHDB_URL="https://couchdb.<TAILNET>"
export ADMIN_PW="<adminPassword from the secret>"
export LIVESYNC_PW="<livesyncPassword from the secret>"

curl -X PUT -u "admin:$ADMIN_PW" "$COUCHDB_URL/_users/org.couchdb.user:livesync" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"livesync\",\"password\":\"$LIVESYNC_PW\",\"roles\":[],\"type\":\"user\"}"

curl -X PUT -u "admin:$ADMIN_PW" "$COUCHDB_URL/obsidian/_security" \
  -H "Content-Type: application/json" \
  -d '{"admins":{"names":[],"roles":[]},"members":{"names":["livesync"],"roles":[]}}'
```

**Never change `couchdbConfig.couchdb.uuid`** — forces full re-replication on every client.

**No backup yet.** A synced desktop client is the only copy until the obsidian-vault-backup spec lands.
