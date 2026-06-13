#!/usr/bin/env bash
set -euo pipefail

CAID_HOME="${CAID_HOME:-/srv/caid}"
CAID_STATE_DIR="${CAID_STATE_DIR:-/etc/caid}"
CAID_DATA_DIR="${CAID_DATA_DIR:-/var/lib/caid}"
ENV_FILE="${ENV_FILE:-$CAID_STATE_DIR/caid.env}"
RECOVERY_FILE="${RECOVERY_FILE:-$CAID_STATE_DIR/openbao-init.json}"
RECOVERY_README="${RECOVERY_README:-$CAID_STATE_DIR/OPENBAO-RECOVERY-README.txt}"

OPENBAO_IMAGE="${OPENBAO_IMAGE:-openbao/openbao:2.3.1}"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.2}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.9-alpine}"

KEYCLOAK_REALM="${KEYCLOAK_REALM:-website}"
APPROLE_NAME="${APPROLE_NAME:-website-vps}"
APP_POLICY_NAME="${APP_POLICY_NAME:-website-runtime}"
BAO_KV_MOUNT="${BAO_KV_MOUNT:-kv}"
ZTNA_PROVIDER="${ZTNA_PROVIDER:-}"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root, for example: sudo bash scripts/setup-caid-vps.sh" >&2
    exit 1
  fi
}

random_b64url() {
  local bytes="${1:-32}"
  openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '=\n'
}

prompt_if_missing() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-false}"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    return
  fi

  if [[ ! -t 0 && -n "$default" ]]; then
    printf -v "$var_name" '%s' "$default"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "$var_name is required but no value was provided and stdin is not interactive." >&2
    exit 1
  fi

  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt" current
    echo
  elif [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " current
    current="${current:-$default}"
  else
    read -r -p "$prompt: " current
  fi

  printf -v "$var_name" '%s' "$current"
}

prompt_optional_if_unset() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-false}"

  if [[ "${!var_name+x}" == "x" ]]; then
    return
  fi

  prompt_if_missing "$var_name" "$prompt" "$default" "$secret"
}

validate_plain_hostname() {
  local var_name="$1"
  local value="${!var_name:-}"

  if [[ -z "$value" ]]; then
    echo "$var_name is required." >&2
    exit 1
  fi

  if [[ "$value" == *"://"* || "$value" == *"/"* || "$value" == *":"* ]]; then
    echo "$var_name must be a plain hostname, not a URL or host:port value: $value" >&2
    echo "Example: auth.example.internal, bao.example.internal, auth.localhost, or bao.localhost" >&2
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  else
    echo "Unsupported Linux package manager. Install Docker, Docker Compose plugin, curl, git, openssl, and node manually." >&2
    exit 1
  fi
}

install_missing_dependencies() {
  local manager
  manager="$(detect_pkg_manager)"

  if command -v curl >/dev/null 2>&1 &&
    command -v git >/dev/null 2>&1 &&
    command -v openssl >/dev/null 2>&1 &&
    command -v node >/dev/null 2>&1 &&
    command -v docker >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1; then
    return
  fi

  case "$manager" in
    apt)
      apt-get update
      apt-get install -y ca-certificates curl git openssl nodejs ufw
      ;;
    dnf)
      dnf install -y ca-certificates curl git openssl nodejs ufw ||
        dnf install -y ca-certificates curl git openssl nodejs
      ;;
    yum)
      yum install -y ca-certificates curl git openssl nodejs
      ;;
  esac

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Installing Docker Engine and Compose plugin from Docker's official installer..."
    curl -fsSL https://get.docker.com | sh
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker installation failed: docker command is unavailable." >&2
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker installation failed: docker compose plugin is unavailable." >&2
    exit 1
  fi
}

enable_docker() {
  systemctl enable --now docker
}

