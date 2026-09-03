#!/usr/bin/env bash

# ==========================================================
# Xray LogReader — первичная установка.
#
# Скрипт:
#   1. Устанавливает зависимости Docker на чистом Ubuntu VPS.
#   2. Клонирует Git-репозиторий в /opt/xray-logreader.
#   3. Создаёт локальный docker-compose.override.yml.
#   4. Загружает latest Gitea Release.
#   5. Запускает контейнер.
#
# Скрипт предназначен только для первого запуска.
# Для обновления существующей установки используйте docker-update.sh.
# ==========================================================

set -euo pipefail

# Скрипт может быть запущен из каталога, удалённого предыдущим uninstall.
# Переходим в гарантированно существующую папку.
cd /


# ==========================================================
# Аргументы
# ==========================================================

GIT_REPOSITORY_URL=""
PRODUCTION_SERVER_ID=""
PRODUCTION_REQUEST_URL=""
XRAY_LOGS_HOST_PATH=""

for ARGUMENT in "$@"; do
    case "${ARGUMENT}" in
        --repo=*)
            GIT_REPOSITORY_URL="${ARGUMENT#*=}"
            ;;

        --server_id=*)
            PRODUCTION_SERVER_ID="${ARGUMENT#*=}"
            ;;

        --api_url=*)
            PRODUCTION_REQUEST_URL="${ARGUMENT#*=}"
            ;;

        --xray_logs_path=*)
            XRAY_LOGS_HOST_PATH="${ARGUMENT#*=}"
            ;;

        *)
            echo "ERROR: Unknown argument: ${ARGUMENT}" >&2
            echo "Usage: sudo $0 --repo=\"https://git.ithelper.online/OWNER/REPOSITORY.git\" --server_id=\"1\" --api_url=\"https://api.example.com/api/logreader/connection\" --xray_logs_path=\"/var/log/xray\"" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${GIT_REPOSITORY_URL}" ]]; then
    echo "ERROR: --repo parameter is required." >&2
    exit 1
fi

if [[ -z "${PRODUCTION_SERVER_ID}" ]]; then
    echo "ERROR: --server_id parameter is required." >&2
    exit 1
fi

if [[ -z "${PRODUCTION_REQUEST_URL}" ]]; then
    echo "ERROR: --api_url parameter is required." >&2
    exit 1
fi

if [[ -z "${XRAY_LOGS_HOST_PATH}" ]]; then
    echo "ERROR: --xray_logs_path parameter is required." >&2
    exit 1
fi


# ==========================================================
# Проверка переданных параметров
# ==========================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script with sudo." >&2
    exit 1
fi

