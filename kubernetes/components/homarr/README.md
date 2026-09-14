# Homarr

[Homarr](https://github.com/homarr-labs/homarr) dashboard (official chart, OCI `ghcr.io/homarr-labs/charts`),
at `https://homarr.<LOCAL_DOMAIN>`. Its config lives in its own SQLite database (drag and drop, no YAML),
so there is **no Kubernetes operator** for it — the `homarr-httproute-sync` CronJob below uses Homarr's
[official API](https://homarr.dev/docs/management/api) to add apps instead.

## How the sync behaves

Every 10 minutes the CronJob lists Gateway API HTTPRoutes (read-only RBAC) and makes sure each hostname
has an app in Homarr, matched on the app URL:

- **new route → app created** (name, icon, description, `pingUrl` set to the in-cluster URL taken from the
  gatus annotation, so Homarr can show online/offline status)
- **existing apps are never modified or deleted** — anything you rename or move in the UI sticks
- a newly created app is placed on a board once (first board, or `BOARD_NAME`); if placement fails it is
  logged and the app just needs one manual drag. Existing items are never moved, so no duplicates

Per-route annotations (all optional):

| Annotation | Effect |
|---|---|
| `homarr.synced/name` | app title (defaults to the route name) |
| `homarr.synced/icon` | [dashboard-icons](https://github.com/homarr-labs/dashboard-icons) slug, e.g. `home-assistant`, or a full URL |
| `homarr.synced/description` | subtitle (defaults to `<namespace>/<route>`) |
| `homarr.synced/enabled` | `"false"` keeps the route out of Homarr |

## First-time setup (once)

1. Open `https://homarr.<LOCAL_DOMAIN>` and create the owner account.
2. `Management → Tools → API → Authentication` → create an API key (format `<id>.<token>`).
3. Store it in the SOPS secret (keeps it out of process listings):

```bash
export SOPS_AGE_KEY_FILE=/opt/data/.config/sops/age/keys.txt
printf '"%s"' '<id>.<token>' | sops set --value-stdin kubernetes/components/homarr/secret.yaml '["stringData"]["api-key"]'
```

Commit and merge — until the key is set the CronJob logs a hint and exits without changes.

## K8s integration (`rbac.enabled`)

Enables Homarr's read-only cluster view (`Management → Tools → Kubernetes`). The chart creates a
ServiceAccount + ClusterRole that can read pods, services, **secrets**, configmaps, PVCs, namespaces,
PVs, nodes, deployments, ingresses and metrics, cluster-wide. Set `rbac.enabled: false` in the
HelmRelease if that is more access than you want.

Resources: single replica, `requests: 25m/256Mi`, 1Gi PVC for `/appdata` (SQLite).

Verify:

```bash
kubectl get hr,pod,pvc -n homarr
kubectl logs -n homarr deploy/homarr | tail                     # startup, DB migrations
kubectl get cronjob -n homarr
kubectl create job -n homarr --from=cronjob/homarr-httproute-sync sync-now   # run the sync by hand
kubectl logs -n homarr job/sync-now
```