write_env_file() {
  mkdir -p "$CAID_STATE_DIR"
  chmod 700 "$CAID_STATE_DIR"

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  local host_default
  host_default="$(hostname -f 2>/dev/null || hostname)"

  prompt_if_missing AUTH_HOST "Keycloak/auth private hostname" "auth.$host_default"
  prompt_if_missing BAO_HOST "OpenBao private hostname" "bao.$host_default"
  validate_plain_hostname AUTH_HOST
  validate_plain_hostname BAO_HOST
  if [[ "$AUTH_HOST" == "$BAO_HOST" ]]; then
    echo "AUTH_HOST and BAO_HOST must be different hostnames so Caddy can route Keycloak and OpenBao separately." >&2
    exit 1
  fi

  prompt_if_missing ZTNA_PROVIDER "Secure management overlay provider: none, tailscale, or netbird" "none"
  ZTNA_PROVIDER="$(printf '%s' "$ZTNA_PROVIDER" | tr '[:upper:]' '[:lower:]')"

  case "$ZTNA_PROVIDER" in
    none)
      prompt_optional_if_unset VPN_CIDR "Optional CIDR allowed to reach CAId UI, e.g. your.home.ip/32; leave blank to skip firewall automation" ""
      ;;
    tailscale)
      VPN_CIDR="${VPN_CIDR:-100.64.0.0/10}"
      prompt_if_missing TAILSCALE_HOSTNAME "Tailscale device hostname" "caid"
      prompt_optional_if_unset TAILSCALE_AUTH_KEY "Optional Tailscale auth key; leave blank for browser login" "" true
      ;;
    netbird)
      VPN_CIDR="${VPN_CIDR:-100.64.0.0/10}"
      prompt_optional_if_unset NETBIRD_SETUP_KEY "Optional NetBird setup key; leave blank for interactive login" "" true
      prompt_optional_if_unset NETBIRD_MANAGEMENT_URL "Optional NetBird management URL for self-hosted NetBird; leave blank for default cloud/control URL" ""
      ;;
    *)
      echo "Unsupported ZTNA_PROVIDER=$ZTNA_PROVIDER. Use none, tailscale, or netbird." >&2
      exit 1
      ;;
  esac

  prompt_if_missing KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME "Initial Keycloak admin username" "admin"
  prompt_if_missing INITIAL_OWNER_USERNAME "Initial website owner username" "owner"
  prompt_if_missing INITIAL_OWNER_EMAIL "Initial website owner email" "owner@$AUTH_HOST"
  prompt_if_missing APP_PUBLIC_URL "Website public URL" "https://app.example.com"
  prompt_if_missing MEDIA_PUBLIC_URL "Media public URL" "https://media.example.com"
  prompt_if_missing OAUTH2_PROXY_PUBLIC_URL "OAuth2 Proxy public URL for protected admin dashboards" "https://oauth2.example.com"
  prompt_if_missing RUSTFS_BUCKET "RustFS/S3 media bucket name" "public-media"
  prompt_optional_if_unset NETBIRD_HOST "Optional NetBird/ZTNA hostname; leave blank to publish a config request" ""
  prompt_optional_if_unset GRAFANA_HOST "Optional Grafana logging hostname; leave blank to publish a config request" ""
  prompt_optional_if_unset GOOGLE_CLIENT_ID "Optional Google OAuth client ID; leave blank to skip" ""
  prompt_optional_if_unset GOOGLE_CLIENT_SECRET "Optional Google OAuth client secret; leave blank to skip" "" true
  prompt_optional_if_unset ALLOWED_EMAILS "Optional comma-separated allowed emails/domains; leave blank to skip" ""
  prompt_optional_if_unset DNS_PROVIDER "Optional DNS provider for automated records; none or cloudflare" "none"
  DNS_PROVIDER="$(printf '%s' "${DNS_PROVIDER:-none}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
    prompt_if_missing CLOUDFLARE_ZONE_NAME "Cloudflare zone name" "$AUTH_HOST"
    prompt_optional_if_unset CLOUDFLARE_ZONE_ID "Optional Cloudflare zone ID; leave blank if external automation resolved it" ""
    prompt_if_missing CLOUDFLARE_API_TOKEN "Cloudflare API token with Zone:DNS:Edit" "" true
    CLOUDFLARE_PROXIED="${CLOUDFLARE_PROXIED:-false}"
    CLOUDFLARE_TTL="${CLOUDFLARE_TTL:-120}"
  else
    DNS_PROVIDER="none"
    CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-}"
    CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
    CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
    CLOUDFLARE_PROXIED="${CLOUDFLARE_PROXIED:-false}"
    CLOUDFLARE_TTL="${CLOUDFLARE_TTL:-120}"
  fi

  if [[ -z "${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
    KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD="$(random_b64url 24)"
    echo "Generated KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD."
  fi

  if [[ -z "${KEYCLOAK_DB_PASSWORD:-}" ]]; then
    KEYCLOAK_DB_PASSWORD="$(random_b64url 32)"
    echo "Generated KEYCLOAK_DB_PASSWORD."
  fi

  if [[ -z "${INITIAL_OWNER_PASSWORD:-}" ]]; then
    INITIAL_OWNER_PASSWORD="$(random_b64url 24)"
    echo "Generated INITIAL_OWNER_PASSWORD."
  fi

  if [[ -z "${WEBSITE_AUTH_SECRET:-}" ]]; then
    WEBSITE_AUTH_SECRET="$(openssl rand -base64 32)"
    echo "Generated WEBSITE_AUTH_SECRET."
  fi

  if [[ -z "${WEBSITE_CLIENT_SECRET:-}" ]]; then
    WEBSITE_CLIENT_SECRET="$(random_b64url 32)"
    echo "Generated WEBSITE_CLIENT_SECRET."
  fi

  if [[ -z "${OAUTH2_PROXY_CLIENT_SECRET:-}" ]]; then
    OAUTH2_PROXY_CLIENT_SECRET="$(random_b64url 32)"
    echo "Generated OAUTH2_PROXY_CLIENT_SECRET."
  fi

  if [[ -z "${OAUTH2_PROXY_COOKIE_SECRET:-}" ]]; then
    OAUTH2_PROXY_COOKIE_SECRET="$(openssl rand -hex 16)"
    echo "Generated OAUTH2_PROXY_COOKIE_SECRET."
  fi

  if [[ -z "${WEBSITE_ADMIN_SYNC_CLIENT_SECRET:-}" ]]; then
    WEBSITE_ADMIN_SYNC_CLIENT_SECRET="$(random_b64url 32)"
    echo "Generated WEBSITE_ADMIN_SYNC_CLIENT_SECRET."
  fi

  if [[ -z "${OPENBAO_OIDC_CLIENT_SECRET:-}" ]]; then
    OPENBAO_OIDC_CLIENT_SECRET="$(random_b64url 32)"
    echo "Generated OPENBAO_OIDC_CLIENT_SECRET."
  fi

  if [[ -z "${NETBIRD_OIDC_CLIENT_SECRET:-}" ]]; then
    NETBIRD_OIDC_CLIENT_SECRET="$(random_b64url 32)"
    echo "Generated NETBIRD_OIDC_CLIENT_SECRET."
  fi

  if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(random_b64url 24)"
    echo "Generated GRAFANA_ADMIN_PASSWORD."
  fi

  if [[ -z "${RUSTFS_ACCESS_KEY_ID:-}" ]]; then
    RUSTFS_ACCESS_KEY_ID="rustfs-$(random_b64url 18)"
    echo "Generated RUSTFS_ACCESS_KEY_ID."
  fi

  if [[ -z "${RUSTFS_SECRET_ACCESS_KEY:-}" ]]; then
    RUSTFS_SECRET_ACCESS_KEY="$(random_b64url 32)"
    echo "Generated RUSTFS_SECRET_ACCESS_KEY."
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
AUTH_HOST=$AUTH_HOST
BAO_HOST=$BAO_HOST
VPN_CIDR=$VPN_CIDR
ZTNA_PROVIDER=$ZTNA_PROVIDER
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:-}
NETBIRD_SETUP_KEY=${NETBIRD_SETUP_KEY:-}
NETBIRD_MANAGEMENT_URL=${NETBIRD_MANAGEMENT_URL:-}
NETBIRD_HOST=${NETBIRD_HOST:-}
GRAFANA_HOST=${GRAFANA_HOST:-}

BAO_PORT=8200
BAO_ADDR=http://openbao:8200
BAO_API_ADDR=http://openbao:8200
BAO_KV_MOUNT=$BAO_KV_MOUNT

KEYCLOAK_PORT=8080
KEYCLOAK_REALM=$KEYCLOAK_REALM
KEYCLOAK_DB_PASSWORD=$KEYCLOAK_DB_PASSWORD
KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME=$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME
KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD=$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD
INITIAL_OWNER_USERNAME=$INITIAL_OWNER_USERNAME
INITIAL_OWNER_EMAIL=$INITIAL_OWNER_EMAIL
INITIAL_OWNER_PASSWORD=$INITIAL_OWNER_PASSWORD
WEBSITE_AUTH_SECRET=$WEBSITE_AUTH_SECRET
WEBSITE_CLIENT_SECRET=$WEBSITE_CLIENT_SECRET
OAUTH2_PROXY_CLIENT_SECRET=$OAUTH2_PROXY_CLIENT_SECRET
OAUTH2_PROXY_COOKIE_SECRET=$OAUTH2_PROXY_COOKIE_SECRET
WEBSITE_ADMIN_SYNC_CLIENT_SECRET=$WEBSITE_ADMIN_SYNC_CLIENT_SECRET
OPENBAO_OIDC_CLIENT_SECRET=$OPENBAO_OIDC_CLIENT_SECRET
NETBIRD_OIDC_CLIENT_SECRET=$NETBIRD_OIDC_CLIENT_SECRET
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
RUSTFS_ACCESS_KEY_ID=$RUSTFS_ACCESS_KEY_ID
RUSTFS_SECRET_ACCESS_KEY=$RUSTFS_SECRET_ACCESS_KEY

APP_POLICY_NAME=$APP_POLICY_NAME
APPROLE_NAME=$APPROLE_NAME

APP_PUBLIC_URL=$APP_PUBLIC_URL
MEDIA_PUBLIC_URL=$MEDIA_PUBLIC_URL
OAUTH2_PROXY_PUBLIC_URL=$OAUTH2_PROXY_PUBLIC_URL
RUSTFS_BUCKET=$RUSTFS_BUCKET
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}
ALLOWED_EMAILS=${ALLOWED_EMAILS:-}
DNS_PROVIDER=$DNS_PROVIDER
CLOUDFLARE_ZONE_NAME=$CLOUDFLARE_ZONE_NAME
CLOUDFLARE_ZONE_ID=$CLOUDFLARE_ZONE_ID
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
CLOUDFLARE_PROXIED=$CLOUDFLARE_PROXIED
CLOUDFLARE_TTL=$CLOUDFLARE_TTL

