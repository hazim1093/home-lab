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

Only hostnames listed in the `cloudflared-ingress` Secret reach Traefik; the base domain also serves other things outside this cluster, so there is no wildcard. The list is a SOPS secret (`ingress-secret.yaml`) so this public repo names no hosts. Public names are flat, `<app>-dev.${PUBLIC_BASE_DOMAIN}`: the zone's free Universal SSL certificate covers only one subdomain level.

1. Add a rule to `stringData."values.yaml"` in `ingress-secret.yaml` (`sops ingress-secret.yaml`), keeping the whole list:
   ```yaml
   cloudflare:
     ingress:
     - hostname: app-dev.<base domain>
       service: https://traefik.traefik.svc.cluster.local:443
       originRequest:
         noTLSVerify: true # Traefik's default certificate is not issued for the public hostname
   ```
   cloudflared rejects a hostname-less first rule and only honours a `*.` wildcard prefix. The chart appends the final 404 rule itself.
2. `hostnames: ["app-dev.${PUBLIC_BASE_DOMAIN}"]` on its `HTTPRoute`; Traefik matches `Host`.
3. `external-dns.kubernetes.io/hostname: "app-dev.${PUBLIC_BASE_DOMAIN}"` and `external-dns.kubernetes.io/target: "${CF_TUNNEL_TARGET}"` on its `Service`; `external-dns-dev` creates the proxied CNAME to the tunnel.

Interactive apps still want Cloudflare Access — the tunnel is a conduit, not auth.
