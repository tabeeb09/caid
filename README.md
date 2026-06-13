# CAId

Central Authorization and Identity bootstrap scripts.

This repo is intentionally small. A blank web-connected VPS should be able to clone it and run one script to provision the central CAId stack:

- OpenBao
- Keycloak
- PostgreSQL for Keycloak
- Caddy reverse proxy

The script does not assume Docker is already installed. It installs missing host dependencies, writes the required stack files, pulls public container images, starts the stack, initializes and unseals OpenBao, bootstraps OpenBao policies/AppRole, bootstraps Keycloak clients/roles, and prints the AppRole credentials needed by an app VPS.

## Platform layout

```mermaid
graph LR
  subgraph "External"
    user["User (browser)"]
    gh["GitHub Actions"]
    cf["Cloudflare DNS"]
  end
  subgraph "Cloud Infrastructure"
    caddy["Caddy Proxy<br/>(TLS on 443)"]
    next["Next.js app (Docker)"]
    oauth2["OAuth2 Proxy (admin)"]
    keycloak["Keycloak (OIDC server)"]
    pg["PostgreSQL (Keycloak DB)"]
    openbao["OpenBao (Secret store)"]
    rustfs["RustFS (S3 media storage)"]
  end
  subgraph "CI/CD & Provisioning"
    ghcr["GH Container Registry"]
    runner["Self-hosted Runner"]
    compose["Docker Compose"]
    terraform["Terraform<br/>(Hetzner + cloud-init)"]
    vps["Hetzner VPS"]
  end
  user -->|DNS lookup| cf
  cf -->|resolves to| caddy
  user -->|HTTPS| caddy
  caddy --> next
  caddy --> oauth2
  oauth2 --> openbao
  oauth2 --> keycloak
  keycloak --> pg
  next --> rustfs
  gh --> ghcr
  gh --> runner
  runner --> ghcr
  runner --> compose
  compose --> next
  compose --> keycloak
  compose --> openbao
  compose --> rustfs
  compose --> oauth2
  vps --> caddy
  terraform --> vps
  vps --> runner
  vps --> compose
```

## Blank VPS Quick Start

Minimal curl-based install:

```bash
sudo apt-get update
sudo apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/tabeeb09/caid/main/scripts/setup-caid-vps.sh -o setup-caid-vps.sh
sudo bash setup-caid-vps.sh
```

Git-based install:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/tabeeb09/caid.git
cd caid
sudo bash scripts/setup-caid-vps.sh
```

If you already have the repo checked out and want to rerun convergence or bootstrap logic:

```bash
cd /srv/caid
sudo bash scripts/setup-caid-vps.sh
sudo bash scripts/caid-converge.sh --mode noninteractive
```

The script prompts for:

```text
AUTH_HOST
BAO_HOST
ZTNA_PROVIDER
VPN_CIDR
KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME
APP_PUBLIC_URL
MEDIA_PUBLIC_URL
OAUTH2_PROXY_PUBLIC_URL
RUSTFS_BUCKET
GOOGLE_CLIENT_ID, optional
GOOGLE_CLIENT_SECRET, optional
ALLOWED_EMAILS, optional
DNS_PROVIDER, optional
CLOUDFLARE_ZONE_NAME, if DNS_PROVIDER=cloudflare
CLOUDFLARE_ZONE_ID, optional if DNS_PROVIDER=cloudflare
CLOUDFLARE_API_TOKEN, if DNS_PROVIDER=cloudflare
```

`AUTH_HOST` and `BAO_HOST` must be plain hostnames, not URLs and not `host:port` values.

Good:

```text
auth.example.internal
bao.example.internal
auth.localhost
bao.localhost
```

Bad:

```text
localhost:8080
https://auth.example.internal
```

`ZTNA_PROVIDER` can be:

```text
none
tailscale
netbird
```

If `tailscale` is selected, the script installs Tailscale if missing and prompts for an optional Tailscale auth key. If the key is blank, Tailscale prints its normal browser login URL.

If `netbird` is selected, the script installs NetBird if missing and prompts for an optional setup key and management URL. If the setup key is blank, NetBird uses its interactive login flow where supported.

The overlay choice and setup key are saved in:

```text
/etc/caid/caid.env
```

That file is root-only and reused on later runs. App URL settings and optional provider values are saved there too.

It generates:

```text
KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD
KEYCLOAK_DB_PASSWORD
OpenBao root token
OpenBao unseal key
Keycloak client secrets
OpenBao AppRole credentials
```

It writes the generated and prompted app values into OpenBao paths:

```text
kv/data/website/prod
kv/data/rustfs/prod
kv/data/oauth2-proxy/prod
kv/data/keycloak/prod
kv/data/cloudflare/prod, only when DNS_PROVIDER=cloudflare
```

The Cloudflare token should be scoped to the relevant zone and only needs:

```text
Zone:DNS:Edit
Zone:Zone:Read
```

## Important Recovery Output

On first OpenBao initialization, the script writes:

```text
/etc/caid/openbao-init.json
/etc/caid/OPENBAO-RECOVERY-README.txt
```

Back up `openbao-init.json` offline. It contains the OpenBao root token and unseal key.

## App VPS Output

At the end, the script prints:

```text
BAO_ADDR=https://<BAO_HOST>
OPENBAO_ROLE_ID=...
OPENBAO_SECRET_ID=...
```

Paste those into the app VPS bootstrap script.

## Default Install Paths

```text
/srv/caid       generated compose/config files
/etc/caid       env and OpenBao recovery material
/var/lib/caid   persistent container data
```

## Startup Service

The setup script installs and enables:

```text
caid.service
```

Useful commands:

```bash
sudo systemctl status caid
sudo systemctl restart caid
sudo systemctl stop caid
sudo journalctl -u caid -f
```

The service runs:

```text
docker compose up -d
```

from `/srv/caid`, so OpenBao, Keycloak, Caddy, and Postgres come back after VPS reboot.

OpenBao itself intentionally comes back sealed after an OpenBao process restart unless you configure a separate auto-unseal mechanism. The setup script can unseal it again using `/etc/caid/openbao-init.json`, or you can unseal manually through OpenBao using the saved unseal key. Keep the recovery file offline-backed-up and root-only.

## Admin access

OpenBao is available at:

```text
https://<BAO_HOST>
```

Use the root token from:

```text
/etc/caid/openbao-init.json
```

for first setup or emergency recovery. For normal operation, create narrower admin policies/tokens in OpenBao.

Keycloak is available at:

```text
https://<AUTH_HOST>
```

Log in with the bootstrap admin username you provided to the setup script and the generated password saved in `/etc/caid/caid.env`.

To add a new app manually:

```text
1. Open https://<BAO_HOST>
2. Log in.
3. Go to Secrets -> kv.
4. Create a new path, for example my-new-app/prod.
5. Add the app's key/value secrets.
6. Create a policy allowing read access to that path.
7. Create an AppRole using that policy.
8. Copy the AppRole role_id and secret_id to that app VPS bootstrap.
```

## Non-Interactive Use

You can pass values through environment variables:

```bash
sudo AUTH_HOST=auth.internal.example.com \
  BAO_HOST=bao.internal.example.com \
  ZTNA_PROVIDER=tailscale \
  TAILSCALE_AUTH_KEY=tskey-auth-... \
  VPN_CIDR=10.8.0.0/24 \
  KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME=admin \
  bash scripts/setup-caid-vps.sh
```