OPENBAO_IMAGE=$OPENBAO_IMAGE
KEYCLOAK_IMAGE=$KEYCLOAK_IMAGE
POSTGRES_IMAGE=$POSTGRES_IMAGE
CADDY_IMAGE=$CADDY_IMAGE
EOF
  chmod 600 "$ENV_FILE"
}

install_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if tailscale status >/dev/null 2>&1; then
    echo "Tailscale is already connected."
    return
  fi

  echo "Connecting Tailscale..."
  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    tailscale up --auth-key "$TAILSCALE_AUTH_KEY" --hostname "${TAILSCALE_HOSTNAME:-caid}" --ssh
  else
    echo "No TAILSCALE_AUTH_KEY provided. Tailscale will print a browser login URL."
    tailscale up --hostname "${TAILSCALE_HOSTNAME:-caid}" --ssh
  fi
}

install_netbird() {
  if ! command -v netbird >/dev/null 2>&1; then
    echo "Installing NetBird..."
    curl -fsSL https://pkgs.netbird.io/install.sh | sh
  fi

  if netbird status >/dev/null 2>&1; then
    echo "NetBird is already connected."
    return
  fi

  echo "Connecting NetBird..."
  local args=()
  if [[ -n "${NETBIRD_SETUP_KEY:-}" ]]; then
    args+=(--setup-key "$NETBIRD_SETUP_KEY")
  fi
  if [[ -n "${NETBIRD_MANAGEMENT_URL:-}" ]]; then
    args+=(--management-url "$NETBIRD_MANAGEMENT_URL")
  fi

  if ((${#args[@]} > 0)); then
    netbird up "${args[@]}"
  else
    echo "No NETBIRD_SETUP_KEY provided. NetBird will use its interactive login flow if supported."
    netbird up
  fi
}

configure_management_overlay() {
  case "${ZTNA_PROVIDER:-none}" in
    none)
      echo "No management overlay selected."
      ;;
    tailscale)
      install_tailscale
      ;;
    netbird)
      install_netbird
      ;;
  esac
}

