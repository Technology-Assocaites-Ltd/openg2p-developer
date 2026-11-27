#!/usr/bin/env bash
# First-time bring-up of PBMS (Odoo + staff API + Celery) and the registry
# connector against the Docker VSSS stack that is already running.
#
# Does not recreate VSSS, and does not start a second native registry.
# SPAR and G2P Bridge are a later step (PBMS_WITH_SPAR / PBMS_WITH_BRIDGE stay false).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/run-service.sh"

OPENG2P_WORKSPACE="$(workspace_open)"
CONNECTOR_API_DIR="${OPENG2P_WORKSPACE}/registry-connector/api"
PARTNER_PORT="${VSSS_REGISTRY_PARTNER_API_PORT:-8022}"
CONNECTOR_PORT="${CONNECTOR_APP_PORT:-8070}"
CONNECTOR_DB_NAME="${CONNECTOR_DB_DBNAME:-connector}"
CONNECTOR_REDIS_DB="${CONNECTOR_REDIS_DB:-4}"

set_env_key() {
  local key="$1" value="$2" file="${ROOT_DIR}/.env"
  if grep -q "^${key}=" "$file"; then
    # macOS sed needs a backup suffix; empty string is fine.
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$file"
  fi
  export "${key}=${value}"
}

echo "==> VSSS partner API must already be up (Docker) ..."
partner_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PARTNER_PORT}/ping" || true)"
if [[ "$partner_code" != "200" ]]; then
  echo "VSSS partner API on :${PARTNER_PORT} returned '${partner_code}', not 200." >&2
  echo "Start it first: make docker-vsss-up" >&2
  exit 1
fi
echo "Partner API http://127.0.0.1:${PARTNER_PORT}/ping -> 200"

echo "==> Point PBMS at the Docker VSSS database (no native registry) ..."
set_env_key PBMS_REGISTRY_VARIANT village-social-security-registry
set_env_key PBMS_WITH_REGISTRY false
set_env_key PBMS_WITH_SPAR false
set_env_key PBMS_WITH_BRIDGE false

