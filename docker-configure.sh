#!/usr/bin/env bash

# ==========================================================
# Xray LogReader — изменение локальных настроек VPS.
#
# Скрипт изменяет docker-compose.override.yml, который:
#
# - не попадает в Git;
# - не перезаписывается docker-update.sh;
# - содержит реальные настройки конкретного VPS.
#
# Неуказанные параметры сохраняют предыдущие значения.
#
# После изменения настроек контейнер пересоздаётся автоматически.
#
# Примеры:
#
# Изменить только ServerID:
# sudo bash docker-configure.sh --server_id="2"
#
# Изменить только API URL:
# sudo bash docker-configure.sh --request_url="https://s19.wiserv.ru/api/logreader/connection"
#
# Изменить только путь к Xray-логам:
# sudo bash docker-configure.sh --xray_logs_path="/var/log/xray"
#
# Изменить cooldown на один час:
# sudo bash docker-configure.sh --cooldown_ms="3600000"
#
# Отключить info-логи:
# sudo bash docker-configure.sh --info_enabled="false"
#
# Показать текущие параметры:
# sudo bash docker-configure.sh --show
# ==========================================================

set -euo pipefail

cd /

PROJECT_DIRECTORY="/opt/xray-logreader"
VPS_CONFIG_FILE=".vps-config"
COMPOSE_OVERRIDE_FILE="docker-compose.override.yml"

SERVER_ID=""
REQUEST_URL=""
XRAY_LOGS_PATH=""
LOG_PATH=""
INTERVAL_MS=""
TIMEOUT_MS=""
COOLDOWN_MS=""
STATE_SAVE_INTERVAL_MS=""
INFO_ENABLED=""
INFO_LOG_PATH=""
ERROR_ENABLED=""
ERROR_LOG_PATH=""
RETAINED_LOG_FILES=""
SHOW_CONFIGURATION=0

for ARGUMENT in "$@"; do
    case "${ARGUMENT}" in
        --server_id=*) SERVER_ID="${ARGUMENT#*=}" ;;
        --request_url=*) REQUEST_URL="${ARGUMENT#*=}" ;;
        --xray_logs_path=*) XRAY_LOGS_PATH="${ARGUMENT#*=}" ;;
        --log_path=*) LOG_PATH="${ARGUMENT#*=}" ;;
        --interval_ms=*) INTERVAL_MS="${ARGUMENT#*=}" ;;
        --timeout_ms=*) TIMEOUT_MS="${ARGUMENT#*=}" ;;
        --cooldown_ms=*) COOLDOWN_MS="${ARGUMENT#*=}" ;;
        --state_save_interval_ms=*) STATE_SAVE_INTERVAL_MS="${ARGUMENT#*=}" ;;
        --info_enabled=*) INFO_ENABLED="${ARGUMENT#*=}" ;;
        --info_log_path=*) INFO_LOG_PATH="${ARGUMENT#*=}" ;;
        --error_enabled=*) ERROR_ENABLED="${ARGUMENT#*=}" ;;
        --error_log_path=*) ERROR_LOG_PATH="${ARGUMENT#*=}" ;;
        --retained_log_files=*) RETAINED_LOG_FILES="${ARGUMENT#*=}" ;;
        --show) SHOW_CONFIGURATION=1 ;;
        --project_dir=*) PROJECT_DIRECTORY="${ARGUMENT#*=}" ;;
        *)
            echo "ERROR: Unknown argument: ${ARGUMENT}" >&2
            echo "Use: sudo bash docker-configure.sh --show" >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script with sudo." >&2
    exit 1
fi

if [[ ! -d "${PROJECT_DIRECTORY}/.git" ]]; then
    echo "ERROR: Xray LogReader is not installed: ${PROJECT_DIRECTORY}" >&2
    exit 1
fi

cd "${PROJECT_DIRECTORY}"