install_caid_systemd_service() {
  cat >/etc/systemd/system/caid.service <<EOF
[Unit]
Description=CAId central authorization and identity stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$CAID_HOME
ExecStart=/usr/bin/docker compose --env-file $ENV_FILE -f $CAID_HOME/docker-compose.yaml up -d
ExecStop=/usr/bin/docker compose --env-file $ENV_FILE -f $CAID_HOME/docker-compose.yaml stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable caid.service
}

write_stack_files() {
  mkdir -p \
    "$CAID_HOME" \
    "$CAID_HOME/caddy" \
    "$CAID_HOME/openbao/config" \
    "$CAID_HOME/openbao/policies" \
    "$CAID_DATA_DIR/openbao" \
    "$CAID_DATA_DIR/keycloak-db" \
    "$CAID_DATA_DIR/caddy-data" \
    "$CAID_DATA_DIR/caddy-config"

  cat >"$CAID_HOME/docker-compose.yaml" <<'EOF'
services:
  caddy:
    image: ${CADDY_IMAGE}
    restart: unless-stopped
    environment:
      BAO_HOST: ${BAO_HOST}
      AUTH_HOST: ${AUTH_HOST}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /var/lib/caid/caddy-data:/data
      - /var/lib/caid/caddy-config:/config
    depends_on:
      - openbao
      - keycloak
    networks:
      - edge
      - internal

  openbao:
    image: ${OPENBAO_IMAGE}
    entrypoint: ["/bin/sh", "-c"]
    command:
      - chown -R 100:1000 /openbao/data && exec su openbao -s /bin/sh -c 'bao server -config=/openbao/config/openbao.hcl'
    user: "0:0"
    restart: unless-stopped
    cap_add:
      - IPC_LOCK
    environment:
      BAO_API_ADDR: ${BAO_API_ADDR}
      BAO_ADDR: http://127.0.0.1:8200
    volumes:
      - /var/lib/caid/openbao:/openbao/data
      - ./openbao/config:/openbao/config:ro
      - ./openbao/policies:/openbao/policies:ro
    expose:
      - "8200"
    networks:
      - internal

  keycloak-db:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    volumes:
      - /var/lib/caid/keycloak-db:/var/lib/postgresql/data
    networks:
      - internal

  keycloak:
    image: ${KEYCLOAK_IMAGE}
    command:
      - start
      - --proxy-headers=xforwarded
      - --hostname=${AUTH_HOST}
      - --hostname-strict=true
      - --http-enabled=true
      - --health-enabled=true
    restart: unless-stopped
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: keycloak-db
      KC_DB_URL_DATABASE: keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD}
    depends_on:
      - keycloak-db
    expose:
      - "8080"
      - "9000"
    networks:
      - internal

networks:
  edge:
  internal:
EOF

  cat >"$CAID_HOME/openbao/config/openbao.hcl" <<'EOF'
ui = true
disable_mlock = true

storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = true
}
EOF

  cat >"$CAID_HOME/openbao/policies/website-runtime.hcl" <<'EOF'
path "kv/data/website/prod" {
  capabilities = ["read"]
}

path "kv/data/rustfs/prod" {
  capabilities = ["read"]
}

path "kv/data/oauth2-proxy/prod" {
  capabilities = ["read"]
}

path "kv/data/keycloak/prod" {
  capabilities = ["read"]
}

path "kv/data/caid/config-requests" {
  capabilities = ["read", "update"]
}

path "kv/data/caid/config-values/*" {
  capabilities = ["read", "update"]
}
EOF

  cat >"$CAID_HOME/openbao/policies/admin-bootstrap.hcl" <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  cat >"$CAID_HOME/openbao/policies/openbao-admin.hcl" <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  cat >"$CAID_HOME/caddy/Caddyfile" <<'EOF'
{$BAO_HOST} {
  reverse_proxy openbao:8200
}

{$AUTH_HOST} {
  reverse_proxy keycloak:8080
}
EOF

  # Runtime config is mounted read-only into non-root containers. Keep secrets in
  # /etc/caid locked down, but make generated service config traversable/readable.
  chmod 755 "$CAID_HOME" "$CAID_HOME/caddy" "$CAID_HOME/openbao" "$CAID_HOME/openbao/config" "$CAID_HOME/openbao/policies"
  chmod 644 \
    "$CAID_HOME/docker-compose.yaml" \
    "$CAID_HOME/caddy/Caddyfile" \
    "$CAID_HOME/openbao/config/openbao.hcl" \
    "$CAID_HOME/openbao/policies/website-runtime.hcl" \
    "$CAID_HOME/openbao/policies/admin-bootstrap.hcl" \
    "$CAID_HOME/openbao/policies/openbao-admin.hcl"
}

configure_firewall() {
  if [[ -z "${VPN_CIDR:-}" ]]; then
    echo "VPN_CIDR is empty; skipping firewall automation."
    echo "CAId admin surfaces should be protected by your VPS firewall/VPN before production use."
    return
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw is not installed; skipping firewall automation." >&2
    return
  fi

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from "$VPN_CIDR" to any port 22 proto tcp
  ufw allow from "$VPN_CIDR" to any port 80 proto tcp
  ufw allow from "$VPN_CIDR" to any port 443 proto tcp
  ufw --force enable
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$CAID_HOME/docker-compose.yaml" "$@"
}

