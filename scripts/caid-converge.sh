#!/usr/bin/env bash
set -euo pipefail

CAID_HOME="${CAID_HOME:-/srv/caid}"
CAID_STATE_DIR="${CAID_STATE_DIR:-/etc/caid}"
ENV_FILE="${ENV_FILE:-$CAID_STATE_DIR/caid.env}"
RECOVERY_FILE="${RECOVERY_FILE:-$CAID_STATE_DIR/openbao-init.json}"
MODE="${MODE:-noninteractive}"

while (($#)); do
  case "$1" in
    --mode)
      MODE="${2:?Missing value for --mode}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root, for example: sudo bash scripts/caid-converge.sh --mode noninteractive" >&2
    exit 1
  fi
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

root_token() {
  if [[ ! -f "$RECOVERY_FILE" ]]; then
    echo "Missing OpenBao recovery file: $RECOVERY_FILE" >&2
    exit 1
  fi

  node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(data.root_token)" "$RECOVERY_FILE"
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$CAID_HOME/docker-compose.yaml" "$@"
}

random_b64url() {
  local bytes="${1:-32}"
  openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '=\n'
}

ensure_runtime_policy() {
  local source_policy="$CAID_HOME/scripts/policies/website-runtime.hcl"
  local target_policy="$CAID_HOME/openbao/policies/website-runtime.hcl"

  if [[ ! -f "$source_policy" ]]; then
    echo "Missing source website runtime policy file: $source_policy" >&2
    exit 1
  fi

  install -m 0644 "$source_policy" "$target_policy"

  if [[ ! -f "$target_policy" ]]; then
    echo "Missing website runtime policy file." >&2
    exit 1
  fi

  compose exec -T openbao env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$1" \
    bao policy write "${APP_POLICY_NAME:-website-runtime}" /openbao/policies/website-runtime.hcl >/dev/null
}

ensure_openbao_admin_policy() {
  local token="$1"
  local target_policy="$CAID_HOME/openbao/policies/openbao-admin.hcl"

  if [[ ! -f "$target_policy" ]]; then
    cat >"$target_policy" <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
    chmod 0644 "$target_policy"
  fi

  compose exec -T openbao env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$token" \
    bao policy write openbao-admin /openbao/policies/openbao-admin.hcl >/dev/null
}

bao_root() {
  local token="$1"
  shift
  compose exec -T openbao env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" "$@"
}

read_kv_field() {
  local token="$1"
  local path_name="$2"
  local key="$3"

  bao_root "$token" bao read -format=json "${BAO_KV_MOUNT:-kv}/data/$path_name" 2>/dev/null |
    node -e "const fs=require('fs');let input='';process.stdin.on('data',c=>input+=c);process.stdin.on('end',()=>{if(!input.trim())return;const data=JSON.parse(input);process.stdout.write(data?.data?.data?.[process.argv[1]] || '')})" "$key" || true
}

write_kv_payload() {
  local token="$1"
  local path_name="$2"
  local payload="$3"
  local encoded

  encoded="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  compose exec -T openbao sh -lc "printf '%s' '$encoded' | base64 -d > /tmp/caid-converge-payload.json && BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$token' bao write '${BAO_KV_MOUNT:-kv}/data/$path_name' @/tmp/caid-converge-payload.json >/dev/null"
}

ensure_openbao_oidc_secret() {
  local token="$1"
  local secret

  secret="${OPENBAO_OIDC_CLIENT_SECRET:-}"
  if [[ -z "$secret" ]]; then
    secret="$(read_kv_field "$token" caid/config-values/openbao OPENBAO_OIDC_CLIENT_SECRET)"
  fi
  if [[ -z "$secret" ]]; then
    secret="$(random_b64url 32)"
    write_kv_payload "$token" caid/config-values/openbao "{\"data\":{\"OPENBAO_OIDC_CLIENT_SECRET\":\"$secret\"}}"
  fi

  printf '%s' "$secret"
}

kcadm() {
  compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" </dev/null
}

keycloak_client_id() {
  local client_id="$1"
  kcadm get clients -r "$KEYCLOAK_REALM" -q "clientId=$client_id" --fields id --format csv | tail -n 1 | tr -d '"\r'
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
  fi
}

ensure_keycloak_client() {
  local client_id="$1"
  local secret="$2"
  local redirect_uri="$3"
  local web_origin="$4"
  local service_account="${5:-false}"
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
    kcadm update "clients/$id" -r "$KEYCLOAK_REALM" -f "$json_file" >/dev/null
  else
    kcadm create clients -r "$KEYCLOAK_REALM" -f "$json_file" >/dev/null
    id="$(keycloak_client_id "$client_id")"
  fi

  printf '%s' "$id"
}

ensure_groups_mapper() {
  local client_uuid="$1"
  local existing

  existing="$(kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" --fields id,name --format csv |
    awk -F, '$2 == "\"groups\"" { gsub(/"/, "", $1); print $1; exit }' || true)"
  if [[ -n "$existing" ]]; then
    return
  fi

  kcadm create "clients/$client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
    -s "name=groups" \
    -s "protocol=openid-connect" \
    -s "protocolMapper=oidc-group-membership-mapper" \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
}

