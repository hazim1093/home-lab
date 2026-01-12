# Home Lab Repository Documentation

> **Purpose**: This document explains the home-lab repository structure, component organization, and deployment patterns to help you understand and extend the infrastructure.

## Table of Contents
- [Repository Overview](#repository-overview)
- [Directory Structure](#directory-structure)
- [Component Architecture](#component-architecture)
- [How Components Are Linked](#how-components-are-linked)
- [Adding a New Component/App](#adding-a-new-componentapp)
- [Secrets Management](#secrets-management)
- [Service Exposure Patterns](#service-exposure-patterns)
- [DNS and Networking](#dns-and-networking)
- [Certificate Management](#certificate-management)
- [Common Patterns Reference](#common-patterns-reference)

---

## Repository Overview

This is a **GitOps-based Kubernetes home lab** using:
- **K3s** - Lightweight Kubernetes distribution
- **Flux CD** - GitOps continuous delivery
- **Traefik** - Kubernetes Gateway API ingress controller
- **MetalLB** - Bare metal load balancer
- **Mosquitto** - MQTT broker for IoT devices
- **PiHole + Unbound** - DNS filtering and recursive resolution
- **cert-manager** - TLS certificate management
- **SOPS** - Secrets encryption with age

**Hybrid Architecture**: K3s cluster handles core services, with Raspberry Pi running hardware-dependent services (Zigbee2MQTT) via Docker, managed through Ansible.

**Key Principle**: Everything is declarative. All infrastructure and applications are defined in YAML and automatically deployed by Flux or Ansible. Secrets are encrypted with SOPS before being committed to Git.

---

## Directory Structure

```
home-lab/
├── kubernetes/
│   ├── bootstrap/flux/              # Terraform/OpenTofu Flux bootstrap
│   │   ├── main.tf
│   │   ├── provider.tf
│   │   └── backend.tf               # Cloudflare R2 state backend
│   └── components/                  # All Kubernetes applications
│       ├── flux-system/             # Flux core + orchestration
│       │   ├── repos/               # HelmRepository definitions
│       │   ├── apps/                # Kustomization resources for apps
│       │   ├── gotk-components.yaml # Flux controllers
│       │   └── gotk-sync.yaml       # Git sync config
│       ├── traefik/                 # Ingress controller
│       ├── cert-manager/            # Certificate management
│       ├── certificates/            # Root CA + wildcard cert
│       ├── metallb/                 # Load balancer
│       ├── metallb-config/          # IP pool + L2 advertisement
│       ├── mosquitto/               # MQTT broker
│       ├── pihole/                  # DNS filtering
│       ├── home-assistant/          # Home automation
│       ├── rustdesk/                # Remote desktop
│       ├── gatus/                   # Health monitoring
│       ├── external-dns/            # Automatic DNS management
│       └── renovate/                # Dependency updates
├── hallon/                          # Raspberry Pi management
│   ├── ansible/                     # Ansible automation
│   │   ├── playbook.yml             # Pi setup playbook
│   │   ├── inventory.yml            # Pi host configuration
│   │   └── group_vars/              # Configuration variables
│   ├── docker-compose.yml           # Zigbee2MQTT container
│   ├── zigbee2mqtt/                 # Zigbee2MQTT configuration
│   └── README.md                    # Pi setup documentation
├── cluster/
│   └── k3s/config.yaml              # K3s server configuration
├── .github/workflows/
│   └── secret-scan.yml              # Gitleaks security scanning
└── renovate.json                    # Renovate config
```

---

## Component Architecture

### Standard Component Structure

Each component follows this pattern:

```
/kubernetes/components/<app-name>/
├── namespace.yaml              # Namespace definition
├── helmrelease.yaml            # Helm chart deployment
├── kustomization.yaml          # Kustomize manifest
├── httproute.yaml              # (Optional) Gateway API route
├── configmap.yaml              # (Optional) Configuration
├── rbac.yaml                   # (Optional) ServiceAccount + RBAC
├── pvc.yaml                    # (Optional) Persistent storage
└── certificate.yaml            # (Optional) Custom certificates
```

### Example Component Files

**namespace.yaml**:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```

**helmrelease.yaml**:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta2
kind: HelmRelease
metadata:
  name: my-app
  namespace: my-app
spec:
  interval: 12h
  chart:
    spec:
      chart: my-app-chart
      version: "1.2.3"
      sourceRef:
        kind: HelmRepository
        name: my-repo
        namespace: flux-system
  values:
    # Application-specific configuration
    service:
      type: ClusterIP
      port: 80
```

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
  - httproute.yaml
```

---

## How Components Are Linked

### The Deployment Flow

```
GitHub Repository (main branch)
    ↓
Flux GitRepository (watches repository)
    ↓
Flux Kustomization (applies /kubernetes/components/flux-system)
    ├→ repos/ (HelmRepository definitions)
    │   ├── jetstack.yaml (cert-manager charts)
    │   ├── traefik.yaml (traefik charts)
    │   ├── metallb.yaml (metallb charts)
    │   └── ...
    └→ apps/ (Application Kustomizations)
        ├── cert-manager.yaml → /kubernetes/components/cert-manager/
        ├── traefik.yaml → /kubernetes/components/traefik/
        ├── pihole.yaml → /kubernetes/components/pihole/
        └── ...
```

### 1. Helm Repository Registration

**Location**: `/kubernetes/components/flux-system/repos/`

**Example** (`repos/traefik.yaml`):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 12h
  url: https://traefik.github.io/charts
```

**Purpose**: Defines external Helm chart repositories that Flux can pull charts from.

### 2. App Kustomization (Orchestration Layer)

**Location**: `/kubernetes/components/flux-system/apps/`

**Example** (`apps/traefik.yaml`):
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v2
kind: Kustomization
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/components/traefik
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-lab
  wait: true
  dependsOn:
    - name: cert-manager  # Wait for cert-manager first
```

**Purpose**:
- Points to the actual component directory
- Manages dependencies (e.g., Traefik waits for cert-manager)
- Controls when and how resources are applied

### 3. Component Kustomization

**Location**: `/kubernetes/components/<app-name>/kustomization.yaml`

**Example**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
  - httproute.yaml
```

**Purpose**: Lists all YAML files that make up the component.

### 4. HelmRelease (Actual Deployment)

**Location**: `/kubernetes/components/<app-name>/helmrelease.yaml`

**Purpose**:
- References the HelmRepository (from step 1)
- Specifies chart version
- Provides configuration values
- Flux automatically deploys and updates based on this

### Linking Summary

```
HelmRepository (flux-system/repos/)
    ↓ referenced by
HelmRelease (components/<app>/helmrelease.yaml)
    ↓ included in
Component Kustomization (components/<app>/kustomization.yaml)
    ↓ pointed to by
App Kustomization (flux-system/apps/<app>.yaml)
    ↓ applied by
Flux System Kustomization (flux-system/kustomization.yaml)
```

---

## Adding a New Component/App

### Step-by-Step Guide

#### Step 1: Create Component Directory

```bash
mkdir -p kubernetes/components/my-new-app
cd kubernetes/components/my-new-app
```

#### Step 2: Create Namespace

Create `namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-new-app
```

#### Step 3: Add Helm Repository (if needed)

If using a new Helm repository, create `flux-system/repos/my-repo.yaml`:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: my-repo
  namespace: flux-system
spec:
  interval: 12h
  url: https://charts.example.com
```

Then add to `flux-system/repos/kustomization.yaml`:
```yaml
resources:
  # ... existing repos
  - my-repo.yaml
```

#### Step 4: Create HelmRelease

Create `helmrelease.yaml`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta2
kind: HelmRelease
metadata:
  name: my-new-app
  namespace: my-new-app
spec:
  interval: 12h
  chart:
    spec:
      chart: my-app-chart
      version: "1.0.0"  # Pin explicit version
      sourceRef:
        kind: HelmRepository
        name: my-repo
        namespace: flux-system
  values:
    # Your configuration here
    service:
      type: ClusterIP
      port: 8080
```

#### Step 5: Create Component Kustomization

Create `kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

#### Step 6: Create App Kustomization

Create `flux-system/apps/my-new-app.yaml`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v2
kind: Kustomization
metadata:
  name: my-new-app
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/components/my-new-app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-lab
  wait: true
  # Optional: Add dependencies
  # dependsOn:
  #   - name: cert-manager
```

Then add to `flux-system/apps/kustomization.yaml`:
```yaml
resources:
  # ... existing apps
  - my-new-app.yaml
```

#### Step 7: Commit and Push

```bash
git add kubernetes/components/my-new-app/
git add kubernetes/components/flux-system/
git commit -m "Add my-new-app component"
git push
```

Flux will automatically detect and deploy within ~1 minute.

#### Step 8: Verify Deployment

```bash
# Check Flux reconciliation
flux get kustomizations

# Check HelmRelease status
flux get helmreleases -n my-new-app

# Check pods
kubectl get pods -n my-new-app
```

---

## Secrets Management

All secrets are encrypted using **SOPS** (Secrets OPerationS) with **age** encryption before being committed to Git. Flux automatically decrypts them when deploying to the cluster.

### Encryption Setup

```bash
# Restore age key from backup to .age/key.txt
# Deploy key to cluster for Flux
cat .age/key.txt | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin
```

### Working with Secrets

```bash
# Set key location
export SOPS_AGE_KEY_FILE=.age/key.txt

# Encrypt a secret file
sops --encrypt --in-place kubernetes/components/my-app/secret.yaml

# Edit encrypted secret (auto decrypt/encrypt)
sops kubernetes/components/my-app/secret.yaml
```

### Flux Decryption

Add to any Kustomization that deploys encrypted secrets:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

**Age public key**: `age1s84t0ws8cpp8ujf8mny373gg63g9d52fezrdwe24jdfe4d309pwqvawpcu`

**Configuration**: `.sops.yaml` encrypts `data` and `stringData` fields only

---

## Service Exposure Patterns

### Pattern 1: HTTP/HTTPS Web Interface (Gateway API)

**Use Case**: Web applications that need to be accessible via browser

**Example**: PiHole, Home Assistant, Gatus

**Configuration**:

1. Create `httproute.yaml` in your component:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
  annotations:
    # Optional: Enable Gatus health monitoring
    gatus.home-operations.com/enabled: "true"
    gatus.home-operations.com/endpoint: |
      url: "http://my-app.my-app.svc.cluster.local:8080"
      interval: 60s
      conditions:
        - "[STATUS] == 200"
spec:
  parentRefs:
  - name: traefik-gateway      # Reference to Traefik Gateway
    namespace: traefik
    sectionName: web           # Use 'websecure' for HTTPS
  hostnames:
  - "myapp.lab"                # Use .lab domain convention
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app             # Service name
      port: 8080
```

2. Add DNS entry in PiHole:
```yaml
# In pihole/helmrelease.yaml values
customDnsEntries:
  - address=/myapp.lab/192.168.0.200  # Traefik LoadBalancer IP
```

3. Add to component kustomization:
```yaml
resources:
  - namespace.yaml
  - helmrelease.yaml
  - httproute.yaml
```

**Result**: Accessible at `http://myapp.lab` (auto-redirects to HTTPS)

### Pattern 2: LoadBalancer with Static IP

**Use Case**: Services that need dedicated IP addresses (DNS servers, non-HTTP protocols)

**Example**: RustDesk, PiHole DNS

**Configuration**:

In `helmrelease.yaml`:
```yaml
spec:
  values:
    service:
      type: LoadBalancer
      loadBalancerIP: "192.168.0.205"  # Choose from MetalLB pool
      externalTrafficPolicy: Local     # Preserve source IP
      ports:
        app:
          port: 8080
          targetPort: 8080
```

**Available IP Range**: `192.168.0.200-192.168.0.210` (configured in metallb-config)

**IP Assignments**:
- `192.168.0.200` - Traefik (ingress)
- `192.168.0.201` - PiHole DNS
- `192.168.0.202` - Mosquitto MQTT
- `192.168.0.203` - RustDesk
- `192.168.0.204-210` - Available

### Pattern 3: ClusterIP (Internal Only)

**Use Case**: Services only accessible from within the cluster

**Example**: Internal databases, caches

**Configuration**:
```yaml
spec:
  values:
    service:
      type: ClusterIP
      port: 5432
```

**Access**: Only via `<service-name>.<namespace>.svc.cluster.local:<port>`

---

## Raspberry Pi Setup (Hallon)

### Overview

The `hallon/` directory manages Raspberry Pi 3B+ running hardware-dependent services that cannot run in k8s (USB devices, Zigbee radios, etc.).

**Architecture**:
```
Raspberry Pi (hallon)          K3s Cluster
┌──────────────────┐          ┌─────────────────┐
│ Zigbee2MQTT      │          │ Mosquitto MQTT  │
│ (Docker)         │──MQTT───>│ (192.168.0.202) │
│                  │          │                 │
│ ConBee USB ──────┤          │ Home Assistant  │
│ /dev/ttyACM0     │          │                 │
└──────────────────┘          └─────────────────┘
```

### Why Separate Pi?

- **USB device access**: ConBee Zigbee stick requires direct USB access
- **Resource efficiency**: Pi 3B+ (1GB RAM) can't run k3s efficiently
- **Simplicity**: Direct Docker deployment, no k8s overhead
- **Reliability**: Hardware failures isolated from cluster

### Directory Structure

```
hallon/
├── ansible/
│   ├── playbook.yml              # Automated Pi setup
│   ├── inventory.yml             # Pi host configuration
│   └── group_vars/
│       └── raspberry_pi.yml      # Configuration variables
├── docker-compose.yml            # Zigbee2MQTT container
├── zigbee2mqtt/
│   └── configuration.yaml        # Zigbee2MQTT config template
└── README.md                     # Full setup documentation
```

### Deployment Process

**One-time setup**:
1. Edit `ansible/inventory.yml` with Pi's IP address
2. Edit `ansible/group_vars/raspberry_pi.yml` if needed (timezone, etc.)
3. Run: `ansible-playbook -i ansible/inventory.yml ansible/playbook.yml`

**What Ansible does**:
- Installs Docker and Docker Compose
- Creates `/opt/zigbee2mqtt/` directory structure
- Deploys Zigbee2MQTT container configuration
- Creates systemd service for auto-start on boot
- Configures timezone and system settings

**Result**:
- Zigbee2MQTT running on Pi, connecting to `mqtt.lab` (192.168.0.202)
- Web UI accessible at `http://<pi-ip>:8080`
- Devices automatically discovered by Home Assistant via MQTT

### Services on Pi

**Currently Running**:
- **Zigbee2MQTT**: Bridges Zigbee devices (via ConBee) to MQTT broker

**Good Candidates for Pi**:
- Bluetooth Proxy for Home Assistant (very lightweight)
- ESPHome Dashboard (if using ESP32/ESP8266 devices)
- Network UPS Tools (if Pi on UPS)

**Avoid on Pi**:
- Heavy services (databases, media servers)
- Anything better suited for k8s cluster
- Services with high CPU usage

### Configuration Management

**Infrastructure as Code**:
- Pi configuration is managed via Ansible (declarative)
- Docker Compose defines containers (version-controlled)
- Changes pushed to Git, then re-run playbook to update

**Key Configuration Files**:
- `ansible/group_vars/raspberry_pi.yml`: MQTT host, timezone, device paths
- `zigbee2mqtt/configuration.yaml`: Zigbee network, MQTT connection, frontend

### Integration with K3s

**MQTT Broker (Mosquitto)**:
- Runs in k8s cluster (`mqtt` namespace)
- Static IP: 192.168.0.202 (MetalLB LoadBalancer)
- DNS: mqtt.lab (configured in PiHole)
- Pi connects to cluster via `mqtt.lab:1883`

**Home Assistant**:
- Runs in k8s cluster
- Auto-discovers Zigbee devices via MQTT integration
- No direct Pi access required

### Troubleshooting

**Check Pi services**:
```bash
ssh pi@<pi-ip>
docker ps                           # Check running containers
docker logs zigbee2mqtt             # View logs
sudo systemctl status zigbee2mqtt  # Check systemd service
```

**Test MQTT connection**:
```bash
# From Pi
mosquitto_sub -h mqtt.lab -t 'zigbee2mqtt/#' -v
```

**Re-deploy configuration**:
```bash
# From local machine
ansible-playbook -i hallon/ansible/inventory.yml hallon/ansible/playbook.yml
```

### Documentation

Full setup instructions and troubleshooting: `hallon/README.md`

---

## DNS and Networking

### DNS Flow

```
Client Query (e.g., "myapp.lab")
    ↓
PiHole (192.168.0.201)
    ├→ Blocklists check
    ├→ Custom DNS entries check
    │   └→ Returns 192.168.0.200 (Traefik)
    └→ Unbound (recursive resolver)
        └→ Authoritative DNS servers

Client connects to 192.168.0.200 (Traefik)
    ↓
Traefik Gateway (matches HTTPRoute)
    ↓
Backend Service
```

### PiHole Configuration

**Location**: `kubernetes/components/pihole/helmrelease.yaml`

**Custom DNS Entries**:
```yaml
customDnsEntries:
  - address=/homeassistant.lab/192.168.0.200
  - address=/pihole.lab/192.168.0.200
  - address=/rustdesk.lab/192.168.0.203
  - address=/gatus.lab/192.168.0.200
  - address=/mqtt.lab/192.168.0.202
```

**To Add a New DNS Entry**:
1. Edit `pihole/helmrelease.yaml`
2. Add line: `- address=/<hostname>.lab/<ip-address>`
3. Commit and push
4. Flux will reconcile automatically

### External-DNS (Automatic DNS Management)

**Location**: `kubernetes/components/external-dns/`

**What it does**:
- Watches for HTTPRoute resources
- Automatically creates DNS entries in PiHole
- Only manages `.lab` domain

**How to use**:
1. Create HTTPRoute with hostname `myapp.lab`
2. External-DNS automatically adds DNS entry
3. No manual PiHole configuration needed

**Example annotation** (optional override):
```yaml
annotations:
  external-dns.alpha.kubernetes.io/hostname: "myapp.lab"
```

### Traefik Gateway Configuration

**Location**: `kubernetes/components/traefik/helmrelease.yaml`

**Listeners**:
- `web` (port 8000) - HTTP, auto-redirects to HTTPS
- `websecure` (port 8443) - HTTPS with TLS termination

**TLS Certificate**: Uses `internal-wildcard-cert` (*.lab)

**Gateway Reference Pattern**:
```yaml
parentRefs:
- name: traefik-gateway
  namespace: traefik
  sectionName: websecure  # or 'web' for HTTP
```

---

## Certificate Management

### PKI Hierarchy

```
selfsigned-issuer (ClusterIssuer)
    ↓ creates
internal-ca (Certificate, 10-year validity)
    ↓ used by
internal-ca-issuer (ClusterIssuer)
    ↓ issues
internal-wildcard-cert (*.lab + .lab, 1-year validity)
    ↓ used by
Traefik Gateway (TLS termination)
```

### Certificate Locations

**Root CA**: `kubernetes/components/certificates/internal-ca.yaml`
```yaml
spec:
  isCA: true
  commonName: internal-ca
  duration: 87600h  # 10 years
  renewBefore: 720h # 30 days
```

**Wildcard Cert**: `kubernetes/components/certificates/internal-wildcard-cert.yaml`
```yaml
spec:
  dnsNames:
    - "*.lab"
    - "lab"
  duration: 8760h   # 1 year
  renewBefore: 720h # Renew 30 days before expiry
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
```

### Using Certificates

**For Traefik** (already configured):
```yaml
certificateRefs:
- name: internal-wildcard-cert
  namespace: traefik
```

**For Custom Service**:
```yaml
spec:
  tls:
  - secretName: internal-wildcard-cert
    hosts:
    - "*.lab"
```

### Trust the Root CA

To avoid browser warnings:
1. Extract CA cert: `kubectl get secret internal-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > internal-ca.crt`
2. Import to system/browser trust store
3. All `.lab` certificates will be trusted

---

## Common Patterns Reference

### Pattern: Add RBAC for Kubernetes API Access

**Use Case**: App needs to read/write Kubernetes resources

**Example**: Gatus (reads HTTPRoutes), External-DNS (reads HTTPRoutes, writes to PiHole)

**Files**:

`rbac.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  namespace: my-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: my-app
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-app
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: my-app
subjects:
- kind: ServiceAccount
  name: my-app
  namespace: my-app
```

Reference in HelmRelease:
```yaml
spec:
  values:
    serviceAccount:
      create: false
      name: my-app
```

### Pattern: Add Persistent Storage

**Use Case**: App needs to persist data across restarts

**Example**: RustDesk, Home Assistant

**Files**:

`pvc.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
  namespace: my-app
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path  # K3s default
```

Reference in HelmRelease:
```yaml
spec:
  values:
    persistence:
      enabled: true
      existingClaim: my-app-data
```

### Pattern: Add ConfigMap

**Use Case**: External configuration files

**Example**: Unbound configuration for PiHole

**Files**:

`configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
  namespace: my-app
data:
  config.yaml: |
    server:
      port: 8080
      host: 0.0.0.0
```

Reference in HelmRelease:
```yaml
spec:
  values:
    extraVolumes:
    - name: config
      configMap:
        name: my-app-config
    extraVolumeMounts:
    - name: config
      mountPath: /config
      readOnly: true
```

### Pattern: Add Sidecar Container

**Use Case**: Additional utility running alongside main app

**Example**: Gatus sidecar for HTTPRoute discovery

**Configuration**:
```yaml
spec:
  values:
    sidecarContainers:
      helper:
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          while true; do
            echo "Helper running"
            sleep 60
          done
```

### Pattern: Environment Variables from Secrets

**Use Case**: Pass sensitive data to application

**Files**:

Create secret (manually or via Sealed Secrets/SOPS):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
  namespace: my-app
type: Opaque
stringData:
  API_KEY: "my-secret-key"
  DB_PASSWORD: "super-secret"
```

Reference in HelmRelease:
```yaml
spec:
  values:
    env:
    - name: API_KEY
      valueFrom:
        secretKeyRef:
          name: my-app-secret
          key: API_KEY
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: my-app-secret
          key: DB_PASSWORD
```

### Pattern: Configure Dependency Order

**Use Case**: App requires another component to be ready first

**Example**: Traefik depends on cert-manager

**Configuration**:

In `flux-system/apps/my-app.yaml`:
```yaml
spec:
  dependsOn:
    - name: cert-manager
    - name: traefik
```

Flux will wait for dependencies to be ready before deploying.

### Pattern: Health Checks with Gatus

**Use Case**: Monitor service availability

**Configuration**:

In `httproute.yaml`:
```yaml
metadata:
  annotations:
    gatus.home-operations.com/enabled: "true"
    gatus.home-operations.com/endpoint: |
      url: "http://my-app.my-app.svc.cluster.local:8080/health"
      interval: 60s
      conditions:
        - "[STATUS] == 200"
        - "[RESPONSE_TIME] < 500"
```

View at: `https://gatus.lab`

---

## Troubleshooting Commands

### Check Flux Status
```bash
# Overall status
flux get all

# Specific component
flux get kustomizations my-app
flux get helmreleases -n my-app

# Reconcile manually (force update)
flux reconcile kustomization my-app
flux reconcile helmrelease my-app -n my-app
```

### Check Application Status
```bash
# Pods
kubectl get pods -n my-app

# Logs
kubectl logs -n my-app deployment/my-app

# Describe (events and issues)
kubectl describe helmrelease my-app -n my-app
```

### Check Networking
```bash
# Services and endpoints
kubectl get svc -n my-app
kubectl get endpoints -n my-app

# HTTPRoutes
kubectl get httproute -n my-app

# Gateway status
kubectl get gateway -n traefik
```

### Check DNS
```bash
# From within cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup myapp.lab

# From host (if PiHole is DNS server)
nslookup myapp.lab 192.168.0.201
```

### Check Certificates
```bash
# Certificate status
kubectl get certificate -n cert-manager

# Certificate details
kubectl describe certificate internal-wildcard-cert -n traefik

# Check secret
kubectl get secret internal-wildcard-cert -n traefik -o yaml
```

---

## Quick Reference

### Common File Locations
- **Flux core**: `kubernetes/components/flux-system/`
- **Helm repos**: `kubernetes/components/flux-system/repos/`
- **App orchestration**: `kubernetes/components/flux-system/apps/`
- **Components**: `kubernetes/components/<app-name>/`
- **Certificates**: `kubernetes/components/certificates/`

### Naming Conventions
- **Namespaces**: Same as component name (e.g., `my-app`)
- **Hostnames**: `<app-name>.lab`
- **Services**: `<app-name>` or chart default
- **HelmRelease**: Same as component name
- **Kustomization**: Same as component name

### IP Allocations
- **Traefik**: `192.168.0.200`
- **PiHole DNS**: `192.168.0.201`
- **Mosquitto MQTT**: `192.168.0.202`
- **RustDesk**: `192.168.0.203`
- **Available**: `192.168.0.204-210`

### Domain Structure
- **Internal domain**: `.lab`
- **Wildcard cert**: `*.lab` + `lab`
- **DNS managed by**: PiHole + External-DNS

### Key Dependencies
1. **cert-manager** → certificates
2. **certificates** → traefik (TLS)
3. **metallb** + **metallb-config** → LoadBalancer services
4. **traefik** → HTTPRoutes (ingress)

---

## Additional Resources

- **Flux Documentation**: https://fluxcd.io/
- **Kubernetes Gateway API**: https://gateway-api.sigs.k8s.io/
- **Traefik Gateway API**: https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/
- **cert-manager**: https://cert-manager.io/
- **MetalLB**: https://metallb.universe.tf/

---

**Last Updated**: 2026-01-07