validate_stack_files() {
  local missing=false
  local required_files=(
    "$CAID_HOME/docker-compose.yaml"
    "$CAID_HOME/openbao/config/openbao.hcl"
    "$CAID_HOME/openbao/policies/website-runtime.hcl"
    "$CAID_HOME/openbao/policies/admin-bootstrap.hcl"
    "$CAID_HOME/openbao/policies/openbao-admin.hcl"
    "$CAID_HOME/caddy/Caddyfile"
  )

  for file in "${required_files[@]}"; do
    if [[ ! -s "$file" ]]; then
      echo "Missing required CAId stack file: $file" >&2
      missing=true
    fi
  done

  if [[ "$missing" == "true" ]]; then
    echo "Refusing to start CAId stack until all generated config files exist." >&2
    echo "Rerun the latest setup-caid-vps.sh; do not start Docker Compose directly from a partial /srv/caid directory." >&2
    exit 1
  fi

  if ! grep -q 'bao server -config=/openbao/config/openbao.hcl' "$CAID_HOME/docker-compose.yaml"; then
    echo "CAId compose file does not point OpenBao at /openbao/config/openbao.hcl." >&2
    exit 1
  fi

  if ! grep -q 'listener "tcp"' "$CAID_HOME/openbao/config/openbao.hcl"; then
    echo "OpenBao config exists but does not contain a TCP listener." >&2
    exit 1
  fi

  compose config >/dev/null
}

pull_and_start_stack() {
  validate_stack_files
  echo "Pulling CAId images..."
  compose pull
  echo "Starting CAId stack..."
  compose up -d
}

wait_for_openbao() {
  local deadline=$((SECONDS + 180))
  until compose exec -T openbao sh -lc \
    "test -r /openbao/config/openbao.hcl && wget -qO- http://127.0.0.1:8200/v1/sys/seal-status >/dev/null" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for OpenBao process." >&2
      echo "" >&2
      echo "OpenBao container status:" >&2
      compose ps openbao >&2 || true
      echo "" >&2
      echo "OpenBao recent logs:" >&2
      compose logs --tail=120 openbao >&2 || true
      echo "" >&2
      echo "Generated OpenBao config path expected on host:" >&2
      echo "  $CAID_HOME/openbao/config/openbao.hcl" >&2
      exit 1
    fi
    sleep 3
  done
}

wait_for_keycloak() {
  local deadline=$((SECONDS + 600))
  until compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for Keycloak admin login." >&2
      echo "" >&2
      echo "Keycloak container status:" >&2
      compose ps keycloak >&2 || true
      echo "" >&2
      echo "Keycloak recent logs:" >&2
      compose logs --tail=160 keycloak >&2 || true
      exit 1
    fi
    sleep 5
  done
}

bao() {
  compose exec -T openbao env BAO_ADDR=http://127.0.0.1:8200 "$@"
}

extract_json_field() {
  local field="$1"
  node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(0,'utf8'));const parts='$field'.split('.');let cur=data;for(const part of parts){cur=cur && Object.prototype.hasOwnProperty.call(cur, part) ? cur[part] : undefined;} if(cur===undefined){process.exit(1)} if(typeof cur==='object'){process.stdout.write(JSON.stringify(cur))} else {process.stdout.write(String(cur))}"
}

init_and_unseal_openbao() {
  local status_json initialized sealed root_token unseal_key created_init
  created_init=false

  status_json="$(bao bao status -format=json || true)"
  initialized="$(printf '%s' "$status_json" | extract_json_field initialized)"
  sealed="$(printf '%s' "$status_json" | extract_json_field sealed)"

  if [[ "$initialized" != "true" ]]; then
    echo "Initializing OpenBao..."
    local init_json
    init_json="$(bao bao operator init -format=json -key-shares=1 -key-threshold=1)"
    umask 077
    printf '%s\n' "$init_json" >"$RECOVERY_FILE"
    chmod 600 "$RECOVERY_FILE"
    created_init=true
  elif [[ ! -f "$RECOVERY_FILE" ]]; then
    echo "OpenBao is initialized but $RECOVERY_FILE is missing." >&2
    echo "Provide the recovery file or unseal manually before rerunning." >&2
    exit 1
  fi

  root_token="$(node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(data.root_token)" "$RECOVERY_FILE")"
  unseal_key="$(node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(data.unseal_keys_b64[0])" "$RECOVERY_FILE")"

  status_json="$(bao bao status -format=json || true)"
  sealed="$(printf '%s' "$status_json" | extract_json_field sealed)"

  if [[ "$sealed" == "true" ]]; then
    echo "Unsealing OpenBao..."
    bao bao operator unseal "$unseal_key" >/dev/null
  fi

  cat >"$RECOVERY_README" <<EOF
OpenBao recovery material:
$RECOVERY_FILE

Contains:
- root_token: super-admin OpenBao credential
- unseal_keys_b64: key material required to unseal OpenBao after restart

Back this file up offline. Do not commit it. Do not give it to app VPSes.
EOF
  chmod 600 "$RECOVERY_README"

  if [[ "$created_init" == "true" ]]; then
    echo ""
    echo "OPENBAO FIRST-RUN RECOVERY MATERIAL CREATED"
    echo "Recovery JSON: $RECOVERY_FILE"
    echo "Instructions:  $RECOVERY_README"
    echo ""
    echo "UNSEAL_KEY_B64=$unseal_key"
    echo "ROOT_TOKEN=$root_token"
    echo ""
    echo "Back these up offline now."
  fi

  BAO_BOOTSTRAP_TOKEN="$root_token"
}

bootstrap_openbao() {
  echo "Bootstrapping OpenBao policies and AppRole..."
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao secrets enable -path="$BAO_KV_MOUNT" -version=2 kv >/dev/null 2>&1 || true
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao auth enable approle >/dev/null 2>&1 || true
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao policy write admin-bootstrap /openbao/policies/admin-bootstrap.hcl
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao policy write openbao-admin /openbao/policies/openbao-admin.hcl
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao policy write "$APP_POLICY_NAME" /openbao/policies/website-runtime.hcl
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao write "auth/approle/role/$APPROLE_NAME" \
    "token_policies=$APP_POLICY_NAME" \
    secret_id_ttl=0 \
    token_ttl=1h \
    token_max_ttl=4h
}

