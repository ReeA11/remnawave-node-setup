#!/bin/bash
clear
set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

printf "${WHITE}🚀  RemnaNode Removal Script${NC}\n"
printf "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}\n\n"

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${GRAY}Запусти скрипт от root: sudo $0${NC}"
  exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "🔍 Docker не установлен. Нечего удалять."
    exit 0
fi

# --- Остановка и удаление контейнера ---
if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
    echo "[*] Останавливаю и удаляю контейнер remnanode..."
    docker compose -f /opt/remnanode/docker-compose.yml down 2>/dev/null || true
    docker rm -f remnanode 2>/dev/null || true
else
    echo "🔍 Контейнер remnanode не найден. Пропускаю."
fi

# --- Удаление директории ---
if [ -d "/opt/remnanode" ]; then
    echo "[*] Удаляю директорию /opt/remnanode..."
    rm -rf /opt/remnanode
else
    echo "🔍 Директория /opt/remnanode не найдена."
fi

echo "🎉 RemnaNode успешно удалён 🎉"
echo
echo "Нажмите Enter, чтобы открыть меню установки..."
read -r   # ждём нажатия Enter

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)