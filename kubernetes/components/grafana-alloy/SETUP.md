# Grafana Alloy Quick Setup

Ships cluster metrics (kubelet/cAdvisor) and pod logs to a Grafana Cloud
free-tier stack via [Grafana Alloy](https://grafana.com/docs/alloy/latest/).

## Prerequisites

You need an existing Grafana Cloud stack (the free tier is enough).

1. Get your Prometheus and Loki connection details:
   Grafana Cloud portal -> your stack -> **Send Metrics** (Prometheus) and
   **Send Logs** (Loki). Note the remote_write/push URL and username/instance
   ID for each.
2. Create an Access Policy Token scoped to `metrics:write` and `logs:write`:
   Grafana Cloud portal -> Administration -> Access Policies -> Create access policy.

## Configure

1. Edit `helmrelease.yaml` and replace the four placeholders in the Alloy
   config with your real values (not secret, safe to commit in plain text):
   - `GRAFANA_CLOUD_PROMETHEUS_URL`
   - `GRAFANA_CLOUD_PROMETHEUS_USERNAME`
   - `GRAFANA_CLOUD_LOKI_URL`
   - `GRAFANA_CLOUD_LOKI_USERNAME`

2. Edit `grafana-cloud-secret.yaml` and replace the placeholder `api-key`
   with the real Access Policy Token, then encrypt it in place:
   ```bash
   export SOPS_AGE_KEY_FILE=.age/key.txt
   sops --encrypt --in-place kubernetes/components/grafana-alloy/grafana-cloud-secret.yaml
   ```
   Verify it's encrypted: the file should show `sops:` metadata and
   `ENC[...]` in place of the token, not the plain text token.

## Deploy

```bash
git add kubernetes/components/grafana-alloy/
git add kubernetes/components/flux-system/
git commit -m "Add Grafana Alloy -> Grafana Cloud"
git push
```

## Verify

```bash
flux get kustomizations grafana-alloy
flux get helmreleases -n grafana-alloy
kubectl get pods -n grafana-alloy -w
kubectl logs -n grafana-alloy -l app.kubernetes.io/name=alloy
```

In Grafana Cloud, check **Explore** for the `integrations/kubernetes/cadvisor`
/ `integrations/kubernetes/kubelet` metric jobs, and the Loki datasource for
log lines labeled with `namespace`/`pod`/`container`.