kcadm() {
  compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" </dev/null
}

keycloak_client_id() {
  local client_id="$1"
  kcadm get clients -r "$KEYCLOAK_REALM" -q "clientId=$client_id" --fields id --format csv | tail -n 1 | tr -d '"\r'
}

ensure_keycloak_client() {
  local client_id="$1"
  local secret="$2"
  local redirect_uri="$3"
  local web_origin="$4"
  local service_account="$5"
  local id json_file

  id="$(keycloak_client_id "$client_id" || true)"
  json_file="/tmp/keycloak-client-$client_id.json"

  compose exec -T keycloak sh -lc "cat > '$json_file'" <<EOF
{
  "clientId": "$client_id",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": $service_account,
  "secret": "$secret",
  "redirectUris": ["$redirect_uri"],
  "webOrigins": ["$web_origin"]
}
EOF

  if [[ -n "$id" ]]; then
    kcadm update "clients/$id" -r "$KEYCLOAK_REALM" -f "$json_file"
  else
    kcadm create clients -r "$KEYCLOAK_REALM" -f "$json_file"
    id="$(keycloak_client_id "$client_id")"
  fi

  printf '%s' "$id"
}

keycloak_user_id() {
  local username="$1"
  kcadm get users -r "$KEYCLOAK_REALM" -q "username=$username" --fields id --format csv | tail -n 1 | tr -d '"\r'
}

keycloak_group_id() {
  local group_name="$1"
  kcadm get groups -r "$KEYCLOAK_REALM" -q "search=$group_name" --fields id,name --format csv |
    awk -F, -v name="\"$group_name\"" '$2 == name { gsub(/"/, "", $1); print $1; exit }'
}

ensure_keycloak_group() {
  local group_name="$1"
  local group_id

  group_id="$(keycloak_group_id "$group_name" || true)"
  if [[ -z "$group_id" ]]; then
    kcadm create groups -r "$KEYCLOAK_REALM" -s "name=$group_name" >/dev/null
    group_id="$(keycloak_group_id "$group_name")"
  fi

  printf '%s' "$group_id"
}

ensure_user_group() {
  local user_id="$1"
  local group_name="$2"
  local group_id

  group_id="$(ensure_keycloak_group "$group_name")"
  kcadm update "users/$user_id/groups/$group_id" -r "$KEYCLOAK_REALM" -n >/dev/null 2>&1 || true
}

ensure_groups_mapper() {
  local client_uuid="$1"
  local mapper_name="${2:-groups}"
  local existing

  existing="$(kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" --fields id,name --format csv |
    awk -F, -v name="\"$mapper_name\"" '$2 == name { gsub(/"/, "", $1); print $1; exit }' || true)"

  if [[ -n "$existing" ]]; then
    return
  fi

  kcadm create "clients/$client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
    -s "name=$mapper_name" \
    -s "protocol=openid-connect" \
    -s "protocolMapper=oidc-group-membership-mapper" \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
}

ensure_initial_owner_user() {
  local username="${INITIAL_OWNER_USERNAME:?Missing INITIAL_OWNER_USERNAME}"
  local email="${INITIAL_OWNER_EMAIL:?Missing INITIAL_OWNER_EMAIL}"
  local password="${INITIAL_OWNER_PASSWORD:?Missing INITIAL_OWNER_PASSWORD}"
  local user_id

  user_id="$(keycloak_user_id "$username" || true)"

  if [[ -z "$user_id" ]]; then
    kcadm create users -r "$KEYCLOAK_REALM" \
      -s "username=$username" \
      -s "email=$email" \
      -s "firstName=Website" \
      -s "lastName=Owner" \
      -s enabled=true \
      -s emailVerified=true \
      -s 'requiredActions=[]' >/dev/null
  else
    kcadm update "users/$user_id" -r "$KEYCLOAK_REALM" \
      -s "email=$email" \
      -s "firstName=Website" \
      -s "lastName=Owner" \
      -s enabled=true \
      -s emailVerified=true \
      -s 'requiredActions=[]' >/dev/null
  fi

  kcadm set-password -r "$KEYCLOAK_REALM" \
    --username "$username" \
    --new-password "$password" \
    --temporary=false >/dev/null

  kcadm add-roles -r "$KEYCLOAK_REALM" \
    --uusername "$username" \
    --cclientid website \
    --rolename owner >/dev/null 2>&1 || true

  user_id="$(keycloak_user_id "$username")"
  for group in owner openbao_admin rustfs_admin netbird_admin logging_admin identity_hr_manager config_admin audit_admin; do
    ensure_user_group "$user_id" "$group"
  done
}

