# cloudflared

Cloudflare Tunnel connector (`cloudflare-tunnel` chart, locally-managed). Outbound-only: no inbound port. Exposes nothing until routes are added — with none, every request 404s.

## Setup

```bash
cloudflared tunnel login
cloudflared tunnel create home-lab
```

Fill `secret.yaml` from `~/.cloudflared/<UUID>.json`, set `tunnelName` in `helmrelease.yaml`, then:

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
sops --encrypt --in-place kubernetes/components/cloudflared/secret.yaml
```

Use `secretName`, never `values.cloudflare.secret` — the latter renders credentials into the HelmRelease values (plaintext, public repo).

## Expose a service

Add to `values.cloudflare.ingress` in `helmrelease.yaml`:

```yaml
- hostname: pr-agent.${BASE_DOMAIN}
  service: http://pr-agent.pr-agent.svc.cluster.local:3000
```

Then: the matching egress rule in `networkpolicy.yaml`; `cloudflared tunnel route dns home-lab <host>`; and a NetworkPolicy locking the app's ingress to the `cloudflared` namespace. Put interactive apps behind Cloudflare Access — the tunnel is a conduit, not auth.
