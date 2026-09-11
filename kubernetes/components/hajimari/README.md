# Hajimari

[Hajimari](https://github.com/toboshii/hajimari) start page, at `https://hajimari.<LOCAL_DOMAIN>`.
Second dashboard, kept next to `kubernetes/components/homer/` for comparison.

**Known limitation:** upstream Hajimari (v0.3.1, last release Oct 2022) only discovers `Ingress`
objects — Gateway API support is an open issue (toboshii/hajimari#163) and the PR adding HTTPRoute
discovery was closed unmerged. This cluster exposes everything through HTTPRoutes, so the app list in
`helmrelease.yaml` (`hajimari.customApps`) is **static** and has to be edited when a service is added.
`defaultEnable: true` is set so any future `Ingress` would still be picked up automatically.

## Adding an app

Append to `customApps` in `helmrelease.yaml`:

```yaml
        - group: Infrastructure
          apps:
            - name: My App
              url: "https://my-app.${LOCAL_DOMAIN}"
              icon: mdi:application   # any Material Design Icons name
              info: "optional description"
```

Or, without touching the HelmRelease, drop an `Application` object next to the app:

```yaml
apiVersion: hajimari.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  name: My App
  group: Infrastructure
  icon: mdi:application
  url: https://my-app.<LOCAL_DOMAIN>
```

Apps that only exist in `home-lab-private` are intentionally not listed here (public repo) — add them
by hand (name + `https://<host>.${LOCAL_DOMAIN}`) if you want them on this dashboard too.

## crd.yaml / rbac.yaml

The released chart (2.0.2) ships the `applications.hajimari.io` CRD file but does not install it, and
its ClusterRole only covers `ingresses`/`endpointslices`. Without both, Hajimari's 60s discovery loop
logs an error and then discards the Ingress results it did collect. `crd.yaml` is upstream's file,
verbatim; `rbac.yaml` grants the `applications` read the loop needs.

`persistence.data` is disabled: per-browser appearance tweaks are not saved, nothing else needs a volume.
Resources: single replica, `requests: 10m/32Mi`, `showAppStatus` off (static apps have no replica status).

Verify:

```bash
kubectl get hr,pod -n hajimari
kubectl logs -n hajimari deploy/hajimari | tail          # no repeated CRD/Ingress errors
kubectl get crd applications.hajimari.io
kubectl get application -A
kubectl get configmap hajimari-settings -n hajimari -o yaml   # rendered app list
```
