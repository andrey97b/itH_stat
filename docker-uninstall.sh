#!/usr/bin/env bash

# ==========================================================
# Xray LogReader — удаление с VPS.
#
# Обычный запуск:
# sudo ./docker-uninstall.sh
#
# Полное удаление, включая state JSON, логи и VPS-конфигурацию:
# sudo ./docker-uninstall.sh --purge
#
# Скрипт не удаляет:
# - Docker Engine;
# - Docker Compose plugin;
# - Xray / 3x-ui;
# - /var/log/xray;
# ==========================================================

set -u

PROJECT_DIRECTORY="/opt/xray-logreader"
PURGE_DATA=0

for ARGUMENT in "$@"; do
    case "${ARGUMENT}" in
        --purge)
            PURGE_DATA=1
            ;;

        *)
            echo "ERROR: Unknown argument: ${ARGUMENT}" >&2
            echo "Usage: sudo $0 [--purge]" >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script with sudo." >&2
    exit 1
fi

if [[ ! -d "${PROJECT_DIRECTORY}" ]]; then
    echo "Xray LogReader directory was not found: ${PROJECT_DIRECTORY}"
    exit 0
fi

cd "${PROJECT_DIRECTORY}" || exit 1

echo "=========================================================="
echo "Stopping and removing Xray LogReader container..."
echo "=========================================================="

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if [[ -f "docker-compose.yml" ]]; then
        docker compose down --remove-orphans || echo "WARNING: Docker Compose could not fully stop the container."
    else
        docker rm --force xray-logreader 2>/dev/null || true
    fi

    echo
    echo "Removing local Docker image: xray-logreader:current"

    docker image rm --force xray-logreader:current 2>/dev/null || true
else
    echo "WARNING: Docker or Docker Compose is unavailable."
    echo "WARNING: Only local files can be removed."
fi

if [[ "${PURGE_DATA}" -eq 1 ]]; then
    echo
    echo "=========================================================="
    echo "Removing all Xray LogReader data..."
    echo "=========================================================="

    rm -rf "${PROJECT_DIRECTORY}"

    echo "Removed:"
    echo "${PROJECT_DIRECTORY}"
else
    echo
    echo "=========================================================="
    echo "Container and current image were removed."
    echo "=========================================================="

    echo "The following data was preserved:"
    echo "${PROJECT_DIRECTORY}/data"
    echo "${PROJECT_DIRECTORY}/logs"
    echo "${PROJECT_DIRECTORY}/docker-compose.override.yml"

    echo
    echo "To remove everything permanently, run:"
    echo "sudo $0 --purge"
fi
