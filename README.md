# CAId

Central Authorization and Identity bootstrap scripts.

This repo is intentionally small. A blank web-connected VPS should be able to clone it and run one script to provision the central CAId stack:

- OpenBao
- Keycloak
- PostgreSQL for Keycloak
- Caddy reverse proxy

The script does not assume Docker is already installed. It installs missing host dependencies, writes the required stack files, pulls public container images, starts the stack, initializes and unseals OpenBao, bootstraps OpenBao policies/AppRole, bootstraps Keycloak clients/roles, and prints the AppRole credentials needed by an app VPS.

## Blank VPS Quick Start

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/tabeeb09/caid.git
cd caid
sudo bash scripts/setup-caid-vps.sh
```

The script prompts for:

```text
AUTH_HOST
BAO_HOST
ZTNA_PROVIDER
VPN_CIDR
KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME
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

That file is root-only and reused on later runs.

It generates:

```text
KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD
KEYCLOAK_DB_PASSWORD
OpenBao root token
OpenBao unseal key
Keycloak client secrets
OpenBao AppRole credentials
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
