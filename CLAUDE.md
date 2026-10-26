# Home Lab Repository Documentation

> **Purpose**: Explains how this home-lab repo is wired, so an agent (or a human) can add, change, or debug infrastructure without reading every manifest first. It describes the repo **as it is now**. When this file and a manifest disagree, the manifest wins — fix this file.

## Repository Visibility: PUBLIC

**This repository is public.** Never commit or suggest committing any of the following in plaintext:

- Real secrets, tokens, passwords, or API keys — these must always go through SOPS (`sops --encrypt --in-place ...`) before being committed, no exceptions, not even "temporarily"
- The real home/public domain name, DDNS hostname, or ISP-assigned public IP — use `${LOCAL_DOMAIN}` / `${BASE_DOMAIN}` substitution, `example.com` / `.lab` placeholders, and RFC1918 private IPs (`192.168.0.x` etc.) in examples, docs, and code
- Personal email addresses, phone numbers, or other PII beyond what's already public via the GitHub account (git commit author identity)
- Real values in planning docs, specs, or scratch files under `docs/` — use placeholders (`<PASTE_...>`, `REPLACE_WITH_...`) exactly like existing secret templates in this repo, never a real pasted-in value

If asked to add DNS entries, secrets, or config referencing real infrastructure details, always default to placeholders/examples unless explicitly told the value is safe to publish.

## Table of Contents

