# Obsidian MCP

[obsidian-sync-mcp](https://github.com/es617/obsidian-sync-mcp) — agent read/write access
to the vault via CouchDB directly, E2EE passphrase, no materialized plaintext copy.

Only `:latest` is published upstream — no pinned version tags exist.

## Set the secrets (one time)

```bash
sops kubernetes/apps/obsidian-mcp/secret.yaml
```

`COUCHDB_PASSWORD` (livesyncPassword from `kubernetes/apps/couchdb/secret.yaml`),
`COUCHDB_PASSPHRASE` (E2EE passphrase), `MCP_AUTH_TOKEN` (`openssl rand -hex 32`).

## URL

In-cluster only, no external exposure: `http://obsidian-mcp.obsidian-mcp.svc.cluster.local:8787`
(Hermes). Requires `Authorization: Bearer <MCP_AUTH_TOKEN>` on every request.