if [[ ! -f "docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml was not found." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker or Docker Compose plugin is unavailable." >&2
    exit 1
fi

# Если скрипт используется впервые на старой установке,
# создаём конфигурацию с действующими базовыми параметрами.
if [[ ! -f "${VPS_CONFIG_FILE}" ]]; then
    OLD_SERVER_ID="1"
    OLD_REQUEST_URL="https://example.com/api/logreader/connection"
    OLD_XRAY_LOGS_PATH="/var/log/xray"

    if [[ -f "${COMPOSE_OVERRIDE_FILE}" ]]; then
        OLD_SERVER_ID="$(sed -n 's/^[[:space:]]*Logreader__ServerID:[[:space:]]*"\([^"]*\)".*/\1/p' "${COMPOSE_OVERRIDE_FILE}" | head -n 1)"
        OLD_REQUEST_URL="$(sed -n "s/^[[:space:]]*Logreader__RequestUrl:[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "${COMPOSE_OVERRIDE_FILE}" | head -n 1)"
        OLD_XRAY_LOGS_PATH="$(sed -n "s/^[[:space:]]*-[[:space:]]*['\"]\?\([^:'\"]*\):\/var\/log\/xray:ro['\"]\?.*/\1/p" "${COMPOSE_OVERRIDE_FILE}" | head -n 1)"

        OLD_SERVER_ID="${OLD_SERVER_ID:-1}"
        OLD_REQUEST_URL="${OLD_REQUEST_URL:-https://example.com/api/logreader/connection}"
        OLD_XRAY_LOGS_PATH="${OLD_XRAY_LOGS_PATH:-/var/log/xray}"
    fi

    cat > "${VPS_CONFIG_FILE}" <<EOF
CONFIG_SERVER_ID="${OLD_SERVER_ID}"
CONFIG_REQUEST_URL="${OLD_REQUEST_URL}"
CONFIG_XRAY_LOGS_PATH="${OLD_XRAY_LOGS_PATH}"
CONFIG_LOG_PATH="/var/log/xray/access.log"
CONFIG_INTERVAL_MS="500"
CONFIG_TIMEOUT_MS="5000"
CONFIG_COOLDOWN_MS="86400000"
CONFIG_STATE_SAVE_INTERVAL_MS="60000"
CONFIG_INFO_ENABLED="false"
CONFIG_INFO_LOG_PATH="/app/logs/info/log-.txt"
CONFIG_ERROR_ENABLED="true"
CONFIG_ERROR_LOG_PATH="/app/logs/error/log-.txt"
CONFIG_RETAINED_LOG_FILES="30"
EOF

    chmod 600 "${VPS_CONFIG_FILE}"
fi

# .vps-config создаётся только этим скриптом.
# shellcheck disable=SC1090
source "${VPS_CONFIG_FILE}"

if [[ "${SHOW_CONFIGURATION}" -eq 1 ]]; then
    echo "=========================================================="
    echo "Current Xray LogReader configuration:"
    echo "=========================================================="
    cat "${VPS_CONFIG_FILE}"
    exit 0
fi

SERVER_ID="${SERVER_ID:-${CONFIG_SERVER_ID}}"
REQUEST_URL="${REQUEST_URL:-${CONFIG_REQUEST_URL}}"
XRAY_LOGS_PATH="${XRAY_LOGS_PATH:-${CONFIG_XRAY_LOGS_PATH}}"
LOG_PATH="${LOG_PATH:-${CONFIG_LOG_PATH}}"
INTERVAL_MS="${INTERVAL_MS:-${CONFIG_INTERVAL_MS}}"
TIMEOUT_MS="${TIMEOUT_MS:-${CONFIG_TIMEOUT_MS}}"
COOLDOWN_MS="${COOLDOWN_MS:-${CONFIG_COOLDOWN_MS}}"
STATE_SAVE_INTERVAL_MS="${STATE_SAVE_INTERVAL_MS:-${CONFIG_STATE_SAVE_INTERVAL_MS}}"
INFO_ENABLED="${INFO_ENABLED:-${CONFIG_INFO_ENABLED}}"
INFO_LOG_PATH="${INFO_LOG_PATH:-${CONFIG_INFO_LOG_PATH}}"
ERROR_ENABLED="${ERROR_ENABLED:-${CONFIG_ERROR_ENABLED}}"
ERROR_LOG_PATH="${ERROR_LOG_PATH:-${CONFIG_ERROR_LOG_PATH}}"
RETAINED_LOG_FILES="${RETAINED_LOG_FILES:-${CONFIG_RETAINED_LOG_FILES}}"

if [[ ! "${SERVER_ID}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --server_id must be a positive integer." >&2
    exit 1
fi

if [[ ! "${REQUEST_URL}" =~ ^https?://[^[:space:]]+$ ]] || [[ "${REQUEST_URL}" == *"'"* ]]; then
    echo "ERROR: --request_url must be HTTP/HTTPS URL without spaces or single quotes." >&2
    exit 1
fi

if [[ "${XRAY_LOGS_PATH}" != /* ]] || [[ ! -d "${XRAY_LOGS_PATH}" ]] || [[ "${XRAY_LOGS_PATH}" == *"'"* ]]; then
    echo "ERROR: --xray_logs_path must be an existing absolute directory." >&2
    exit 1
fi

if [[ "${LOG_PATH}" != /var/log/xray/* ]] || [[ "${LOG_PATH}" == *"'"* ]]; then
    echo "ERROR: --log_path must start with /var/log/xray/." >&2
    exit 1
fi

for VALUE_NAME in INTERVAL_MS TIMEOUT_MS COOLDOWN_MS STATE_SAVE_INTERVAL_MS RETAINED_LOG_FILES; do
    VALUE="${!VALUE_NAME}"

    if [[ ! "${VALUE}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${VALUE_NAME} must be a non-negative integer." >&2
        exit 1
    fi
done

INFO_ENABLED="${INFO_ENABLED,,}"
ERROR_ENABLED="${ERROR_ENABLED,,}"

if [[ "${INFO_ENABLED}" != "true" && "${INFO_ENABLED}" != "false" ]]; then
    echo "ERROR: --info_enabled must be true or false." >&2
    exit 1
fi

if [[ "${ERROR_ENABLED}" != "true" && "${ERROR_ENABLED}" != "false" ]]; then
    echo "ERROR: --error_enabled must be true or false." >&2
    exit 1
fi

for PATH_VALUE in "${INFO_LOG_PATH}" "${ERROR_LOG_PATH}"; do
    if [[ "${PATH_VALUE}" != /app/logs/* ]] || [[ "${PATH_VALUE}" == *"'"* ]]; then
        echo "ERROR: Log file paths must start with /app/logs/." >&2
        exit 1
    fi
done

cat > "${VPS_CONFIG_FILE}" <<EOF
CONFIG_SERVER_ID="${SERVER_ID}"
CONFIG_REQUEST_URL="${REQUEST_URL}"
CONFIG_XRAY_LOGS_PATH="${XRAY_LOGS_PATH}"
CONFIG_LOG_PATH="${LOG_PATH}"
CONFIG_INTERVAL_MS="${INTERVAL_MS}"
CONFIG_TIMEOUT_MS="${TIMEOUT_MS}"
CONFIG_COOLDOWN_MS="${COOLDOWN_MS}"
CONFIG_STATE_SAVE_INTERVAL_MS="${STATE_SAVE_INTERVAL_MS}"
CONFIG_INFO_ENABLED="${INFO_ENABLED}"
CONFIG_INFO_LOG_PATH="${INFO_LOG_PATH}"
CONFIG_ERROR_ENABLED="${ERROR_ENABLED}"
CONFIG_ERROR_LOG_PATH="${ERROR_LOG_PATH}"
CONFIG_RETAINED_LOG_FILES="${RETAINED_LOG_FILES}"
EOF

chmod 600 "${VPS_CONFIG_FILE}"

cat > "${COMPOSE_OVERRIDE_FILE}" <<EOF
services:
  xray-logreader:
    environment:
      Logreader__ServerID: "${SERVER_ID}"
      Logreader__LogPath: "${LOG_PATH}"
      Logreader__IntervalMilliseconds: "${INTERVAL_MS}"
      Logreader__RequestUrl: '${REQUEST_URL}'
      Logreader__RequestTimeoutMilliseconds: "${TIMEOUT_MS}"
      Logreader__RequestCooldownMilliseconds: "${COOLDOWN_MS}"
      Logreader__StateSaveIntervalMilliseconds: "${STATE_SAVE_INTERVAL_MS}"
      FileLogging__InfoEnabled: "${INFO_ENABLED}"
      FileLogging__InfoLogPath: "${INFO_LOG_PATH}"
      FileLogging__ErrorEnabled: "${ERROR_ENABLED}"
      FileLogging__ErrorLogPath: "${ERROR_LOG_PATH}"
      FileLogging__RetainedFileCountLimit: "${RETAINED_LOG_FILES}"

    volumes:
      - '${XRAY_LOGS_PATH}:/var/log/xray:ro'
EOF

chmod 600 "${COMPOSE_OVERRIDE_FILE}"

echo "=========================================================="
echo "Applying configuration..."
echo "=========================================================="

docker compose up --detach --force-recreate --remove-orphans

echo
echo "Configuration applied successfully."

docker compose ps
