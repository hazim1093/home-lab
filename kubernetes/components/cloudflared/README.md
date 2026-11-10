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

Ingress is one wildcard rule (`*.${PUBLIC_BASE_DOMAIN}`) to Traefik, so this component doesn't change per service — give the app a public hostname instead. Public names are flat, `<app>-hq.${PUBLIC_BASE_DOMAIN}`: the zone's free Universal SSL certificate covers only one subdomain level.

1. `hostnames: ["app-hq.${PUBLIC_BASE_DOMAIN}"]` on its `HTTPRoute`; Traefik matches `Host`.
2. `external-dns.alpha.kubernetes.io/hostname: "app-hq.${PUBLIC_BASE_DOMAIN}"` and `external-dns.alpha.kubernetes.io/target: "${CF_TUNNEL_TARGET}"` on its `Service`; `external-dns-hq` creates the proxied CNAME to the tunnel.

Interactive apps still want Cloudflare Access — the tunnel is a conduit, not auth.
