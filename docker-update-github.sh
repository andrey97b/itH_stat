#!/usr/bin/env bash

# ==========================================================
# Xray LogReader — обновление существующей установки.
#
# Скрипт:
#   1. Обновляет tracked-файлы Git-репозитория.
#   2. Проверяет latest Gitea Release.
#   3. Не скачивает TAR и не перезапускает контейнер,
#      если установленная версия уже соответствует latest release.
#   4. При новой версии загружает image и пересоздаёт контейнер.
# ==========================================================

set -euo pipefail

# Скрипт может быть запущен из каталога, удалённого предыдущим uninstall.
# Переходим в гарантированно существующую папку.
cd /


# ==========================================================
# Аргументы
# ==========================================================

PROJECT_DIRECTORY="/opt/xray-logreader"
FORCE_REDEPLOY=0

for ARGUMENT in "$@"; do
    case "${ARGUMENT}" in
        --project_dir=*)
            PROJECT_DIRECTORY="${ARGUMENT#*=}"
            ;;

        --force)
            FORCE_REDEPLOY=1
            ;;

        *)
            echo "ERROR: Unknown argument: ${ARGUMENT}" >&2
            echo "Usage: sudo $0 [--project_dir=/opt/xray-logreader] [--force]" >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script with sudo." >&2
    exit 1
fi


# ==========================================================
# Проверка зависимостей и установки
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

if [[ ! -d "${PROJECT_DIRECTORY}/.git" ]]; then
    echo "ERROR: Xray LogReader is not installed at ${PROJECT_DIRECTORY}." >&2
    echo "ERROR: Run docker-install.sh first." >&2
    exit 1
fi

cd "${PROJECT_DIRECTORY}"

if [[ ! -f "docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml was not found in ${PROJECT_DIRECTORY}" >&2
    exit 1
fi

if [[ ! -f "docker-compose.override.yml" ]]; then
    echo "ERROR: docker-compose.override.yml was not found." >&2
    echo "ERROR: Existing VPS-specific configuration is missing." >&2
    exit 1
fi


# ==========================================================
# Постоянные настройки
# ==========================================================

CURRENT_IMAGE_TAG="xray-logreader:current"
RELEASE_MARKER_FILE=".image-tag"

log() {
    echo
    echo ">>> $*"
    echo
}


# ==========================================================
# 1. Обновление Git-файлов
# ==========================================================

log "Updating Git repository."

CURRENT_BRANCH="$(git symbolic-ref --short HEAD)"

git fetch --depth 1 origin "${CURRENT_BRANCH}"
git reset --hard "origin/${CURRENT_BRANCH}"

if [[ ! -f "docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml is missing after Git update." >&2
    exit 1
fi

if [[ ! -f "docker-compose.override.yml" ]]; then
    echo "ERROR: docker-compose.override.yml is missing after Git update." >&2
    exit 1
fi


# ==========================================================
# 2. Определение GitHub API
# ==========================================================

GIT_REPOSITORY_URL="$(git remote get-url origin)"

if [[ ! "${GIT_REPOSITORY_URL}" =~ ^https?://[^/]+/[^/]+/[^/]+/?(\.git)?$ ]]; then
    echo "ERROR: Unsupported Git remote URL: ${GIT_REPOSITORY_URL}" >&2
    echo "ERROR: Use an HTTPS origin remote URL for GitHub Release updates." >&2
    exit 1
fi

NORMALIZED_REPOSITORY_URL="${GIT_REPOSITORY_URL%/}"
NORMALIZED_REPOSITORY_URL="${NORMALIZED_REPOSITORY_URL%.git}"

REPOSITORY_PATH="$(printf '%s\n' "${NORMALIZED_REPOSITORY_URL}" | sed -E 's#^https?://github\.com/##')"
LATEST_RELEASE_API_URL="https://api.github.com/repos/${REPOSITORY_PATH}/releases/latest"


# ==========================================================
# 3. Проверка latest GitHub Release
# ==========================================================

echo "Getting latest GitHub Release."

RELEASE_JSON="$(curl --fail --location --silent --show-error "${LATEST_RELEASE_API_URL}")"

RELEASE_TAG_NAME="$(printf '%s\n' "${RELEASE_JSON}" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^"tag_name"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -n 1)"
TAR_URL="$(printf '%s\n' "${RELEASE_JSON}" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*linux-amd64\.tar"' | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//' | head -n 1)"

if [[ -z "${TAR_URL}" ]]; then
    echo "ERROR: Latest GitHub Release does not contain linux-amd64.tar." >&2
    exit 1
fi

INSTALLED_RELEASE_TAG_NAME=""

if [[ -f "${RELEASE_MARKER_FILE}" ]]; then
    INSTALLED_RELEASE_TAG_NAME="$(cat "${RELEASE_MARKER_FILE}")"
fi

echo "Installed release: ${INSTALLED_RELEASE_TAG_NAME:-unknown}"
echo "Latest release:    ${RELEASE_TAG_NAME:-unknown}"

if [[ "${FORCE_REDEPLOY}" -eq 0 ]] && [[ -n "${RELEASE_TAG_NAME}" ]] && [[ "${RELEASE_TAG_NAME}" == "${INSTALLED_RELEASE_TAG_NAME}" ]]; then
    echo
    echo "Already up to date (release ${RELEASE_TAG_NAME}). Nothing to do."
    echo "Use --force to redeploy anyway."
    echo

    docker compose ps
    exit 0
fi


# ==========================================================
# 4. Скачивание и загрузка нового Docker image
# ==========================================================

log "New release detected, updating."

echo "Docker TAR URL: ${TAR_URL}"

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
# 5. Перезапуск контейнера
# ==========================================================

echo "Restarting Docker Compose with image: ${CURRENT_IMAGE_TAG}"

docker compose up --detach --force-recreate --remove-orphans


# ==========================================================
# 6. Фиксация новой версии
# ==========================================================

if [[ -n "${RELEASE_TAG_NAME}" ]]; then
    printf '%s\n' "${RELEASE_TAG_NAME}" > "${RELEASE_MARKER_FILE}"
fi


# ==========================================================
# Результат
# ==========================================================

echo
echo "Update completed successfully."
echo

docker compose ps

echo
echo "Info logs:  ${PROJECT_DIRECTORY}/logs/info"
echo "Error logs: ${PROJECT_DIRECTORY}/logs/error"
echo "State JSON: ${PROJECT_DIRECTORY}/data"
