# Gatus Quick Setup

## Prerequisites

Create Slack webhook secret:
```bash
kubectl create secret generic slack-webhook-url \
  --namespace gatus \
  --from-literal=url=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

Get webhook: https://api.slack.com/apps → Incoming Webhooks

## Deploy

```bash
git add kubernetes/components/gatus/
git add kubernetes/components/pihole/httproute.yaml
git add kubernetes/components/home-assistant/httproute.yaml
git add kubernetes/components/flux-system/
git commit -m "Add Gatus monitoring"
git push
```

## Verify

```bash
# Wait for pod (2/2 containers ready)
kubectl get pods -n gatus -w

# Check sidecar discovered routes
kubectl logs -n gatus -l app.kubernetes.io/name=gatus -c gatus-sidecar
```

## Access

Visit: **http://gatus.lab**

You should see **5 monitors**:
- pihole.lab/admin
- homeassistant.lab
- gatus.lab
- Pi-hole DNS
- Unbound DNS

## Add More Services

Just annotate any HTTPRoute:
```yaml
annotations:
  gatus.home-operations.com/enabled: "true"
```

Done! No Gatus config changes needed.