echo "==> Clone Odoo + PBMS (only repos that are not already on disk) ..."
keys=()
[[ -f "${OPENG2P_WORKSPACE}/odoo17/odoo-bin" ]] || keys+=(odoo)
[[ -d "${OPENG2P_WORKSPACE}/openg2p-odoo-commons/.git" ]] || keys+=(odoo_commons)
[[ -f "${OPENG2P_WORKSPACE}/pbms/odoo/g2p_pbms/__manifest__.py" ]] || keys+=(pbms)
[[ -d "${OPENG2P_WORKSPACE}/pbms-connectors/extensions/registry-adapters" ]] || keys+=(pbms_connectors)
[[ -f "${OPENG2P_WORKSPACE}/registry-connector/api/pyproject.toml" ]] || keys+=(registry_connector)
if [[ ${#keys[@]} -gt 0 ]]; then
  CLONE_REPO_KEYS="${keys[*]}" bash "${ROOT_DIR}/scripts/clone-repos.sh"
else
  echo "Odoo, Odoo Commons, PBMS, and the registry connector are already present."
fi

echo "==> Generate PBMS env (registry DB = vsss_registry_db) ..."
bash "${ROOT_DIR}/scripts/generate-config.sh"
if ! grep -q 'vsss_registry_db' "${ROOT_DIR}/generated/pbms/celery-workers.env"; then
  echo "generated/pbms/celery-workers.env is not pointed at vsss_registry_db" >&2
  exit 1
fi

echo "==> Install PBMS Python deps and migrate databases ..."
make install-odoo
make install-pbms-bg-tasks
# Install the PBMS Odoo apps on the first init. A later Apps-menu click is not required.
export PBMS_ODOO_INIT_MODULES="${PBMS_ODOO_INIT_MODULES:-base,queue_job,g2p_pbms}"
make pbms-init
# make pbms-init stops once ir_module_module exists, even when g2p_pbms
# never finished installing. Install the missing apps in that case.
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/pbms-odoo.sh"
pbms_odoo_load_env
g2p_state="$(PGPASSWORD="${PBMS_DB_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${PBMS_DB_USER}" -d "${PBMS_DB_NAME}" -tAc "SELECT state FROM ir_module_module WHERE name = 'g2p_pbms'" || true)"
if [[ "${g2p_state}" != "installed" ]]; then
  echo "==> Installing g2p_pbms (current state: ${g2p_state:-missing}) ..."
  "$(pbms_odoo_python_bin)" "${ODOO_PATH}/odoo-bin" -c "${PBMS_ODOO_CONF}" \
    -d "${PBMS_DB_NAME}" -i "${PBMS_ODOO_INIT_MODULES}" --stop-after-init --without-demo=all
fi
make init-pbms-bg-tasks

echo "==> Start PBMS staff API + Celery beat + worker ..."
bash "${ROOT_DIR}/scripts/start-pbms-bg-tasks.sh"

echo "==> Start PBMS Odoo in the background ..."
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/pbms-odoo.sh"
pbms_odoo_load_env
run_service_stop "pbms-odoo" "odoo-bin" "${PBMS_ODOO_CONF}"
run_service "pbms-odoo" "${ODOO_PATH}" "${ROOT_DIR}/.env" \
  python "${ODOO_PATH}/odoo-bin" -c "${PBMS_ODOO_CONF}"

echo "==> Connector database + env ..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql \
  -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_SUPERUSER:-postgres}" -d postgres \
  -tc "SELECT 1 FROM pg_database WHERE datname = '${CONNECTOR_DB_NAME}'" | grep -q 1 \
  || PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_SUPERUSER:-postgres}" -d postgres \
    -c "CREATE DATABASE ${CONNECTOR_DB_NAME};"

if [[ ! -d "${CONNECTOR_API_DIR}/.git" && ! -f "${CONNECTOR_API_DIR}/pyproject.toml" ]]; then
  echo "Missing ${CONNECTOR_API_DIR}" >&2
  exit 1
fi

cat > "${CONNECTOR_API_DIR}/.env" <<EOF
CONNECTOR_APP_HOST=0.0.0.0
CONNECTOR_APP_PORT=${CONNECTOR_PORT}
CONNECTOR_LOG_LEVEL=INFO
CONNECTOR_DB_DRIVER=postgresql+asyncpg
CONNECTOR_DB_HOSTNAME=${POSTGRES_HOST}
CONNECTOR_DB_PORT=${POSTGRES_PORT}
CONNECTOR_DB_USERNAME=${POSTGRES_SUPERUSER:-postgres}
CONNECTOR_DB_PASSWORD=${POSTGRES_PASSWORD}
CONNECTOR_DB_DBNAME=${CONNECTOR_DB_NAME}
CONNECTOR_PARTNER_INGEST_BASE_URL=http://127.0.0.1:${PARTNER_PORT}
CONNECTOR_PARTNER_INGEST_TIMEOUT=30
CONNECTOR_CELERY_BROKER_URL=redis://${REDIS_HOST}:${REDIS_PORT}/${CONNECTOR_REDIS_DB}
CONNECTOR_CELERY_RESULT_BACKEND=redis://${REDIS_HOST}:${REDIS_PORT}/${CONNECTOR_REDIS_DB}
CONNECTOR_WORKER_MAX_ATTEMPTS=5
CONNECTOR_OTEL_ENABLED=false
CONNECTOR_STORE_RUN_PAYLOADS=true
CONNECTOR_STRICT_INCREMENTAL=true
CONNECTOR_REGISTRY_DB_DSN=postgresql://${POSTGRES_SUPERUSER:-postgres}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/vsss_registry_db
CONNECTOR_MASTER_DATA_DB_DSN=postgresql://${POSTGRES_SUPERUSER:-postgres}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/vsss_master_data_db
EOF

if [[ ! -x "${CONNECTOR_API_DIR}/venv/bin/python" ]]; then
  python3 -m venv "${CONNECTOR_API_DIR}/venv"
fi
(
  cd "${CONNECTOR_API_DIR}"
  # shellcheck disable=SC1091
  source venv/bin/activate
  pip install -e .
)

echo "==> Start connector API + Celery ..."
run_service_stop "vsss-connector-api" "openg2p_connector_service.main" "${CONNECTOR_API_DIR}"
run_service_stop "vsss-connector-worker" "openg2p_connector_service.worker worker" "${CONNECTOR_API_DIR}"
run_service_stop "vsss-connector-beat" "openg2p_connector_service.worker beat" "${CONNECTOR_API_DIR}"

run_service "vsss-connector-api" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/python" -m openg2p_connector_service.main
run_service "vsss-connector-worker" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/celery" -A openg2p_connector_service.worker worker --loglevel=info
run_service "vsss-connector-beat" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/celery" -A openg2p_connector_service.worker beat --loglevel=info --schedule=/tmp/celery-beat-vsss-connector.db

echo "==> Checks ..."
fail=0
check() {
  local name="$1" url="$2" expect="${3:-200}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  if [[ "$code" == "$expect" ]]; then
    echo "OK  ${name} ${url} -> ${code}"
  else
    echo "FAIL ${name} ${url} -> ${code} (wanted ${expect})" >&2
    fail=1
  fi
}

# Odoo can take a while to bind.
for _ in $(seq 1 30); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PBMS_HTTP_PORT:-8069}/web/login" || true)"
  [[ "$code" == "200" || "$code" == "303" ]] && break
  sleep 2
done

check "VSSS partner" "http://127.0.0.1:${PARTNER_PORT}/ping" 200
check "PBMS staff API" "http://127.0.0.1:${PBMS_STAFF_API_PORT:-8050}/docs" 200
check "PBMS Odoo" "http://127.0.0.1:${PBMS_HTTP_PORT:-8069}/web/login" 200
check "Connector" "http://127.0.0.1:${CONNECTOR_PORT}/health" 200
check "Connector ready" "http://127.0.0.1:${CONNECTOR_PORT}/health/ready" 200

if pgrep -f "openg2p_bg_task_celery_beat_producers.main.celery_app beat" >/dev/null; then
  echo "OK  PBMS celery beat is running"
else
  echo "FAIL PBMS celery beat is not running" >&2
  fail=1
fi
if pgrep -f "bg_task_worker_queue" >/dev/null; then
  echo "OK  PBMS celery worker is running"
else
  echo "FAIL PBMS celery worker is not running" >&2
  fail=1
fi
if pgrep -f "openg2p_connector_service.worker worker" >/dev/null; then
  echo "OK  connector celery worker is running"
else
  echo "FAIL connector celery worker is not running" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "One or more checks failed. Logs: ${ROOT_DIR}/generated/run/" >&2
  exit 1
fi

echo
echo "PBMS and the connector are up against Docker VSSS."
echo "  VSSS partner : http://127.0.0.1:${PARTNER_PORT}/docs"
echo "  PBMS Odoo    : http://127.0.0.1:${PBMS_HTTP_PORT:-8069}"
echo "  PBMS API     : http://127.0.0.1:${PBMS_STAFF_API_PORT:-8050}/docs"
echo "  Connector    : http://127.0.0.1:${CONNECTOR_PORT}/health"
echo "  Registry DB  : vsss_registry_db (PBMS Celery SR connection)"
echo "SPAR and G2P Bridge are not started. Next step when you want disbursement."
