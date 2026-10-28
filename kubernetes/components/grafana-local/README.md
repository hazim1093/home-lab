# Grafana (local instance)

A self-hosted Grafana, run by the `grafana-operator`, exposed only on the local
domain at `https://grafana.${LOCAL_DOMAIN}`.

For app data visualizations, not infrastructure metrics.
Apps attach datasources and dashboards by setting `instanceSelector` label `dashboards: grafana-local` and
`allowCrossNamespaceImport: true` on their CRs. Nothing here is game-specific:
what it displays is decided entirely by those attached resources.

## Admin password

The operator generates the admin credentials in a Secret (nothing in git):

```bash
kubectl -n grafana-local get secret grafana-local-admin-credentials \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d
```

Sign-up and anonymous access are off, so this is the only way in.

## State

No PVC: datasources and dashboards are CRs, so the instance is fully
reproducible and sessions reset on restart. Exposure is LAN-only (Traefik on the
local domain); the only controls are Grafana's own login plus the network policy.
