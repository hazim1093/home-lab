# HA-MCP

Community [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) MCP server (HTTP transport, port 8086) for controlling Home Assistant. Reachable in-cluster (Hermes) and on the local domain (Claude Code / other MCP clients on your PC).

## Before it works: set the secrets (one time)

The secret is a SOPS-encrypted placeholder. Set the real values:

```bash
sops kubernetes/components/ha-mcp/secret.yaml
```

1. `HOMEASSISTANT_TOKEN` — long-lived token from HA: your user (bottom left) → Security → Long-lived access tokens → Create token
2. `MCP_SECRET_PATH` — high-entropy path, e.g. `/private_$(openssl rand -hex 16)`. This is the only auth (URL-path secrecy) — keep it secret.

Save, commit the re-encrypted file, merge. The pod won't talk to HA until the token is real.

## URLs

| Client | URL |
|---|---|
| Hermes (in-cluster) | `http://ha-mcp.ha-mcp.svc.cluster.local:8086<MCP_SECRET_PATH>` |
| Your PC (local domain) | `http://mcp.<LOCAL_DOMAIN><MCP_SECRET_PATH>` |

## Client setup

Claude Code (on your PC):

```bash
claude mcp add --transport http ha-mcp "http://mcp.<LOCAL_DOMAIN>/private_<random>"
```

Hermes:

```bash
hermes config set mcp_servers.ha_mcp.url "http://ha-mcp.ha-mcp.svc.cluster.local:8086/private_<random>"
# restart hermes - tools appear as mcp_ha_mcp_*
```
