# Renovate

## Trigger manually

```bash
kubectl create job --from=cronjob/renovate renovate-manual-$(shuf -i 1-100 -n 1) -n renovate
```