bootstrap_keycloak() {
  echo "Bootstrapping Keycloak realm, clients, and roles..."
  kcadm config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  kcadm create realms -s "realm=$KEYCLOAK_REALM" -s enabled=true >/dev/null 2>&1 || true
  kcadm update "realms/$KEYCLOAK_REALM" \
    -s registrationAllowed=true \
    -s registrationEmailAsUsername=true \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s verifyEmail=false >/dev/null
  kcadm update "authentication/required-actions/CONFIGURE_TOTP" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s defaultAction=true >/dev/null 2>&1 || true

  local website_secret oauth_secret admin_secret website_client_uuid openbao_client_uuid netbird_client_uuid
  website_secret="$WEBSITE_CLIENT_SECRET"
  oauth_secret="$OAUTH2_PROXY_CLIENT_SECRET"
  admin_secret="$WEBSITE_ADMIN_SYNC_CLIENT_SECRET"

  website_client_uuid="$(ensure_keycloak_client website "$website_secret" "$APP_PUBLIC_URL/api/auth/callback/keycloak" "$APP_PUBLIC_URL" false)"
  ensure_keycloak_client oauth2-proxy "$oauth_secret" "$OAUTH2_PROXY_PUBLIC_URL/oauth2/callback" "$OAUTH2_PROXY_PUBLIC_URL" false >/dev/null
  ensure_keycloak_client website-admin-sync "$admin_secret" "$APP_PUBLIC_URL/*" "$APP_PUBLIC_URL" true >/dev/null
  openbao_client_uuid="$(ensure_keycloak_client openbao "$OPENBAO_OIDC_CLIENT_SECRET" "https://$BAO_HOST/ui/vault/auth/oidc/oidc/callback" "https://$BAO_HOST" false)"
  netbird_client_uuid="$(ensure_keycloak_client netbird "$NETBIRD_OIDC_CLIENT_SECRET" "${NETBIRD_PUBLIC_URL:-https://${NETBIRD_HOST:-netbird.localhost}}/*" "${NETBIRD_PUBLIC_URL:-https://${NETBIRD_HOST:-netbird.localhost}}" false)"

  for role in owner media_admin editor viewer infra_admin identity_hr_manager config_admin audit_admin logging_admin openbao_admin rustfs_admin netbird_admin; do
    kcadm create "clients/$website_client_uuid/roles" -r "$KEYCLOAK_REALM" -s "name=$role" >/dev/null 2>&1 || true
    ensure_keycloak_group "$role" >/dev/null
  done
  ensure_groups_mapper "$website_client_uuid"
  ensure_groups_mapper "$openbao_client_uuid"
  ensure_groups_mapper "$netbird_client_uuid"

  ensure_initial_owner_user

  for role in view-users query-users manage-users view-clients; do
    kcadm add-roles -r "$KEYCLOAK_REALM" \
      --uusername service-account-website-admin-sync \
      --cclientid realm-management \
      --rolename "$role" >/dev/null 2>&1 || true
  done

  seed_app_secrets "$website_secret" "$oauth_secret" "$admin_secret"
}

write_kv() {
  local path="$1"
  local payload="$2"
  local encoded
  encoded="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  compose exec -T openbao sh -lc "printf '%s' '$encoded' | base64 -d > /tmp/payload.json && BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$BAO_BOOTSTRAP_TOKEN' bao write '$BAO_KV_MOUNT/data/$path' @/tmp/payload.json >/dev/null"
}

seed_app_secrets() {
  local website_secret="$1"
  local oauth_secret="$2"
  local admin_secret="$3"
  local auth_secret s3_access s3_secret oauth_cookie website_payload
  auth_secret="$WEBSITE_AUTH_SECRET"
  s3_access="$RUSTFS_ACCESS_KEY_ID"
  s3_secret="$RUSTFS_SECRET_ACCESS_KEY"
  oauth_cookie="$OAUTH2_PROXY_COOKIE_SECRET"

  website_payload="$(AUTH_SECRET_VALUE="$auth_secret" \
    WEBSITE_SECRET="$website_secret" \
    APP_PUBLIC_URL="$APP_PUBLIC_URL" \
    MEDIA_PUBLIC_URL="$MEDIA_PUBLIC_URL" \
    AUTH_HOST="$AUTH_HOST" \
    KEYCLOAK_REALM="$KEYCLOAK_REALM" \
    GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
    GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
    ALLOWED_EMAILS="${ALLOWED_EMAILS:-}" \
    node -e "
const data = {
  AUTH_SECRET: process.env.AUTH_SECRET_VALUE,
  NEXTAUTH_SECRET: process.env.AUTH_SECRET_VALUE,
  NEXTAUTH_URL: process.env.APP_PUBLIC_URL,
  NEXT_PUBLIC_SITE_URL: process.env.APP_PUBLIC_URL,
  NEXT_PUBLIC_MEDIA_BASE_URL: process.env.MEDIA_PUBLIC_URL,
  KEYCLOAK_ISSUER: 'https://' + process.env.AUTH_HOST + '/realms/' + process.env.KEYCLOAK_REALM,
  KEYCLOAK_CLIENT_ID: 'website',
  KEYCLOAK_CLIENT_SECRET: process.env.WEBSITE_SECRET,
  KEYCLOAK_REQUIRED_MEDIA_ROLES: 'owner,media_admin',
  KEYCLOAK_ROLE_CLAIM_PATH: 'resource_access.website.roles'
};
if (process.env.GOOGLE_CLIENT_ID) data.GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
if (process.env.GOOGLE_CLIENT_SECRET) data.GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;
if (process.env.ALLOWED_EMAILS) data.ALLOWED_EMAILS = process.env.ALLOWED_EMAILS;
process.stdout.write(JSON.stringify({ data }));
")"

  write_kv website/prod "$website_payload"
  write_kv rustfs/prod "{\"data\":{\"NEXT_PUBLIC_MEDIA_BASE_URL\":\"$MEDIA_PUBLIC_URL\",\"S3_ENDPOINT\":\"http://rustfs:9000\",\"S3_PUBLIC_ENDPOINT\":\"$MEDIA_PUBLIC_URL\",\"S3_BUCKET\":\"$RUSTFS_BUCKET\",\"S3_REGION\":\"us-east-1\",\"S3_ACCESS_KEY_ID\":\"$s3_access\",\"S3_SECRET_ACCESS_KEY\":\"$s3_secret\"}}"
  write_kv oauth2-proxy/prod "{\"data\":{\"OAUTH2_PROXY_CLIENT_ID\":\"oauth2-proxy\",\"OAUTH2_PROXY_CLIENT_SECRET\":\"$oauth_secret\",\"OAUTH2_PROXY_COOKIE_SECRET\":\"$oauth_cookie\",\"OAUTH2_PROXY_REDIRECT_URL\":\"$OAUTH2_PROXY_PUBLIC_URL/oauth2/callback\"}}"
  write_kv keycloak/prod "{\"data\":{\"KEYCLOAK_ADMIN_REALM\":\"$KEYCLOAK_REALM\",\"KEYCLOAK_ADMIN_CLIENT_ID\":\"website-admin-sync\",\"KEYCLOAK_ADMIN_CLIENT_SECRET\":\"$admin_secret\"}}"
  write_kv caid/config-values/netbird "{\"data\":{\"NETBIRD_HOST\":\"${NETBIRD_HOST:-}\",\"NETBIRD_OIDC_CLIENT_SECRET\":\"$NETBIRD_OIDC_CLIENT_SECRET\"}}"
  write_kv caid/config-values/logging "{\"data\":{\"GRAFANA_HOST\":\"${GRAFANA_HOST:-}\",\"GRAFANA_ADMIN_PASSWORD\":\"$GRAFANA_ADMIN_PASSWORD\"}}"
  if [[ "${DNS_PROVIDER:-none}" == "cloudflare" && -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    local cloudflare_payload
    cloudflare_payload="$(DNS_PROVIDER_VALUE="$DNS_PROVIDER" \
      CLOUDFLARE_ZONE_NAME_VALUE="$CLOUDFLARE_ZONE_NAME" \
      CLOUDFLARE_ZONE_ID_VALUE="${CLOUDFLARE_ZONE_ID:-}" \
      CLOUDFLARE_API_TOKEN_VALUE="$CLOUDFLARE_API_TOKEN" \
      CLOUDFLARE_PROXIED_VALUE="${CLOUDFLARE_PROXIED:-false}" \
      CLOUDFLARE_TTL_VALUE="${CLOUDFLARE_TTL:-120}" \
      node -e "process.stdout.write(JSON.stringify({data:{DNS_PROVIDER:process.env.DNS_PROVIDER_VALUE,CLOUDFLARE_ZONE_NAME:process.env.CLOUDFLARE_ZONE_NAME_VALUE,CLOUDFLARE_ZONE_ID:process.env.CLOUDFLARE_ZONE_ID_VALUE,CLOUDFLARE_API_TOKEN:process.env.CLOUDFLARE_API_TOKEN_VALUE,CLOUDFLARE_PROXIED:process.env.CLOUDFLARE_PROXIED_VALUE,CLOUDFLARE_TTL:process.env.CLOUDFLARE_TTL_VALUE}}))")"
    write_kv cloudflare/prod "$cloudflare_payload"
  fi
}

configure_openbao_oidc() {
  echo "Configuring OpenBao OIDC login through Keycloak..."
  local role_payload
  role_payload="$(BAO_HOST_VALUE="$BAO_HOST" node -e "
const host = process.env.BAO_HOST_VALUE;
process.stdout.write(JSON.stringify({
  user_claim: 'email',
  groups_claim: 'groups',
  allowed_redirect_uris: [
    'https://' + host + '/ui/vault/auth/oidc/oidc/callback',
    'http://localhost:8250/oidc/callback'
  ],
  bound_claims: {
    groups: 'openbao_admin'
  },
  policies: ['openbao-admin'],
  ttl: '1h'
}));
")"

  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao auth enable oidc >/dev/null 2>&1 || true
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao write auth/oidc/config \
    oidc_discovery_url="https://$AUTH_HOST/realms/$KEYCLOAK_REALM" \
    oidc_client_id="openbao" \
    oidc_client_secret="$OPENBAO_OIDC_CLIENT_SECRET" \
    default_role="openbao-admin" >/dev/null
  local encoded
  encoded="$(printf '%s' "$role_payload" | base64 | tr -d '\n')"
  compose exec -T openbao sh -lc "printf '%s' '$encoded' | base64 -d > /tmp/openbao-oidc-role.json && BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$BAO_BOOTSTRAP_TOKEN' bao write auth/oidc/role/openbao-admin @/tmp/openbao-oidc-role.json >/dev/null"
}

print_approle() {
  local role_id secret_id
  role_id="$(bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao read -format=json "auth/approle/role/$APPROLE_NAME/role-id" | node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(data.data.role_id)")"
  secret_id="$(bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao write -format=json -f "auth/approle/role/$APPROLE_NAME/secret-id" | node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(data.data.secret_id)")"

  echo ""
  echo "APP VPS BOOTSTRAP CREDENTIALS"
  echo "BAO_ADDR=https://$BAO_HOST"
  echo "OPENBAO_ROLE_ID=$role_id"
  echo "OPENBAO_SECRET_ID=$secret_id"
  echo ""
  echo "INITIAL WEBSITE OWNER LOGIN"
  echo "KEYCLOAK_REALM=$KEYCLOAK_REALM"
  echo "USERNAME=$INITIAL_OWNER_USERNAME"
  echo "EMAIL=$INITIAL_OWNER_EMAIL"
  echo "PASSWORD=$INITIAL_OWNER_PASSWORD"
}

main() {
  require_root
  install_missing_dependencies
  enable_docker
  write_env_file
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  configure_management_overlay
  write_stack_files
  install_caid_systemd_service
  configure_firewall
  pull_and_start_stack
  wait_for_openbao
  init_and_unseal_openbao
  bootstrap_openbao
  wait_for_keycloak
  bootstrap_keycloak
  configure_openbao_oidc
  print_approle

  echo ""
  echo "CAId provisioning complete."
  echo "Keycloak: https://$AUTH_HOST"
  echo "OpenBao:  https://$BAO_HOST"
}

main "$@"
