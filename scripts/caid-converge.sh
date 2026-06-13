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

main() {
  require_root
  load_env

  cd "$CAID_HOME"
  token="$(root_token)"
  ensure_runtime_policy "$token"
  ensure_openbao_admin_policy "$token"
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
