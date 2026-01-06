# Flux v2 Bootstrap with OpenTofu

Bootstraps Flux v2 on your K3s cluster using OpenTofu with Cloudflare R2 backend.

## Prerequisites

- OpenTofu >= 1.8.0
- kubectl configured with access to your K3s cluster
- GitHub personal access token with `repo` permissions
- Cloudflare R2 bucket for state storage

## Setup

### 1. Configure Cloudflare R2 Backend

Edit `backend.tf` and replace `<ACCOUNT_ID>` with your Cloudflare account ID.

Set environment variables:

```bash
export AWS_ACCESS_KEY_ID="<r2-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<r2-secret-access-key>"
export TF_VAR_github_token="<github-pat>"
export AWS_ENDPOINT_URL_S3="https://<account-id>.r2.cloudflarestorage.com"
```

### 2. Configure variables

Edit `terraform.auto.tfvars` with your values.

### 3. Initialize and Apply

```bash
tofu init
tofu plan
tofu apply
```

## Cleanup

```bash
tofu destroy
```
