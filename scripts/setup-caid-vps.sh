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

  if command -v docker >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1 &&
    command -v curl >/dev/null 2>&1 &&
    command -v git >/dev/null 2>&1 &&
    command -v openssl >/dev/null 2>&1 &&
    command -v node >/dev/null 2>&1; then
    return
  fi

  case "$manager" in
    apt)
      apt-get update
      apt-get install -y ca-certificates curl git openssl nodejs docker.io docker-compose-plugin ufw
      ;;
    dnf)
      dnf install -y ca-certificates curl git openssl nodejs docker docker-compose-plugin ufw ||
        dnf install -y ca-certificates curl git openssl nodejs docker docker-compose-plugin
      ;;
    yum)
      yum install -y ca-certificates curl git openssl nodejs docker docker-compose-plugin
      ;;
  esac
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
  prompt_if_missing VPN_CIDR "VPN/private CIDR allowed to reach CAId UI, e.g. 10.8.0.0/24" ""
  prompt_if_missing KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME "Initial Keycloak admin username" "admin"

  if [[ -z "${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
    KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD="$(random_b64url 24)"
    echo "Generated KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD."
  fi

  if [[ -z "${KEYCLOAK_DB_PASSWORD:-}" ]]; then
    KEYCLOAK_DB_PASSWORD="$(random_b64url 32)"
    echo "Generated KEYCLOAK_DB_PASSWORD."
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
AUTH_HOST=$AUTH_HOST
BAO_HOST=$BAO_HOST
VPN_CIDR=$VPN_CIDR

BAO_PORT=8200
BAO_ADDR=http://openbao:8200
BAO_API_ADDR=http://openbao:8200
BAO_KV_MOUNT=$BAO_KV_MOUNT

KEYCLOAK_PORT=8080
KEYCLOAK_REALM=$KEYCLOAK_REALM
KEYCLOAK_DB_PASSWORD=$KEYCLOAK_DB_PASSWORD
KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME=$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME
KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD=$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD

APP_POLICY_NAME=$APP_POLICY_NAME
APPROLE_NAME=$APPROLE_NAME

OPENBAO_IMAGE=$OPENBAO_IMAGE
KEYCLOAK_IMAGE=$KEYCLOAK_IMAGE
POSTGRES_IMAGE=$POSTGRES_IMAGE
CADDY_IMAGE=$CADDY_IMAGE
EOF
  chmod 600 "$ENV_FILE"
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
EOF

  cat >"$CAID_HOME/openbao/policies/admin-bootstrap.hcl" <<'EOF'
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

pull_and_start_stack() {
  echo "Pulling CAId images..."
  compose pull
  echo "Starting CAId stack..."
  compose up -d
}

wait_for_openbao() {
  local deadline=$((SECONDS + 180))
  until compose exec -T openbao sh -lc "bao status >/dev/null 2>&1 || true" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for OpenBao process." >&2
      exit 1
    fi
    sleep 3
  done
}

wait_for_keycloak() {
  local deadline=$((SECONDS + 240))
  until compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for Keycloak admin login." >&2
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
  node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(0,'utf8'));const parts='$field'.split('.');let cur=data;for(const part of parts){cur=cur?.[part];} if(cur===undefined){process.exit(1)} if(typeof cur==='object'){process.stdout.write(JSON.stringify(cur))} else {process.stdout.write(String(cur))}"
}

init_and_unseal_openbao() {
  local status_json initialized sealed root_token unseal_key created_init
  created_init=false

  status_json="$(bao bao status -format=json)"
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

  status_json="$(bao bao status -format=json)"
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
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao policy write "$APP_POLICY_NAME" /openbao/policies/website-runtime.hcl
  bao env BAO_TOKEN="$BAO_BOOTSTRAP_TOKEN" bao write "auth/approle/role/$APPROLE_NAME" \
    "token_policies=$APP_POLICY_NAME" \
    secret_id_ttl=0 \
    token_ttl=1h \
    token_max_ttl=4h
}

kcadm() {
  compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
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

bootstrap_keycloak() {
  echo "Bootstrapping Keycloak realm, clients, and roles..."
  kcadm config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  kcadm create realms -s "realm=$KEYCLOAK_REALM" -s enabled=true >/dev/null 2>&1 || true

  local website_secret oauth_secret admin_secret website_client_uuid
  website_secret="$(random_b64url 32)"
  oauth_secret="$(random_b64url 32)"
  admin_secret="$(random_b64url 32)"

  website_client_uuid="$(ensure_keycloak_client website "$website_secret" "https://app.example.com/api/auth/callback/keycloak" "https://app.example.com" false)"
  ensure_keycloak_client oauth2-proxy "$oauth_secret" "https://oauth2.example.com/oauth2/callback" "https://oauth2.example.com" false >/dev/null
  ensure_keycloak_client website-admin-sync "$admin_secret" "https://app.example.com/*" "https://app.example.com" true >/dev/null

  for role in owner media_admin editor viewer infra_admin; do
    kcadm create "clients/$website_client_uuid/roles" -r "$KEYCLOAK_REALM" -s "name=$role" >/dev/null 2>&1 || true
  done

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
  encoded="$(printf '%s' "$payload" | base64 -w 0)"
  compose exec -T openbao sh -lc "printf '%s' '$encoded' | base64 -d > /tmp/payload.json && BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$BAO_BOOTSTRAP_TOKEN' bao write '$BAO_KV_MOUNT/data/$path' @/tmp/payload.json >/dev/null"
}

seed_app_secrets() {
  local website_secret="$1"
  local oauth_secret="$2"
  local admin_secret="$3"
  local auth_secret s3_access s3_secret oauth_cookie
  auth_secret="$(openssl rand -base64 32)"
  s3_access="rustfs-$(random_b64url 18)"
  s3_secret="$(random_b64url 32)"
  oauth_cookie="$(openssl rand -base64 32)"

  write_kv website/prod "{\"data\":{\"AUTH_SECRET\":\"$auth_secret\",\"NEXTAUTH_SECRET\":\"$auth_secret\",\"NEXTAUTH_URL\":\"https://app.example.com\",\"NEXT_PUBLIC_SITE_URL\":\"https://app.example.com\",\"NEXT_PUBLIC_MEDIA_BASE_URL\":\"https://media.example.com\",\"KEYCLOAK_ISSUER\":\"https://$AUTH_HOST/realms/$KEYCLOAK_REALM\",\"KEYCLOAK_CLIENT_ID\":\"website\",\"KEYCLOAK_CLIENT_SECRET\":\"$website_secret\",\"KEYCLOAK_REQUIRED_MEDIA_ROLES\":\"owner,media_admin\",\"KEYCLOAK_ROLE_CLAIM_PATH\":\"resource_access.website.roles\"}}"
  write_kv rustfs/prod "{\"data\":{\"NEXT_PUBLIC_MEDIA_BASE_URL\":\"https://media.example.com\",\"S3_ENDPOINT\":\"http://rustfs:9000\",\"S3_PUBLIC_ENDPOINT\":\"https://media.example.com\",\"S3_BUCKET\":\"public-media\",\"S3_REGION\":\"us-east-1\",\"S3_ACCESS_KEY_ID\":\"$s3_access\",\"S3_SECRET_ACCESS_KEY\":\"$s3_secret\"}}"
  write_kv oauth2-proxy/prod "{\"data\":{\"OAUTH2_PROXY_CLIENT_ID\":\"oauth2-proxy\",\"OAUTH2_PROXY_CLIENT_SECRET\":\"$oauth_secret\",\"OAUTH2_PROXY_COOKIE_SECRET\":\"$oauth_cookie\",\"OAUTH2_PROXY_REDIRECT_URL\":\"https://oauth2.example.com/oauth2/callback\"}}"
  write_kv keycloak/prod "{\"data\":{\"KEYCLOAK_ADMIN_REALM\":\"$KEYCLOAK_REALM\",\"KEYCLOAK_ADMIN_CLIENT_ID\":\"website-admin-sync\",\"KEYCLOAK_ADMIN_CLIENT_SECRET\":\"$admin_secret\"}}"
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
}

main() {
  require_root
  install_missing_dependencies
  enable_docker
  write_env_file
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  write_stack_files
  configure_firewall
  pull_and_start_stack
  wait_for_openbao
  init_and_unseal_openbao
  bootstrap_openbao
  wait_for_keycloak
  bootstrap_keycloak
  print_approle

  echo ""
  echo "CAId provisioning complete."
  echo "Keycloak: https://$AUTH_HOST"
  echo "OpenBao:  https://$BAO_HOST"
}

main "$@"
