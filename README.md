# home-lab
Home lab

## Secrets Management (SOPS)

```bash
# Restore age key from backup
mkdir -p .age && echo "BACKED_UP_KEY" > .age/key.txt

# Deploy key to cluster
cat .age/key.txt | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin

# Encrypt secrets
export SOPS_AGE_KEY_FILE=.age/key.txt
sops --encrypt --in-place secret.yaml

# Edit encrypted secrets
sops secret.yaml
```
