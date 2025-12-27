# Renovate

Automated dependency updates for Kubernetes components.

## Setup

1. Create a GitHub Personal Access Token (classic) with these permissions:
   - `repo` (Full control of private repositories)
   - `workflow` (Update GitHub Action workflows)

2. Create secret:

```bash
kubectl create secret generic renovate-secret \
  --namespace renovate \
  --from-literal=token=YOUR_GITHUB_TOKEN
```

3. Update repository name in `cronjob.yaml` to match your GitHub repo (e.g., `username/repo-name`)

## Trigger manually

```bash
kubectl create job --from=cronjob/renovate renovate-manual -n renovate
```
