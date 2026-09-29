# CouchDB

Generic CouchDB instance. Currently used as the sync backend for Obsidian's
Self-hosted LiveSync plugin — notes are end-to-end encrypted by the client,
so this database stores ciphertext only.

- URL: `https://couchdb.<TAILNET>` (ClusterIP-only, tailnet is the only route in)
- Fauxton: `https://couchdb.<TAILNET>/_utils`
- Credentials: `sops --decrypt kubernetes/apps/couchdb/secret.yaml` — use `livesync`, not `admin`, in any client.
- Setup runbook: [`docs/obsidian-livesync-manual-steps.md`](../../../docs/obsidian-livesync-manual-steps.md)

**Never change `couchdbConfig.couchdb.uuid`** — forces full re-replication on every client.

**No backup yet.** A synced desktop client is the only copy until the obsidian-vault-backup spec lands.
