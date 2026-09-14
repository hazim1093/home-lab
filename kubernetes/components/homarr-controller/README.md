# homarr-controller

[adamancini/homarr-kubernetes-dashboard-controller](https://github.com/adamancini/homarr-kubernetes-dashboard-controller)
— the community controller that keeps a Homarr board in sync with annotated HTTPRoutes (there is no
official Homarr operator; Homarr itself has no config-as-code for apps).

Chart `oci://ghcr.io/adamancini/charts/homarr-kubernetes-dashboard-controller` (0.4.0), running in the
`homarr` namespace next to the dashboard (hence `dependsOn: homarr` for the namespace and the API-key
secret).

## How it is wired here

- `sources: [gateway-httproute]` — this lab has no Ingress/IngressRoute objects
- `homarr.apiKeySecret` reuses `homarr-secrets`/`api-key` (same secret as the dashboard)
- `board.name: home-lab` — created on first sync if missing; set an existing board name to take it over
- `defaultIconBaseURL` points at homarr-labs/dashboard-icons (matches the slugs used in annotations)
- `allNamespaces: true`, ignoring `kube-system` + `flux-system`

## Annotations (on the HTTPRoute)

Only routes with `homarr.dev/enabled: "true"` are managed; `name` and `url` are required.

| Annotation | Notes |
|---|---|
| `homarr.dev/enabled` | `"true"` to manage the route |
| `homarr.dev/name` | board title |
| `homarr.dev/url` | link target (`https://<host>.${LOCAL_DOMAIN}`) |
| `homarr.dev/icon` | dashboard-icons slug (`gatus`, `pi-hole`, …) or full URL |
| `homarr.dev/description` | subtitle |
| `homarr.dev/ping-url` | in-cluster URL for status dots (copied from the gatus endpoint) |
| `homarr.dev/category` | board group for the tile. Defaults to the route's **namespace**, so without it every route lands in a group of its own; groups in use: `Dashboards`, `Monitoring`, `Home & Network`, `AI & Dev` |

Unannotated routes (e.g. `hermes-api`, `ha-mcp`) are ignored — deliberately not listed in the dashboard.
Routes annotated **and** then un-annotated are removed from the board by the controller, since it
reconciles desired state.

## Caveat

Groups are created but never deleted: dropping or changing a `homarr.dev/category` leaves the old,
now-empty group header on the board, so delete those once in the board editor. A group's position is
fixed when it is first created (the controller assigns the y-offset on that first reconcile) —
reorder by dragging the header afterwards, which sticks.

The controller talks to Homarr's internal tRPC API rather than the documented OpenAPI surface, so a
Homarr upgrade can break it before an upstream fix lands. It is a young project (single maintainer,
v0.4.0); if it misbehaves, the previous approach — a small in-repo CronJob driving `POST /api/apps` —
is in git history (PR #95/#96 era).
