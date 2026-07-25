# screener

Crypto project screener — FastAPI backend + Next.js frontend.

Source: [hazim1093/screener-rag](https://github.com/hazim1093/screener-rag)

## Secrets

Both `secret.yaml` and `pull-secret.yaml` must be encrypted with SOPS before committing.

### API keys (`secret.yaml`)

```bash
# 1. Fill in values: TAVILY_API_KEY, LLM_PROVIDER, LLM_MODEL, ANTHROPIC_API_KEY / OPENAI_API_KEY
vi secret.yaml

# 2. Encrypt in place
sops --encrypt --in-place secret.yaml
```

### GHCR image pull secret (`pull-secret.yaml`)

The images are pulled from `ghcr.io/hazim1093` (private). Create a GitHub PAT with `read:packages` scope, then:

```bash
# 1. Replace <github-pat> in pull-secret.yaml with the real token
vi pull-secret.yaml

# 2. Encrypt in place
sops --encrypt --in-place pull-secret.yaml
```

To generate the correct `.dockerconfigjson` value from scratch:

```bash
echo -n '{"auths":{"ghcr.io":{"username":"hazim1093","password":"<github-pat>","auth":""}}}' \
  | python3 -c "import sys; d=sys.stdin.read(); open('pull-secret.yaml','w').write(
    'apiVersion: v1\nkind: Secret\nmetadata:\n  name: ghcr-pull-secret\n  namespace: screener\n'
    'type: kubernetes.io/dockerconfigjson\nstringData:\n  .dockerconfigjson: \''+d+'\'\n')"
sops --encrypt --in-place pull-secret.yaml
```

### Editing an encrypted secret

```bash
sops secret.yaml
sops pull-secret.yaml
```

## Building Docker images

From the `screener-rag` repo root:

```bash
# Build both images
make docker-build NEXT_PUBLIC_API_URL=https://screener-api.yourdomain.com

# Build individually
make docker-build-api
make docker-build-frontend NEXT_PUBLIC_API_URL=https://screener-api.yourdomain.com
```

Override image tags:

```bash
make docker-build \
  API_IMAGE=ghcr.io/hazim1093/screener-api:v1.0.0 \
  FRONTEND_IMAGE=ghcr.io/hazim1093/screener-frontend:v1.0.0 \
  NEXT_PUBLIC_API_URL=https://screener-api.yourdomain.com
```

> `NEXT_PUBLIC_API_URL` is baked into the frontend image at build time — it cannot be changed at runtime. Rebuild the frontend image if the API domain changes.

## Deploying

```bash
kubectl apply -k kubernetes/components/screener/
```

The app will be available at:

- Frontend: `https://screener.${LOCAL_DOMAIN}`
- API: `https://screener-api.${LOCAL_DOMAIN}`
