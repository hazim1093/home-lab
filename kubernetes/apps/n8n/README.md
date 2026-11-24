# n8n

`https://n8n.${LOCAL_DOMAIN}` — standalone n8n (SQLite on a PVC, no queue mode).

`N8N_ENCRYPTION_KEY` in `secret.yaml` encrypts all stored credentials. Back it
up (`sops -d kubernetes/apps/n8n/secret.yaml`); losing it loses them.
