# Renovate

Automated dependency updates for Kubernetes components.

## Setup

Create secret with GitHub token:

```bash
kubectl create secret generic renovate-secret \
  --namespace renovate \
  --from-literal=token=YOUR_GITHUB_TOKEN
```

Update repository name in `cronjob.yaml` to match your GitHub repo.

## Trigger manually

```bash
kubectl create job --from=cronjob/renovate renovate-manual -n renovate
```
