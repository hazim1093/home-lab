# homarr-bootstrap

One-shot Job that applies the Homarr login from the SOPS secret, so the dashboard never needs
the first-run wizard. The dashboard itself lives in [`../homarr`](../homarr).

Why a separate component: Flux health-checks Jobs, and `../homarr` runs with `wait: true`. When
the Job failed (a wrong CLI invocation — see below), the dashboard's Kustomization stayed
`HealthCheckFailed`, which in turn blocked `homarr-controller` via `dependsOn`. This Kustomization
runs with `wait: false`, so the bootstrap can never gate the dashboard again.

## What it runs

Homarr's own CLI, shipped inside the application image (invoked as `homarr`, but note the command
*group*: `homarr users list`, `homarr users update-password`, and `homarr recreate-admin`):

```sh
homarr users list                                       # probe: waits for the migrated database
homarr recreate-admin -u "$ADMIN_USERNAME"              # no-op when an admin already exists
homarr users update-password -u "$ADMIN_USERNAME" -p "$ADMIN_PASSWORD"
```

Credentials come from `homarr-secrets` (`admin-username`, `admin-password`); while the password is
still the `CHANGEME` placeholder the Job just logs that and exits 0.

## Re-running it

The Job is one-shot: it applies once and stays `Completed`, so Flux does not re-run it in a loop and
log you out. To apply changed credentials (or a fixed script), delete it and let Flux recreate it:

```bash
kubectl -n homarr delete job homarr-admin-bootstrap-v2
flux reconcile kustomization homarr-bootstrap -n flux-system --with-source   # or wait for the 10m interval
```

When you edit the script itself, bump the `-v2` suffix instead (a Job's pod template is immutable)
and let the old one be pruned. Check the outcome with:

```bash
kubectl -n homarr logs job/homarr-admin-bootstrap-v2
```
