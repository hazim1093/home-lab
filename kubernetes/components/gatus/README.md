# Gatus - Health Dashboard & Monitoring

Self-hosted monitoring with **automatic HTTPRoute discovery** via gatus-sidecar.

## Features

- ✨ **Auto-Discovery**: HTTPRoutes with `gatus.home-operations.com/enabled: "true"` are monitored automatically
- 🔍 **DNS Monitoring**: Static checks for Pi-hole and Unbound
- 🔔 **Slack Alerts**: Failures and recoveries (3 failures = alert, 2 successes = resolved)
- 💾 **Persistent Storage**: 200Mi SQLite database

## How It Works

**gatus-sidecar** watches for HTTPRoutes with the annotation, generates config, and hot-reloads Gatus.

**Current Monitors:**
- `pihole.lab/admin` (auto-discovered)
- `homeassistant.lab` (auto-discovered)
- `gatus.lab` (auto-discovered)
- Pi-hole DNS (static)
- Unbound DNS (static)

## Setup

1. **Create Slack secret:**
   ```bash
   kubectl create secret generic slack-webhook-url \
     --namespace gatus \
     --from-literal=url=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
   ```

2. **Deploy:**
   ```bash
   git add kubernetes/components/gatus/
   git commit -m "Add Gatus monitoring"
   git push
   ```

3. **Access:**
   - URL: http://gatus.lab
   - Or: `kubectl port-forward -n gatus svc/gatus 8080:80`

## Add New Monitors

### HTTP/HTTPS (Auto-Discovery)

Add annotation to any HTTPRoute:
```yaml
metadata:
  annotations:
    gatus.home-operations.com/enabled: "true"
    gatus.home-operations.com/path: "/health"  # optional
```

### DNS/TCP/ICMP (Static)

Edit [config.yaml](config.yaml) `endpoints` section:
```yaml
endpoints:
  - name: My Service
    url: "my-service.default.svc.cluster.local"
    dns:
      query-name: "example.com"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    alerts:
      - type: slack
```

## Troubleshooting

```bash
# Check sidecar logs
kubectl logs -n gatus -l app.kubernetes.io/name=gatus -c gatus-sidecar

# Check Gatus logs
kubectl logs -n gatus -l app.kubernetes.io/name=gatus -c gatus

# Verify HTTPRoute annotations
kubectl get httproute -A -o yaml | grep -A 2 "gatus.home-operations"

# Restart
kubectl rollout restart deployment -n gatus
```

## Architecture

```
Pod: gatus (2 containers)
├── gatus (main) - Reads /config/config.yaml + /config/gatus-sidecar.yaml
└── gatus-sidecar - Watches HTTPRoutes → Writes /config/gatus-sidecar.yaml
```

## Links

- [Gatus](https://github.com/TwiN/gatus)
- [gatus-sidecar](https://github.com/home-operations/gatus-sidecar)
- [Gatus Docs](https://gatus.io)
