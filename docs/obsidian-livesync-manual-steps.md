# Obsidian LiveSync — manual steps, in order

Everything here is work that **cannot** be done by Flux, plus the client-side setup. Do it in this order; several steps block later ones.

Design: [`docs/superpowers/specs/2026-09-19-obsidian-livesync-couchdb-design.md`](superpowers/specs/2026-09-19-obsidian-livesync-couchdb-design.md)

Placeholders used below: `<TAILNET>` = your tailnet name (e.g. `tailxxxx.ts.net`), `<ADMIN_PW>` / `<LIVESYNC_PW>` = values from the SOPS secret, `<VAULT_DB>` = the CouchDB database name you choose (e.g. `obsidian`).

---

## Before anything is deployed

### 1. Record the E2EE passphrase — do this first

Choose your LiveSync end-to-end encryption passphrase now and **save it in your password manager**.

If you lose it, every note in CouchDB becomes permanently unreadable. The spec-2 Cryptomator backup does *not* protect you from this, because that backup holds the decrypted vault, which only exists while some client can still decrypt.

### 2. Tailscale ACL — tag owners

Tailscale admin console → **Access controls**. Add:

```json
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s":          ["tag:k8s-operator"]
}
```

The operator cannot create proxy devices without this. Skipping it is the single most common cause of "the Ingress deployed but no device ever appeared".

### 3. Enable MagicDNS and HTTPS Certificates

Admin console → **DNS**. Turn on **MagicDNS**, then **HTTPS Certificates**.

Without HTTPS Certificates there is no `ts.net` TLS certificate, and the whole "clean https URL on iOS" design falls apart.

### 4. Create the OAuth client

Admin console → **Settings → OAuth clients → Generate OAuth client**.

- Scopes: **Devices Core** (write) and **Auth Keys** (write)
- Tag: `tag:k8s-operator`

Copy the client ID and secret — the secret is shown only once.

### 5. Paste the OAuth credentials into the encrypted secret

The file already exists with placeholders and is already SOPS-encrypted.

```bash
cd ~/own/github/home-lab
export SOPS_AGE_KEY_FILE=.age/key.txt
sops kubernetes/components/tailscale-operator/secret.yaml
```

Replace `<PASTE_TAILSCALE_OAUTH_CLIENT_ID>` and `<PASTE_TAILSCALE_OAUTH_CLIENT_SECRET>`. Saving re-encrypts automatically.

### 6. Read the CouchDB credentials

Already generated and encrypted. To read them when you need them:

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
sops --decrypt kubernetes/apps/couchdb/secret.yaml
```

Contains `adminUsername`, `adminPassword`, `cookieAuthSecret`, `erlangCookie`, `livesyncUsername`, `livesyncPassword`.

---

## After Flux deploys the operator

### 7. Confirm the operator is live

```bash
kubectl get pods -n tailscale
```

Then check the Tailscale admin console → **Machines** for a device named `tailscale-operator`.

If it is not there, revisit steps 2 and 4 — the ACL tags and the OAuth scopes.

---

## After Flux deploys CouchDB

### 8. Confirm CouchDB came up and set itself up

```bash
kubectl get pods -n couchdb
kubectl get jobs -n couchdb          # the autoSetup job should be Complete
```

The job creates `_users`, `_replicator` and `_global_changes`. LiveSync will not work without them.

### 9. Confirm the tailnet device and certificate

```bash
kubectl get pods -n tailscale        # a proxy pod for couchdb should appear
```

Admin console → **Machines** should now show a `couchdb` device. The certificate can take a minute or two after first request.

From any device on your tailnet:

```bash
curl -u admin:<ADMIN_PW> https://couchdb.<TAILNET>/_up
```

Expect `{"status":"ok", ...}`. A certificate error means step 3 was skipped. A 401 without credentials is correct and expected.

### 10. Create the database, the user, and the permissions

Run these from a tailnet device. Use `<ADMIN_PW>` and `<LIVESYNC_PW>` from step 6.

```bash
# Create the notes database
curl -X PUT -u admin:<ADMIN_PW> \
  https://couchdb.<TAILNET>/<VAULT_DB>

# Create the non-admin user Obsidian will use
curl -X PUT -u admin:<ADMIN_PW> \
  -H "Content-Type: application/json" \
  -d '{"name":"livesync","password":"<LIVESYNC_PW>","roles":[],"type":"user"}' \
  https://couchdb.<TAILNET>/_users/org.couchdb.user:livesync

# Grant that user access to just this database
curl -X PUT -u admin:<ADMIN_PW> \
  -H "Content-Type: application/json" \
  -d '{"admins":{"names":[],"roles":[]},"members":{"names":["livesync"],"roles":[]}}' \
  https://couchdb.<TAILNET>/<VAULT_DB>/_security

# Verify the livesync user can reach the database, and only it
curl -u livesync:<LIVESYNC_PW> https://couchdb.<TAILNET>/<VAULT_DB>
```

Do **not** put the admin credentials into Obsidian. The admin account stays for Fauxton and maintenance only.

---

## Client setup

### 11. Desktop Obsidian first

Set up the desktop **before** the phone. It is far easier to configure, and it becomes your only backup until spec 2 lands.

1. Install the **Self-hosted LiveSync** community plugin and enable it.
2. In its settings, configure the remote database:
   - URI: `https://couchdb.<TAILNET>`
   - Database name: `<VAULT_DB>`
   - Username: `livesync`
   - Password: `<LIVESYNC_PW>`
3. Enable **End-to-End Encryption** and enter the passphrase from step 1.
4. Enable **Path Obfuscation**.
5. Run the plugin's connection/configuration check, then let it do the initial sync.

Exact setting labels vary between plugin versions — the four things that matter are the remote URI, E2EE on, Path Obfuscation on, and the non-admin credentials.

**Enable E2EE and Path Obfuscation at initial setup, before writing notes.** Turning either on later requires rebuilding the remote database and re-syncing every client.

### 12. iPhone, via setup URI

In desktop LiveSync settings, use **Copy setup URI**. It bundles URL, database name, credentials and passphrase into one encrypted string protected by a passphrase you choose.

On the iPhone: install Obsidian, install Self-hosted LiveSync, open the setup URI, enter that passphrase.

Retyping settings by hand on a phone is the other common failure source. Use the URI.

### 13. Acceptance test

1. Create a note on the desktop. Open Obsidian on the iPhone **over cellular, with Wi-Fi off**. The note should appear.
2. Edit it on the phone, confirm the change lands on the desktop.
3. Open Fauxton at `https://couchdb.<TAILNET>/_utils` (log in as admin), open `<VAULT_DB>`, and look at a document.

Step 3 is the real test: **the document body must be unreadable ciphertext.** If you can read your note text there, E2EE is not actually on — stop and fix it before writing anything real.

---

## Ongoing

- **Keep a desktop client syncing.** Until spec 2, the PVC is on a single disk with no backup, and each LiveSync client is a full copy of the vault. A phone-only setup means one disk failure away from total loss.
- Watch database size in Grafana. LiveSync accumulates revisions; CouchDB compaction is the remedy.
- Never change `couchdbConfig.couchdb.uuid` in the HelmRelease. Changing it forces every client to re-replicate from scratch.
