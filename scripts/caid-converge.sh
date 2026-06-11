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
  if [[ ! -f "$CAID_HOME/openbao/policies/website-runtime.hcl" ]]; then
    echo "Missing website runtime policy file." >&2
    exit 1
  fi

  compose exec -T openbao env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$1" \
    bao policy write "${APP_POLICY_NAME:-website-runtime}" /openbao/policies/website-runtime.hcl >/dev/null
}

main() {
  require_root
  load_env

  cd "$CAID_HOME"
  token="$(root_token)"
  ensure_runtime_policy "$token"
  BAO_ADDR="${BAO_LOCAL_ADDR:-http://127.0.0.1:8200}" \
    BAO_TOKEN="$token" \
    BAO_KV_MOUNT="${BAO_KV_MOUNT:-kv}" \
    node scripts/caid-converge.mjs --mode "$MODE"
}

main "$@"