ensure_keycloak_identity_roles() {
  local openbao_secret="$1"
  local website_uuid openbao_uuid

  kcadm config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  kcadm update "authentication/required-actions/CONFIGURE_TOTP" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s defaultAction=true >/dev/null 2>&1 || true

  website_uuid="$(keycloak_client_id website)"
  openbao_uuid="$(ensure_keycloak_client openbao "$openbao_secret" "https://$BAO_HOST/ui/vault/auth/oidc/oidc/callback" "https://$BAO_HOST" false)"

  for role in owner media_admin editor viewer infra_admin identity_hr_manager config_admin audit_admin logging_admin openbao_admin rustfs_admin netbird_admin technician print_admin queue_admin upload_quota_1kb upload_quota_250mb upload_quota_1gb; do
    kcadm create "clients/$website_uuid/roles" -r "$KEYCLOAK_REALM" -s "name=$role" >/dev/null 2>&1 || true
    ensure_keycloak_group "$role"
  done

  ensure_groups_mapper "$website_uuid"
  ensure_groups_mapper "$openbao_uuid"
}

ensure_openbao_oidc() {
  local token="$1"
  local openbao_secret="$2"
  local role_payload encoded

  role_payload="$(BAO_HOST_VALUE="$BAO_HOST" node -e "
const host = process.env.BAO_HOST_VALUE;
process.stdout.write(JSON.stringify({
  user_claim: 'email',
  groups_claim: 'groups',
  allowed_redirect_uris: [
    'https://' + host + '/ui/vault/auth/oidc/oidc/callback',
    'http://localhost:8250/oidc/callback'
  ],
  bound_claims: { groups: 'openbao_admin' },
  policies: ['openbao-admin'],
  ttl: '1h'
}));
")"

  bao_root "$token" bao auth enable oidc >/dev/null 2>&1 || true
  bao_root "$token" bao write auth/oidc/config \
    oidc_discovery_url="https://$AUTH_HOST/realms/$KEYCLOAK_REALM" \
    oidc_client_id="openbao" \
    oidc_client_secret="$openbao_secret" \
    default_role="openbao-admin" >/dev/null
  encoded="$(printf '%s' "$role_payload" | base64 | tr -d '\n')"
  compose exec -T openbao sh -lc "printf '%s' '$encoded' | base64 -d > /tmp/openbao-oidc-role.json && BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='$token' bao write auth/oidc/role/openbao-admin @/tmp/openbao-oidc-role.json >/dev/null"
}

ensure_identity_plane() {
  local token="$1"
  local openbao_secret

  openbao_secret="$(ensure_openbao_oidc_secret "$token")"
  ensure_keycloak_identity_roles "$openbao_secret"
  ensure_openbao_oidc "$token" "$openbao_secret"
}

main() {
  require_root
  load_env

  cd "$CAID_HOME"
  token="$(root_token)"
  ensure_runtime_policy "$token"
  ensure_openbao_admin_policy "$token"
  ensure_identity_plane "$token"
  converge_bao_addr="${BAO_CONVERGE_ADDR:-}"
  if [[ -z "$converge_bao_addr" ]]; then
    if [[ -n "${BAO_HOST:-}" ]]; then
      converge_bao_addr="https://$BAO_HOST"
    else
      converge_bao_addr="http://127.0.0.1:8200"
    fi
  fi

  BAO_ADDR="$converge_bao_addr" \
    BAO_TOKEN="$token" \
    BAO_KV_MOUNT="${BAO_KV_MOUNT:-kv}" \
    NETBIRD_HOST="${NETBIRD_HOST:-}" \
    NETBIRD_OIDC_CLIENT_SECRET="${NETBIRD_OIDC_CLIENT_SECRET:-}" \
    GRAFANA_HOST="${GRAFANA_HOST:-}" \
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}" \
    node scripts/caid-converge.mjs --mode "$MODE"
}

main "$@"