if [[ ! "${PRODUCTION_SERVER_ID}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --server_id must be a positive integer." >&2
    exit 1
fi

if [[ ! "${PRODUCTION_REQUEST_URL}" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "ERROR: --api_url must start with http:// or https:// and contain no spaces." >&2
    exit 1
fi

if [[ "${PRODUCTION_REQUEST_URL}" == *"'"* ]]; then
    echo "ERROR: --api_url must not contain a single quote character." >&2
    exit 1
fi

if [[ "${XRAY_LOGS_HOST_PATH}" != /* ]]; then
    echo "ERROR: --xray_logs_path must be an absolute Linux path." >&2
    exit 1
fi

if [[ ! -d "${XRAY_LOGS_HOST_PATH}" ]]; then
    echo "ERROR: Xray logs directory does not exist: ${XRAY_LOGS_HOST_PATH}" >&2
    exit 1
fi

if [[ "${XRAY_LOGS_HOST_PATH}" == *"'"* ]]; then
    echo "ERROR: --xray_logs_path must not contain a single quote character." >&2
    exit 1
fi

if [[ ! -f "${XRAY_LOGS_HOST_PATH}/access.log" ]]; then
    echo "WARNING: ${XRAY_LOGS_HOST_PATH}/access.log does not exist yet. Xray LogReader will wait for it to appear." >&2
fi


# ==========================================================
# Постоянные настройки deployment
# ==========================================================

PROJECT_DIRECTORY="/opt/xray-logreader"
CURRENT_IMAGE_TAG="xray-logreader:current"
COMPOSE_OVERRIDE_FILE="docker-compose.override.yml"
RELEASE_MARKER_FILE=".image-tag"

log() {
    echo
    echo ">>> $*"
    echo
}


# ==========================================================
# Защита от повторной первичной установки
# ==========================================================

if [[ -d "${PROJECT_DIRECTORY}/.git" ]]; then
    echo "ERROR: Xray LogReader is already installed at ${PROJECT_DIRECTORY}." >&2
    echo "ERROR: Use docker-update.sh to update the existing installation." >&2
    exit 1
fi


# ==========================================================
# 1. Установка базовых системных пакетов
# ==========================================================

NEED_BASE_PACKAGES=()

for PACKAGE_NAME in ca-certificates curl git; do
    dpkg -s "${PACKAGE_NAME}" >/dev/null 2>&1 || NEED_BASE_PACKAGES+=("${PACKAGE_NAME}")
done

if [[ "${#NEED_BASE_PACKAGES[@]}" -gt 0 ]]; then
    log "Installing base packages: ${NEED_BASE_PACKAGES[*]}"

    apt-get update
    apt-get install -y "${NEED_BASE_PACKAGES[@]}"
else
    log "Base packages are already installed."
fi


# ==========================================================
# 2. Добавление Docker GPG key и APT repository
# ==========================================================

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f "/etc/apt/keyrings/docker.asc" ]]; then
    log "Adding Docker GPG key."

    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o "/etc/apt/keyrings/docker.asc"
    chmod a+r "/etc/apt/keyrings/docker.asc"
else
    log "Docker GPG key already exists."
fi

if [[ ! -f "/etc/apt/sources.list.d/docker.list" ]]; then
    log "Adding Docker APT repository."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee "/etc/apt/sources.list.d/docker.list" > /dev/null
else
    log "Docker APT repository already exists."
fi


# ==========================================================
# 3. Установка Docker Engine и Docker Compose plugin
# ==========================================================

NEED_DOCKER_PACKAGES=()

for PACKAGE_NAME in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    dpkg -s "${PACKAGE_NAME}" >/dev/null 2>&1 || NEED_DOCKER_PACKAGES+=("${PACKAGE_NAME}")
done

if [[ "${#NEED_DOCKER_PACKAGES[@]}" -gt 0 ]]; then
    log "Installing Docker packages: ${NEED_DOCKER_PACKAGES[*]}"

    apt-get update
    apt-get install -y "${NEED_DOCKER_PACKAGES[@]}"
else
    log "Docker Engine and Compose plugin are already installed."
fi


# ==========================================================
# 4. Запуск Docker
# ==========================================================

if ! systemctl is-active --quiet docker; then
    log "Starting and enabling Docker."

    systemctl enable --now docker
else
    log "Docker is already running."
fi


# ==========================================================
# 5. Проверка системных инструментов
# ==========================================================

for COMMAND_NAME in git curl docker grep sed mktemp; do
    if ! command -v "${COMMAND_NAME}" >/dev/null 2>&1; then
        echo "ERROR: Required command was not found: ${COMMAND_NAME}" >&2
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin is unavailable." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker Engine is unavailable or not running." >&2
    exit 1
fi


# ==========================================================
# 6. Проверка формата URL репозитория
# ==========================================================

if [[ ! "${GIT_REPOSITORY_URL}" =~ ^https?://[^/]+/[^/]+/[^/]+/?(\.git)?$ ]]; then
    echo "ERROR: Unsupported Git repository URL: ${GIT_REPOSITORY_URL}" >&2
    exit 1
fi


# ==========================================================
# 7. Клонирование проекта
# ==========================================================

log "Cloning Git repository."

git clone --depth 1 "${GIT_REPOSITORY_URL}" "${PROJECT_DIRECTORY}"

cd "${PROJECT_DIRECTORY}"

if [[ ! -f "docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml was not found in ${PROJECT_DIRECTORY}" >&2
    exit 1
fi


# ==========================================================
# 8. Создание локальной VPS-конфигурации
# ==========================================================

cat > "${COMPOSE_OVERRIDE_FILE}" <<EOF
# Generated by docker-install.sh.
# VPS-specific configuration. This file is ignored by Git.

services:
  xray-logreader:
    environment:
      Logreader__ServerID: "${PRODUCTION_SERVER_ID}"
      Logreader__RequestUrl: '${PRODUCTION_REQUEST_URL}'
      Logreader__LogPath: "/var/log/xray/access.log"

    volumes:
      - '${XRAY_LOGS_HOST_PATH}:/var/log/xray:ro'
EOF

chmod 600 "${COMPOSE_OVERRIDE_FILE}"

mkdir -p "data" "logs/info" "logs/error"


# ==========================================================
# 9. Получение latest GitHub Release
# ==========================================================

NORMALIZED_REPOSITORY_URL="${GIT_REPOSITORY_URL%/}"
NORMALIZED_REPOSITORY_URL="${NORMALIZED_REPOSITORY_URL%.git}"

REPOSITORY_PATH="$(printf '%s\n' "${NORMALIZED_REPOSITORY_URL}" | sed -E 's#^https?://github\.com/##')"
LATEST_RELEASE_API_URL="https://api.github.com/repos/${REPOSITORY_PATH}/releases/latest"

log "Getting latest GitHub Release."

RELEASE_JSON="$(curl --fail --location --silent --show-error "${LATEST_RELEASE_API_URL}")"

RELEASE_TAG_NAME="$(printf '%s\n' "${RELEASE_JSON}" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^"tag_name"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -n 1)"
TAR_URL="$(printf '%s\n' "${RELEASE_JSON}" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*linux-amd64\.tar"' | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -n 1)"

if [[ -z "${TAR_URL}" ]]; then
    echo "ERROR: Latest GitHub Release does not contain linux-amd64.tar." >&2
    exit 1
fi

echo "Release: ${RELEASE_TAG_NAME:-unknown}"
echo "Docker TAR URL: ${TAR_URL}"


# ==========================================================
# 10. Скачивание и загрузка Docker image
# ==========================================================

TEMPORARY_TAR_FILE="$(mktemp /tmp/xray-logreader-XXXXXX.tar)"

trap 'rm -f "${TEMPORARY_TAR_FILE}"' EXIT

echo "Downloading Docker image. Please wait..."

# --progress-bar показывает процесс скачивания большого TAR-архива.
# --silent намеренно не используется, иначе прогресс будет скрыт.
curl --fail --location --progress-bar --show-error --output "${TEMPORARY_TAR_FILE}" "${TAR_URL}"

echo "Loading Docker image."

DOCKER_LOAD_OUTPUT="$(docker load --input "${TEMPORARY_TAR_FILE}" 2>&1)"

echo "${DOCKER_LOAD_OUTPUT}"

LOADED_IMAGE_TAG="$(printf '%s\n' "${DOCKER_LOAD_OUTPUT}" | sed -n 's/^Loaded image: //p' | tail -n 1)"

if [[ -z "${LOADED_IMAGE_TAG}" ]]; then
    echo "ERROR: Could not determine Docker image tag after docker load." >&2
    exit 1
fi

docker tag "${LOADED_IMAGE_TAG}" "${CURRENT_IMAGE_TAG}"


# ==========================================================
# 11. Запуск контейнера
# ==========================================================

echo "Starting Docker Compose with image: ${CURRENT_IMAGE_TAG}"

docker compose up --detach --force-recreate --remove-orphans


# ==========================================================
# 12. Фиксация установленной версии
# ==========================================================

if [[ -n "${RELEASE_TAG_NAME}" ]]; then
    printf '%s\n' "${RELEASE_TAG_NAME}" > "${RELEASE_MARKER_FILE}"
fi


# ==========================================================
# Результат
# ==========================================================

echo
echo "Installation completed successfully."
echo

docker compose ps

echo
echo "Info logs:  ${PROJECT_DIRECTORY}/logs/info"
echo "Error logs: ${PROJECT_DIRECTORY}/logs/error"
echo "State JSON: ${PROJECT_DIRECTORY}/data"
echo
echo "To update Xray LogReader in the future, run:"
echo "  cd ${PROJECT_DIRECTORY} && sudo ./docker-update-github.sh"