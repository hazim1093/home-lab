# home-lab
Home lab

## Node Tuning

### inotify limits (required for K3s + ARC runners)

K3s, Flux, Grafana Alloy, and ARC runner pods all register inotify watchers. The default kernel limits are too low and cause runner pods to crash on startup with `failed to create fsnotify watcher: too many open files`.

Apply on the K3s node:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
```

Make permanent (survives reboots):

```bash
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.conf
```

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

# Decrypt secrets
sops --decrypt secret.yaml > decrypted.yaml
```
