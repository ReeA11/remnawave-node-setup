#!/bin/bash
clear
set -e

# ================== Цвета ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

printf "${WHITE}🚀  RemnaNode Setup Script${NC}\n"
printf "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}\n\n"

# ================== Проверка root ==================
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${GRAY}Запусти скрипт от root: sudo $0${NC}"
  exit 1
fi

# ================== Docker ==================
if ! command -v docker &> /dev/null; then
  echo "🔍 Docker не найден. Устанавливаю..."
  curl -fsSL https://get.docker.com | sh
else
  echo "🔍 Docker установлен."
  systemctl is-active --quiet docker || systemctl start docker
fi

# ================== Подготовка директории ==================
BASE_DIR="/opt/remnanode"
TARGET_DIR="$BASE_DIR"
IDX=1

while [ -d "$TARGET_DIR" ]; do
  IDX=$((IDX+1))
  TARGET_DIR="${BASE_DIR}${IDX}"
done

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

NODE_NAME="$(basename "$TARGET_DIR")"

echo -e "${GREEN}📁 Используется директория:${NC} ${YELLOW}$TARGET_DIR${NC}"
echo -e "${GREEN}🐳 Имя контейнера:${NC} ${YELLOW}$NODE_NAME${NC}"

# ================== Порт ==================
read -p "📝 Введите порт для приложения (по умолчанию 2222): " NODE_PORT </dev/tty
NODE_PORT=${NODE_PORT:-2222}

# ================== Выбор сетевого интерфейса ==================
echo
echo -e "${CYAN}🌐 Доступные сетевые интерфейсы:${NC}"

mapfile -t IFACES < <(
  ip -o -4 addr show | awk '$2 != "lo" {print $2, $4}' | sed 's#/.*##'
)

if [[ "${#IFACES[@]}" -eq 0 ]]; then
  echo -e "${RED}❌ Не найдено интерфейсов с IPv4${NC}"
  exit 1
fi

for i in "${!IFACES[@]}"; do
  IF_NAME=$(awk '{print $1}' <<< "${IFACES[$i]}")
  IF_IP=$(awk '{print $2}' <<< "${IFACES[$i]}")
  printf " ${GREEN}[%d]${NC} %-10s → ${YELLOW}%s${NC}\n" "$((i+1))" "$IF_NAME" "$IF_IP"
done

echo
read -p "👉 Выберите интерфейс [1-${#IFACES[@]}]: " IF_CHOICE </dev/tty

if ! [[ "$IF_CHOICE" =~ ^[0-9]+$ ]] || (( IF_CHOICE < 1 || IF_CHOICE > ${#IFACES[@]} )); then
  echo -e "${RED}❌ Неверный выбор интерфейса${NC}"
  exit 1
fi

BIND_IP=$(awk '{print $2}' <<< "${IFACES[$((IF_CHOICE-1))]}")

echo -e "${GREEN}✔ Используется IP:${NC} ${YELLOW}$BIND_IP${NC}"

# ================== Сертификат ==================
read -p "📝 Вставьте значение SECRET_KEY: " SECRET_KEY </dev/tty

# ================== .env ==================
echo "[*] Создаю .env..."
cat > .env <<EOF
NODE_NAME=$NODE_NAME
NODE_PORT=$NODE_PORT
BIND_IP=$BIND_IP

SECRET_KEY=$SECRET_KEY
EOF

# ================== docker-compose.yml ==================
echo "[*] Создаю docker-compose.yml..."
cat > docker-compose.yml <<EOF
services:
  $NODE_NAME:
    container_name: $NODE_NAME
    hostname: $NODE_NAME
    image: remnawave/node:2.2.3
    restart: always
    env_file:
      - .env
    ports:
      - "\${BIND_IP}:\${NODE_PORT}:\${NODE_PORT}"
EOF

# ================== UFW ==================
if command -v ufw &> /dev/null; then
  if ufw status | grep -q "Status: active"; then
    echo "🔍 UFW активен. Разрешаю порт $NODE_PORT..."
    ufw allow "$NODE_PORT"/tcp
  fi
fi

# ================== Запуск ==================
echo "[*] Запускаю контейнер $NODE_NAME..."
docker compose up -d
docker compose logs -f -t

echo
echo "Нажмите Enter, чтобы открыть меню установки..."
read -r

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)