- [Stack](#stack)
- [Directory Structure](#directory-structure)
- [How Flux Wires It Together](#how-flux-wires-it-together)
- [Inventory: Components](#inventory-components)
- [Inventory: Apps](#inventory-apps)
- [Adding a New App or Component](#adding-a-new-app-or-component)
- [Secrets Management](#secrets-management)
- [Service Exposure](#service-exposure)
- [DNS](#dns)
- [Certificates](#certificates)
- [CI/CD: Validation, Runners, Renovate](#cicd-validation-runners-renovate)
- [Observability](#observability)
- [The Hermes Agent Box](#the-hermes-agent-box)
- [Node, K3s, and CNI Notes](#node-k3s-and-cni-notes)
- [Raspberry Pi (Hallon)](#raspberry-pi-hallon)
- [Common Patterns Reference](#common-patterns-reference)
- [Verifying Changes](#verifying-changes)
- [Pitfalls](#pitfalls)

---

## Stack

| Layer | Choice | Where |
|---|---|---|
| Distro | K3s, single node, bundled Traefik/ServiceLB disabled | `cluster/k3s/config.yaml` |
| CNI | Cilium (VXLAN tunnel, kube-proxy **not** replaced, Hubble on) | `kubernetes/components/cilium/` |
| GitOps | Flux CD v2, bootstrapped with OpenTofu (Cloudflare R2 state backend) | `kubernetes/bootstrap/flux/`, `kubernetes/components/flux-system/` |
| Ingress | Traefik **Gateway API** (`kubernetesGateway` provider), no IngressRoutes | `kubernetes/components/traefik/` |
| LB | MetalLB L2, pool `192.168.0.200-192.168.0.210` | `kubernetes/components/metallb{,-config}/` |
| TLS | Let's Encrypt **production**, DNS-01 via Cloudflare, wildcard `*.${LOCAL_DOMAIN}` | `kubernetes/components/certificates/`, `traefik/certificate.yaml` |
| Public DNS | external-dns → **Cloudflare** (`gateway-httproute` source) | `kubernetes/components/external-dns/` |
| LAN DNS | PiHole (blocklists) + Unbound (recursive) on `192.168.0.201` | `kubernetes/components/pihole/` |
| Secrets | SOPS + age, Flux `decryption.provider: sops` | `.sops.yaml`, `kubernetes/**/secret*.yaml` |
| Scale-to-zero | KEDA + KEDA HTTP add-on (`HTTPScaledObject`) | `kubernetes/components/keda{,-http}/` |
| CI runners | GitHub Actions Runner Controller (ARC) in-cluster | `kubernetes/components/arc-{controller,cluster-runner}/` |
| Observability | Grafana Alloy → Grafana Cloud; Grafana operator manages dashboards/alerts; Gatus for uptime | `grafana-*`, `gatus/`, `kube-state-metrics/`, `node-exporter/` |
| Private access | Tailscale operator (`ingressClassName: tailscale`) | `kubernetes/components/tailscale-operator/` |

**Key principle**: everything except the node bootstrap is declarative and reconciled by Flux from this repo. Secrets are encrypted before they are committed.

---

## Directory Structure

```
home-lab/
├── CLAUDE.md                       # this file
├── README.md                       # SOPS bootstrap + node sysctl tuning
├── renovate.json                   # dependency update config
├── .sops.yaml                      # encryption rules + age recipients
├── .github/workflows/
│   ├── k8s-validation.yml          # calls hazim1093/ci k8s-validation on PRs/pushes
│   └── secret-scan.yml             # calls hazim1093/ci gitleaks scan on PRs/pushes
├── cluster/k3s/                    # install/upgrade/uninstall/get-kubeconfig + config.yaml
├── kubernetes/
│   ├── bootstrap/flux/             # OpenTofu: bootstraps Flux onto the cluster
│   ├── components/                 # platform pieces AND the Flux control plane
│   │   ├── flux-system/            # Flux core, repo definitions, per-bundle Kustomizations
│   │   │   ├── flux-system/        # gotk-components.yaml + gotk-sync.yaml (DO NOT EDIT)
│   │   │   ├── repos/              # HelmRepository + the private GitRepository
│   │   │   ├── apps/               # one Kustomization per bundle + kustomization.yaml
│   │   │   └── alerts.yaml         # Slack notifications for Flux events
│   │   └── <component>/            # traefik/, cert-manager/, pihole/, cilium/, ...
│   └── apps/                       # user-facing applications
│       └── <app>/                  # hermes/, paperless/, couchdb/, ...
├── hallon/                         # Raspberry Pi (Zigbee2MQTT) via Ansible + Docker
├── lab/                            # non-cluster experiments (local-llm docker-compose)
└── docs/                           # plans/ and manual-step runbooks
```

### Standard bundle layout

Every entry in `kubernetes/apps/` and `kubernetes/components/` is a directory with its own `kustomization.yaml` listing its files:

```
kubernetes/apps/my-app/
├── kustomization.yaml      # lists every file below
├── namespace.yaml
├── deployment.yaml         # or helmrelease.yaml
├── service.yaml
├── httproute.yaml          # optional, if it should be reachable
├── pvc.yaml                # optional
├── networkpolicy.yaml      # optional
├── secret.yaml             # SOPS-encrypted
└── README.md               # optional, for anything non-obvious
```

`components/flux-system/apps/kustomization.yaml` lists one Kustomization file per bundle. That list is the registry — a bundle directory that is not listed there is never deployed.

---

## How Flux Wires It Together

### The chain

```
cluster/k3s/install-k3s.sh
  └─ helm install cilium            (durable CNI before anything can be scheduled)
  └─ kubernetes/bootstrap/flux      (OpenTofu) → flux bootstrap
       └─ GitRepository flux-system (this repo, branch main, every 1m)
            └─ Kustomization flux-system → ./kubernetes/components/flux-system
                 ├─ flux-system/gotk-components.yaml   (controllers)
                 ├─ flux-system/gotk-sync.yaml         (GitRepository + this Kustomization)
                 ├─ repos/                             (HelmRepository + GitRepository defs)
                 ├─ apps/                              (one Kustomization per bundle)
                 └─ alerts.yaml                        (Slack Provider + Alert)
```

`apps/*.yaml` are `kustomize.toolkit.fluxcd.io/v1` Kustomizations pointing at `./kubernetes/components/<name>` or `./kubernetes/apps/<name>`, with `prune: true`, `sourceRef` = GitRepository `flux-system`, plus per-bundle `dependsOn` / `healthChecks` / `decryption` / `postBuild`.

### Current API versions in use

```yaml
kustomize.toolkit.fluxcd.io/v1     # Flux Kustomization
helm.toolkit.fluxcd.io/v2          # HelmRelease
source.toolkit.fluxcd.io/v1        # HelmRepository / GitRepository
gateway.networking.k8s.io/v1       # HTTPRoute (Gateway API v1.6.1 standard channel)
cert-manager.io/v1
notification.toolkit.fluxcd.io/v1beta3
```

Copy a neighbour instead of trusting snippets: `traefik.yaml` or `tailscale-operator.yaml` for components, `paperless.yaml` for an app using KEDA HTTP, `couchdb.yaml` for an app with a health check and no HTTPRoute.

### Post-build substitution (`${...}`)

Two substitution sources exist and **each Kustomization opts in by itself** — there is no cluster-wide substitution:

```yaml
spec:
  postBuild:
    substituteFrom:
    - kind: Secret
      name: domain-config
```

`domain-config` lives in `kubernetes/components/flux-system-secrets/domain-config.yaml` (SOPS-encrypted, `flux-system`) and provides exactly three keys:

| Key | Meaning | Example value |
|---|---|---|
| `BASE_DOMAIN` | Registrable domain managed in Cloudflare | `example.com` |
| `LOCAL_DOMAIN` | Subdomain used for this lab's hostnames | `local.example.com` |
| `ACME_EMAIL` | Let's Encrypt ACME registration address | `<admin@example.com>` |

Consequences worth knowing:

- A bundle whose manifests contain `${LOCAL_DOMAIN}` **must** set `postBuild.substituteFrom: domain-config`, or Flux substitutes an empty string and you end up with an HTTPRoute with no hostname. Currently opted in: `traefik`, `certificates`, `external-dns`, `pihole`, `home-assistant`, `gatus`, `hajimari`, `homarr`, `ha-mcp`, `hermes`, `hermes-workspace`, `obsidian-mcp`, `paperless`, `private-apps`.
- Flux's substitution blanks **any** `${...}` it does not know — including shell variables inside inline scripts. Use bare `$VAR` / `printf` in embedded scripts (see the comment in `kubernetes/apps/hermes/tools-install-job.yaml`) or escape as `$${VAR}`.
- Hostname convention: `<app>.${LOCAL_DOMAIN}`. Never hardcode the real domain.

### SOPS decryption

Any Kustomization deploying encrypted Secrets needs:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

`sops-age` is the age key Secret in `flux-system` — see [Secrets Management](#secrets-management).

### Dependency map (from `flux-system/apps/*.yaml`)

| Bundle | dependsOn | Notes |
|---|---|---|
| `traefik` | `gateway-api`, `cert-manager` | owns `traefik-gateway` at `192.168.0.200` |
| `certificates` | `cert-manager` | ClusterIssuers + Cloudflare API token |
| `metallb-config` | `metallb` | IPAddressPool + L2Advertisement |
| `arc-cluster-runner` | `arc-controller` | runner scale set needs the controller |
| `grafana-resources` | `grafana-operator` | dashboard/alert CRs need the CRDs |
| `couchdb` | `tailscale-operator` | tailnet-only, no HTTPRoute |
| `obsidian-mcp` | `couchdb` | talks to CouchDB live-sync |
| `obsidian-vault-backup` | `couchdb` | restic backups of the vault |
| `hermes` | `traefik`, `keda-http` | dashboard + gateway HTTPRoutes |
| `hermes-workspace` | `traefik`, `keda-http` | workspace UI |
| `paperless` | `traefik`, `keda-http` | scale-to-zero via HTTPScaledObject |
| `private-apps` | `traefik` | reconciles the **private** repo's `kubernetes/apps` |
| `cilium` | — | health-checked on its HelmRelease in `kube-system` |
| everything else | — | independent |

Do not copy `dependsOn` blind: an app with no HTTPRoute and no KEDA object has no reason to depend on `traefik`.

### The private repo

```yaml
# flux-system/repos/home-lab-private.yaml
kind: GitRepository
metadata: {name: home-lab-private}
spec:
  url: ssh://git@github.com/hazim1093/home-lab-private
  secretRef: {name: home-lab-private-auth}
```

`flux-system/apps/private-apps.yaml` points that GitRepository at `./kubernetes/apps` with `prune: true` and `domain-config` substitution. Apps that must not be public live there — e.g. `screener` (its namespace appears in `keda-http/referencegrant.yaml`). Apps that can be public stay in this repo under `kubernetes/apps/`. Both reconcile identically; the only difference is visibility.

---

## Inventory: Components

Platform pieces in `kubernetes/components/`. Charts are pinned to explicit versions; `keda` and `keda-http` intentionally float (`2.x` / `0.x`).

| Component | What it is | Chart / source |
|---|---|---|
| `flux-system` | Flux controllers, repo definitions, per-bundle Kustomizations, Slack alerts | gotk-components (generated) |
| `flux-system-secrets` | `domain-config` + alert webhook secret | raw |
| `cilium` | CNI, Hubble, NetworkPolicy. `values.yaml` is the single source of truth, also consumed by `install-k3s.sh` | `cilium` 1.20.4 |
| `metallb` + `metallb-config` | L2 load balancer, pool `192.168.0.200-210` | `metallb` 0.16.1 |
| `gateway-api` | Gateway API CRDs v1.6.1 (standard channel, remote URL) | upstream release |
| `cert-manager` | Certificate controller | `jetstack/cert-manager` v1.19.2 |
| `certificates` | ClusterIssuers: selfsigned → internal CA → internal intermediate; LE staging/prod with Cloudflare DNS-01 | raw |
| `traefik` | Gateway `traefik-gateway` (`web` 8000 → redirect, `websecure` 8443), default TLSStore cert, MetalLB IP `192.168.0.200` | `traefik` 42.1.3 |
| `external-dns` | Cloudflare records from HTTPRoutes, `policy: sync`, txt registry, domain filter `${BASE_DOMAIN}` | `external-dns` 1.22.0 |
| `pihole` | LAN DNS + blocklists, Unbound sidecar on 5335, DNS LoadBalancer `192.168.0.201` | `mojo2600/pihole` 2.38.0 |
| `mosquitto` | MQTT broker for Zigbee2MQTT/HA, LoadBalancer `192.168.0.202` | raw |
| `home-assistant` | Home Assistant core | `home-assistant` 0.3.87 |
| `ha-mcp` | Home Assistant MCP server (`ghcr.io/homeassistant-ai/ha-mcp`, port 8086, path `/mcp`) | raw |
| `rustdesk` | Remote desktop relay, LoadBalancer `192.168.0.203` | `pschichtel` 0.2.4 |
| `keda` / `keda-http` | Autoscaler + HTTP add-on (interceptor). `ReferenceGrant` lets `screener` and `paperless` HTTPRoutes reach the interceptor | `kedacore` 2.x / 0.x |
| `reloader` | Restarts workloads when referenced ConfigMap/Secret changes | `stakater` 2.2.18 |
| `tailscale-operator` | Tailnet ingress, OAuth from `operator-oauth` secret | `tailscale` 1.102.4 |
| `arc-controller` / `arc-cluster-runner` | GitHub Actions runner scale set (0→1) for `hazim1093/screener-rag`, image `ghcr.io/hazim1093/arc-runner` | `arc` 0.15.0 |
| `grafana-operator` | Manages dashboards/alerts against an **external** Grafana Cloud instance | `grafana` 5.25.0 |
| `grafana-alloy` | Ships metrics/logs to Grafana Cloud | `grafana` 1.14.3 |
| `grafana-resources` | Dashboards, folders, contact points, alert rules as CRs | raw |
| `kube-state-metrics` / `node-exporter` | Cluster metrics for scraping | `prometheus-community` 8.6.0 / 4.59.0 |
| `gatus` | Uptime checks; reads HTTPRoute annotations (`gatus.home-operations.com/*`) | `twin` 1.5.0 |
| `hajimari` | Static-link start page | `hajimari` 2.0.2 |
| `homarr` | Board dashboard; CronJob syncs HTTPRoutes into the board every 10m from `homarr.dev/*` annotations | `homarr` 8.29.2 |
| `renovate` | Self-hosted Renovate CronJob | raw |

---

## Inventory: Apps

User-facing applications in `kubernetes/apps/`. All have `decryption: sops`; most have `domain-config` substitution.

| App | What it is | Exposure |
|---|---|---|
| `hermes` | Hermes agent: gateway (8642) + dashboard (9119) in one s6-supervised pod; PVC `hermes-data`; dedicated SA `hermes-agent` with `view` + read on httproutes/gateways; NetworkPolicy limits ingress to hermes / hermes-workspace / traefik / gatus namespaces | `hermes.${LOCAL_DOMAIN}`, `hermes-api.${LOCAL_DOMAIN}` |
| `hermes-workspace` | Companion workspace UI for the gateway | `hermes-workspace.${LOCAL_DOMAIN}` |
| `paperless` | Paperless-ngx (SQLite + Valkey), scale-to-zero 0↔1 via `HTTPScaledObject`, nightly backup CronJob | `paperless.${LOCAL_DOMAIN}` |
| `couchdb` | CouchDB for Obsidian LiveSync | tailnet only: `Ingress` with `ingressClassName: tailscale` |
| `obsidian-mcp` | MCP server over the synced vault (`ghcr.io/es617/obsidian-sync-mcp`) | cluster-internal |
| `obsidian-vault-backup` | restic backup / retention / verify CronJobs for the vault, plus vault materialization | cluster-internal |

Notes:

- The notes stack (`couchdb`, `obsidian*`) is encrypted with the **primary age key only** — see `.sops.yaml`. The restic password unlocks the whole vault, so the agent key is deliberately excluded; an agent cannot read those secrets.
- `hermes` and `paperless` pods carry inline scripts; anything inside them must avoid `${...}`.

---

## Adding a New App or Component

Mechanically `kubernetes/apps/` and `kubernetes/components/` are identical: own directory, own `kustomization.yaml`, own Flux Kustomization in `flux-system/apps/`, own `dependsOn` / `healthChecks` / SOPS / substitution. The only decision is **role**:

- **`kubernetes/components/`** — platform/core: things other workloads depend on, or that the platform is built from (traefik, cert-manager, cilium, keda, tailscale-operator, pihole, metallb…). Helm or raw, doesn't matter.
- **`kubernetes/apps/`** — user-facing applications layered on the platform (hermes, paperless, couchdb…). Helm or raw, doesn't matter: `couchdb` is a Helm chart and lives here because it is an application.

### Steps

1. **Create the bundle** `kubernetes/<apps|components>/my-app/` with `namespace.yaml`, `helmrelease.yaml` *or* raw manifests, and a `kustomization.yaml` listing every file.
2. **Add a HelmRepository** only if the chart source is new: `flux-system/repos/my-repo.yaml`, then list it in `flux-system/repos/kustomization.yaml`. Already registered: `traefik`, `jetstack`, `cilium`, `metallb`, `kedacore`, `prometheus-community`, `grafana`, `stakater`, `pschichtel`, `twin`, `hajimari`, `homarr`, `home-assistant`, `mojo2600`, `external-dns`, `arc`, `tailscale`, `couchdb`.
3. **Create the Flux Kustomization** `flux-system/apps/my-app.yaml`, copying the closest neighbour:

   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: my-app
     namespace: flux-system
   spec:
     interval: 10m
     path: ./kubernetes/<apps|components>/my-app
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     wait: true
     dependsOn:            # only what this app truly needs
       - name: traefik
     healthChecks:         # recommended for Helm-based bundles
       - apiVersion: helm.toolkit.fluxcd.io/v2
         kind: HelmRelease
         name: my-app
         namespace: my-app
     decryption:           # only if the bundle ships SOPS secrets
       provider: sops
       secretRef:
         name: sops-age
     postBuild:            # only if manifests contain ${LOCAL_DOMAIN}
       substituteFrom:
         - kind: Secret
           name: domain-config
   ```

4. **Register it** in `flux-system/apps/kustomization.yaml`.
5. **Encrypt secrets before committing**: `export SOPS_AGE_KEY_FILE=.age/key.txt && sops --encrypt --in-place kubernetes/<apps|components>/my-app/secret.yaml`.
6. **Open a PR** (see [CI/CD](#cicd-validation-runners-renovate)). Merging to `main` is the deploy; Flux reconciles within ~1 minute.

Helm-based bundles use:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
  namespace: my-app
spec:
  interval: 12h
  chart:
    spec:
      chart: my-app-chart
      version: "1.2.3"            # pin explicitly; Renovate bumps it
      sourceRef:
        kind: HelmRepository
        name: my-repo
        namespace: flux-system
      interval: 12h
  values:
    # ...
```

---

## Secrets Management

SOPS + age. `.sops.yaml` has **two rules, first match wins**:

1. `kubernetes/apps/(couchdb|obsidian|obsidian-vault-backup)/*.yaml` → encrypted to the **primary key only** (agent key excluded on purpose).
2. Catch-all → primary key **+ `hermes-agent` key** (`age1470xftej...`), so the agent box can decrypt and edit everything else.

Both rules set `encrypted_regex: ^(data|stringData)$` — only Secret payloads are encrypted; metadata, `type` and comments stay readable.

Primary age public key (safe to publish): `age1s84t0ws8cpp8ujf8mny373gg63g9d52fezrdwe24jdfe4d309pwqvawpcu`

### Bootstrap (one-time, needs the private key)

```bash
mkdir -p .age && echo "<AGE_PRIVATE_KEY>" > .age/key.txt   # .age/ is gitignored
cat .age/key.txt | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin
```

See [`README.md#Secrets-Management`](README.md#secrets-management) for the agent-key bootstrap and revocation notes.

### Day-to-day

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
sops --encrypt --in-place path/to/secret.yaml   # encrypt a fresh plaintext file
sops path/to/secret.yaml                        # edit in place (decrypt → $EDITOR → encrypt)
sops updatekeys -r kubernetes/                  # re-wrap after adding/removing a recipient
```

Adding or revoking the agent key: edit recipients in `.sops.yaml` → `sops updatekeys -r kubernetes/` → commit. Never write a decrypted value into a doc, plan, commit message, or scratch file in the repo.

---

## Service Exposure

Three patterns, chosen by protocol.

### 1. HTTP(S) → HTTPRoute on `traefik-gateway`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
  annotations:
    gatus.home-operations.com/enabled: "true"
    gatus.home-operations.com/endpoint: |
      url: "http://my-app.my-app.svc.cluster.local:8080/health"
      interval: 60s
      conditions:
        - "[STATUS] == 200"
    homarr.dev/enabled: "true"
    homarr.dev/category: "Homelab Apps"
    homarr.dev/name: "My App"
    homarr.dev/url: "https://my-app.${LOCAL_DOMAIN}"
    homarr.dev/icon: "https://example.com/icon.png"   # Homarr rejects app.create without one
    homarr.dev/ping-url: "http://my-app.my-app.svc.cluster.local:8080"
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - "my-app.${LOCAL_DOMAIN}"
  rules:
    - matches:
        - path: {type: PathPrefix, value: /}
      backendRefs:
        - name: my-app
          port: 8080
```

That one object gets you: TLS from the wildcard cert (default TLSStore, no per-route `certificateRefs` needed), a Cloudflare record (external-dns), a Gatus check, and a Homarr tile within 10 minutes.

Use `sectionName: web` only if you explicitly want plain HTTP — `web` redirects to `websecure` by default.

### 2. Non-HTTP → LoadBalancer with a fixed MetalLB IP

| IP | Service |
|---|---|
| `192.168.0.200` | Traefik gateway |
| `192.168.0.201` | PiHole DNS |
| `192.168.0.202` | Mosquitto MQTT |
| `192.168.0.203` | RustDesk |
| `192.168.0.204-210` | free |

```yaml
spec:
  values:
    service:
      type: LoadBalancer
      loadBalancerIP: "192.168.0.204"
      externalTrafficPolicy: Local   # preserves client source IP
```

`metallb.universe.tf/loadBalancerIPs` on a Gateway, `loadBalancerIP` on a Service. Check `metallb-config/ipaddresspool.yaml` before picking an address.

### 3. Tailnet-only → `Ingress` with `ingressClassName: tailscale`

No MetalLB IP, no public DNS. The tailnet hostname comes from `tls.hosts[0]`, not from a rule host — see `kubernetes/apps/couchdb/ingress.yaml`.

### 4. ClusterIP (internal only)

```yaml
spec:
  values:
    service:
      type: ClusterIP
      port: 5432
```

Reachable only at `<service>.<namespace>.svc.cluster.local:<port>`.

### Scale-to-zero with KEDA HTTP

`paperless` scales 0↔1 behind the KEDA HTTP interceptor:

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata: {name: my-app, namespace: my-app}
spec:
  hosts: ["my-app.${LOCAL_DOMAIN}"]
  scaleTargetRef: {name: my-app, kind: Deployment, apiVersion: apps/v1, service: my-app, port: 8080}
  replicas: {min: 0, max: 1}
  scaledownPeriod: 300
```

Its HTTPRoute must target the interceptor, which requires a `ReferenceGrant` in `keda-http` for the app's namespace — add always-on apps to `kubernetes/components/keda-http/referencegrant.yaml`. Per-PR preview namespaces get their own grant created with the preview.

---

## DNS

Two planes, do not mix them up:

- **Public/edge plane** — `external-dns` watches `gateway-httproute` objects and writes A/CNAME records into **Cloudflare** for `${BASE_DOMAIN}` with `policy: sync` (creates *and deletes*), txt registry `txtOwnerId: home-lab`, `txtPrefix: externaldns-`. A deleted HTTPRoute eventually deletes its record; that is intentional. It does not touch LAN DNS.
- **LAN plane** — PiHole at `192.168.0.201` with Unbound on `127.0.0.1#5335`. Only non-HTTP services that LAN clients must resolve by name get manual entries:

  ```yaml
  dnsmasq:
    customDnsEntries:
      - address=/rustdesk.lab/192.168.0.203
      - address=/mqtt.lab/192.168.0.202
  ```

  `.lab` names are a LAN convenience only; they are not what Traefik serves.

PiHole adlists seed `gravity.db` **on first install only** — later edits to that list need `pihole -a adlist ... && pihole -g` inside the pod. Unbound is a sidecar using the `unbound-config` ConfigMap (`private-domain: ${BASE_DOMAIN}` so public records aren't leaked upstream).

If a new HTTP service does not resolve: check the hostname with `kubectl get httproute -n <ns> -o yaml`, then `kubectl logs -n external-dns deploy/external-dns`. Do not hand-add Cloudflare records.

---

## Certificates

- **In use**: `local-wildcard-cert` in `traefik` — `*.${LOCAL_DOMAIN}` + `${LOCAL_DOMAIN}`, issuer `letsencrypt-prod`, DNS-01 via Cloudflare, 90 days, renews 15 days early, `rotationPolicy: Always`. Wired into the Gateway listener (`websecure`, `mode: Terminate`) and the default `TLSStore`, so HTTPRoutes need no cert refs.
- **Defined but unused**: the internal PKI chain in `certificates/clusterissuer.yaml` — `selfsigned-issuer` → `internal-ca` (10y) → `internal-intermediate-ca` (5y) → `internal-ca-issuer`. Nothing references `internal-ca-issuer` today; it is a leftover from the `.lab`-only setup. Use it for certs on non-public hostnames, or delete it if you are sure it is dead.
- `letsencrypt-staging` exists for testing solver changes without burning prod rate limits.

---

## CI/CD: Validation, Runners, Renovate

- **PR checks**: `.github/workflows/k8s-validation.yml` and `secret-scan.yml` are thin callers of reusable workflows in `hazim1093/ci` (k8s validation over `kubernetes/apps` + `kubernetes/components`, plus a gitleaks scan that comments offending files on the PR). Direct pushes to `main` bypass both — prefer PRs.
- **In-cluster runners**: ARC `gha-runner-scale-set` for `hazim1093/screener-rag`, 0→1 runners, image `ghcr.io/hazim1093/arc-runner`. The runner SA's ClusterRole is deliberately broad (namespaces, services, secrets, workloads, HTTPRoutes, ReferenceGrants, HTTPScaledObjects, patch Kustomizations/HelmReleases) because it runs **ephemeral per-PR preview environments** that are torn down with the preview. Personal accounts cannot have account-level runners, hence per-repo scoping: a new repo needs its own runner (or a GitHub org).
- **Renovate**: `renovate.json` runs "before 6am on monday", manages helm/flux/k8s/terraform/helm-values over `kubernetes/components/**` (plus `apps/paperless`, `apps/hermes`), ignores `flux-system/**`. Custom regex managers pick up `# renovate: datasource=... depName=...` comments — use that annotation for pinned non-chart versions (images, CLI versions, upstream CRD URLs).

---

## Observability

- Metrics/logs → **Grafana Cloud** via Alloy. `grafana-operator` treats the remote instance as a `Grafana` CR (`grafana-resources/grafana-instance.yaml`) and pushes dashboards, folders, contact points and alert rules from YAML. Existing alert rules cover Hermes/OpenRouter limits and Paperless backup failures, delivered to Slack.
- **Gatus** (`gatus.home-operations.com/enabled: "true"` on an HTTPRoute) is the uptime layer; its ServiceAccount reads HTTPRoutes, so endpoints are never hand-written.
- **Homarr** tiles come from `homarr.dev/*` annotations; the sync CronJob creates and places tiles but **never deletes** (`PRUNE` off, `PLACE_ITEMS` on).
- **Flux notifications**: `flux-system/alerts.yaml` sends Kustomization/HelmRelease/GitRepository events at `info` severity to Slack via the `slack-webhook-url` secret.

---

## The Hermes Agent Box

`kubernetes/apps/hermes/` is the cluster-hosted agent this repo is often edited from.

- One pod, two s6 services: `gateway` (`args: ["gateway", "run"]`, 8642) and dashboard (`HERMES_DASHBOARD=1`, 9119). `enableServiceLinks: false` because the dashboard Service would otherwise inject a colliding `HERMES_DASHBOARD_PORT`.
- `render-profile-env` init container materialises credential env vars from `hermes-secrets` into `$HERMES_HOME/.env` (keys ending `_API_KEY`, `_TOKEN`, `_ALLOWED_USERS`, `_ALLOW_ALL_USERS`, `_ALLOWED_CHATS`, plus `API_SERVER_KEY`).
- **Tool installation is a separate Job** (`tools-install-job.yaml`, `hermes-tools-install-1`) writing into `/opt/data/.local/bin` on the `hermes-data` PVC: `kubectl`, `jq`, `gh`, `gcloud`/`gsutil`/`bq`, `tofu`. The `wait-for-tools` init container only waits for those binaries — no network calls in the pod's own init path, so a broken download cannot crash-loop the gateway.
- **Not installed by that Job**: `flux`, `helm`, `sops`, `kustomize`, `age`, `ansible`. If a task needs them, extend the Job (bump the Job name suffix — Job specs are immutable) and re-run it, or install ad hoc into `/opt/data/.local/bin`.
- The agent's cluster rights are a dedicated SA (`hermes-agent`) + `view` + read on `httproutes`/`gateways`. It cannot write to the cluster. Changes go through Git.
- Secrets: `hermes-secrets` (model provider keys, `API_SERVER_KEY`, Slack/Telegram/WhatsApp) and `hermes-dashboard-internal-auth`, both SOPS-encrypted under the catch-all rule.

---

## Node, K3s, and CNI Notes

- `cluster/k3s/config.yaml`: `disable: [traefik, servicelb]`, `cluster-cidr 10.42.0.0/16`, `service-cidr 10.43.0.0/16`, `flannel-backend: none`, `disable-network-policy: true`, `write-kubeconfig-mode: 0644`.
- **Never start K3s with `flannel-backend: none` and no CNI already installed** — the node stays `NotReady` and nothing schedules. `cluster/k3s/install-k3s.sh` installs Cilium via Helm *before* Flux exists, using `kubernetes/components/cilium/values.yaml`; the Flux HelmRelease then adopts that release (`valuesFrom` the same file). That file is the single source of truth for Cilium values.
- Cilium: `kubeProxyReplacement: "false"` (kube-proxy keeps Service VIPs), VXLAN tunnel, `k8sServiceHost: 127.0.0.1` (host-network agents, survives the node's WiFi address changing), Hubble relay on, UI off, pod CIDR `10.42.0.0/16` with `/24` per-node masks.
- inotify limits must be raised on the node or Flux/Alloy/ARC-runner pods crash with `failed to create fsnotify watcher: too many open files`:

  ```bash
  sudo sysctl -w fs.inotify.max_user_watches=524288
  sudo sysctl -w fs.inotify.max_user_instances=512
  ```

  See `README.md` for the permanent `/etc/sysctl.conf` version.

---

## Raspberry Pi (Hallon)

`hallon/` manages a Raspberry Pi 3B+ running hardware-dependent services that cannot run in K3s (USB Zigbee radio).

```
Raspberry Pi (hallon)          K3s cluster
┌──────────────────┐          ┌─────────────────┐
│ Zigbee2MQTT      │          │ Mosquitto MQTT  │
│ (Docker)         │──MQTT───>│ 192.168.0.202   │
│ ConBee USB       │          │ Home Assistant  │
│ /dev/ttyACM0     │          │                 │
└──────────────────┘          └─────────────────┘
```

Why a separate Pi: direct USB access to the ConBee stick, 1 GB RAM can't run K3s well, hardware failures stay isolated from the cluster.

- Layout: `ansible/playbook.yml` (installs Docker, creates `/opt/zigbee2mqtt`, deploys the container + systemd unit), `ansible/inventory.yml`, `ansible/group_vars/raspberry_pi.yml` (MQTT host, timezone, device path), `ansible/tasks/led_control.yml`, `docker-compose.yml`, `zigbee2mqtt/configuration.yaml`.
- Deploy: `ansible-playbook -i hallon/ansible/inventory.yml hallon/ansible/playbook.yml`.
- Result: Zigbee2MQTT on the Pi connects to `mqtt.lab:1883` (`192.168.0.202`), web UI on `http://<pi-ip>:8080`, devices auto-discovered by Home Assistant over MQTT.
- Good candidates for the Pi: Bluetooth Proxy, ESPHome dashboard, NUT. Keep databases, media servers, and anything CPU-hungry off it.
- Debug: `ssh pi@<pi-ip>` → `docker ps`, `docker logs zigbee2mqtt`, `sudo systemctl status zigbee2mqtt`, `mosquitto_sub -h mqtt.lab -t 'zigbee2mqtt/#' -v`.

Also outside Flux: `lab/` (e.g. `local-llm/docker-compose.yml`, `qwen.sh`) for experiments, and `docs/` — `plans/` holds approved-before-implementation specs (decision tables, status, target branch) and runbooks capture anything that cannot be expressed declaratively.

---

## Common Patterns Reference

### RBAC for Kubernetes API access

Needed by anything that discovers resources (Gatus reads HTTPRoutes; Homarr reads HTTPRoutes; external-dns writes records):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: my-app, namespace: my-app}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: my-app}
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: my-app}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: my-app}
subjects:
- {kind: ServiceAccount, name: my-app, namespace: my-app}
```

Reference it from a HelmRelease with `serviceAccount: {create: false, name: my-app}`.

### Persistent storage

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: my-app-data, namespace: my-app}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Gi}}
  storageClassName: local-path   # K3s default; single node, so RWO only
```

Reference with `persistence: {enabled: true, existingClaim: my-app-data}`.

### ConfigMap mounted as a file

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: my-app-config, namespace: my-app}
data:
  config.yaml: |
    server:
      port: 8080
```

Reference with `extraVolumes` / `extraVolumeMounts`, or mount with `subPath` when the app wants a single file (see the Unbound sidecar in `pihole/`).

### Env vars from a Secret

```yaml
spec:
  values:
    env:
    - name: API_KEY
      valueFrom:
        secretKeyRef: {name: my-app-secret, key: API_KEY}
```

The Secret itself must be SOPS-encrypted before commit, or supplied by `envFrom: secretRef` as `hermes` does (`hermes-secrets`).

### Sidecar container

```yaml
spec:
  values:
    sidecarContainers:
      helper:
        image: busybox:latest
        command: ["sh", "-c", "while true; do sleep 60; done"]
```

### Dependency order

`dependsOn` in `flux-system/apps/<name>.yaml`; Flux waits for those Kustomizations to be ready. Combine with `healthChecks` when the dependency is a HelmRelease (see `cilium.yaml`, `couchdb.yaml`).

---

## Verifying Changes

Before pushing:

```bash
kustomize build kubernetes/apps/<name> >/dev/null      # renders the bundle
flux build kustomization <name> --path ./kubernetes/apps/<name>   # renders as Flux would
```

After merge / reconcile:

```bash
flux get kustomizations
flux reconcile kustomization <name> --with-source
flux get helmreleases -A
kubectl get pods -n <ns>
kubectl get httproute -n <ns>                  # hostname programmed?
kubectl get certificate -n traefik             # wildcard still valid?
kubectl logs -n external-dns deploy/external-dns | tail
kubectl describe kustomization <name> -n flux-system   # why it failed
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail
```

Pre-PR checklist:

- [ ] New bundle listed in its own `kustomization.yaml` **and** in `flux-system/apps/kustomization.yaml`
- [ ] Chart/image version pinned (or carrying a `# renovate:` annotation)
- [ ] `decryption: sops` present if the bundle ships secrets, and they are actually encrypted
- [ ] `postBuild.substituteFrom: domain-config` present if any manifest uses `${LOCAL_DOMAIN}` / `${BASE_DOMAIN}` / `${ACME_EMAIL}`
- [ ] `dependsOn` limited to what is genuinely required
- [ ] No real domain, public IP, PII, or plaintext secret
- [ ] `networkpolicy.yaml` considered for anything new and exposed

---

## Pitfalls

1. **Unknown `${VAR}` is silently deleted.** Flux blanks every substitution it cannot resolve — including shell variables in inline scripts. Use `$VAR` / `printf`, or escape as `$${VAR}`.
2. **`flux-system/flux-system/gotk-*.yaml` is generated.** `gotk-sync.yaml` says so explicitly; re-bootstrap instead of hand-editing.
3. **Jobs are immutable.** Changing `tools-install-job.yaml` or any `batch/v1` Job requires bumping its `metadata.name` (or deleting it), otherwise the apply fails.
4. **`external-dns` uses `policy: sync`.** Deleting an HTTPRoute deletes its Cloudflare record; competing manual records get pruned.
5. **PiHole `adlists` only seed `gravity.db` on first install** — edit them inside the running pod for later changes.
6. **Homarr sync never deletes** — stale tiles must be removed in the UI.
7. **`encrypted_regex` covers only `data`/`stringData`.** Credentials placed anywhere else (Helm values, a ConfigMap, a `config.yaml` holding a token) are committed in plaintext. Add an explicit `.sops.yaml` rule before doing that.
8. **Notes-stack secrets exclude the agent key by design.** Do not "fix" that by adding the agent recipient; it would let a single compromised agent read the entire vault backup password.
9. **KEDA HTTP needs its ReferenceGrant.** An HTTPScaledObject without a grant in `keda-http/referencegrant.yaml` yields timeouts/502s, not an obvious error.
10. **`.lab` names are LAN-only.** They are manual PiHole entries; they are not Traefik hostnames. Do not use them for new HTTPRoutes.
11. **This repo is public.** Every example in docs and every committed manifest must use `${LOCAL_DOMAIN}`-style substitution or `example.com` / `192.168.0.x` placeholders.

---

## Additional Resources

- **Flux**: https://fluxcd.io/
- **Kubernetes Gateway API**: https://gateway-api.sigs.k8s.io/
- **Traefik + Gateway API**: https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/
- **cert-manager**: https://cert-manager.io/
- **MetalLB**: https://metallb.universe.tf/
- **Cilium**: https://docs.cilium.io/
- **KEDA HTTP add-on**: https://keda.sh/docs/latest/http-add-on/
- **SOPS**: https://getsops.io/

---

**Last Updated**: 2026-10-26 — rewritten against `main` @ `3ecab4f` (Cloudflare/Let's Encrypt edge, Cilium, KEDA, ARC, Grafana Cloud, hermes apps).
