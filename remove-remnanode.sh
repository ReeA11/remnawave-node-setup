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

printf "${WHITE}🗑  RemnaNode Removal Script${NC}\n"
printf "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}\n\n"

# ================== Проверка root ==================
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${GRAY}Запусти скрипт от root: sudo $0${NC}"
  exit 1
fi

# ================== Проверка Docker ==================
if ! command -v docker &> /dev/null; then
  echo -e "${GRAY}🔍 Docker не установлен. Нечего удалять.${NC}"
  exit 0
fi

# ================== Поиск нод ==================
mapfile -t NODES < <(find /opt -maxdepth 1 -type d -name "remnanode*")

if [[ "${#NODES[@]}" -eq 0 ]]; then
  echo -e "${YELLOW}🔍 Ноды RemnaNode не найдены.${NC}"
  exit 0
fi

echo -e "${CYAN}📦 Найденные ноды:${NC}\n"

for i in "${!NODES[@]}"; do
  NODE_DIR="${NODES[$i]}"
  NODE_NAME="$(basename "$NODE_DIR")"

  if docker ps -a --format '{{.Names}}' | grep -qx "$NODE_NAME"; then
    STATUS="${GREEN}🟢 контейнер есть${NC}"
  else
    STATUS="${GRAY}⚪ контейнер отсутствует${NC}"
  fi

  printf " ${GREEN}[%d]${NC} %-15s → %s\n" "$((i+1))" "$NODE_NAME" "$STATUS"
done

echo
read -p "👉 Выберите ноду для удаления [1-${#NODES[@]}]: " CHOICE </dev/tty

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#NODES[@]} )); then
  echo -e "${RED}❌ Неверный выбор${NC}"
  exit 1
fi

TARGET_DIR="${NODES[$((CHOICE-1))]}"
NODE_NAME="$(basename "$TARGET_DIR")"

echo
echo -e "${YELLOW}⚠ Будет удалено:${NC}"
echo -e " 📁 Директория: ${RED}$TARGET_DIR${NC}"
echo -e " 🐳 Контейнер:  ${RED}$NODE_NAME${NC}"
echo

read -p "❓ Подтвердите удаление (y/N): " CONFIRM </dev/tty
CONFIRM=${CONFIRM:-N}

if ! [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${GRAY}Удаление отменено.${NC}"
  exit 0
fi

# ================== Остановка контейнера ==================
if docker ps -a --format '{{.Names}}' | grep -qx "$NODE_NAME"; then
  echo -e "${BLUE}[*] Останавливаю контейнер $NODE_NAME...${NC}"
  docker compose -f "$TARGET_DIR/docker-compose.yml" down 2>/dev/null || true
  docker rm -f "$NODE_NAME" 2>/dev/null || true
else
  echo -e "${GRAY}Контейнер $NODE_NAME не найден.${NC}"
fi

# ================== Удаление директории ==================
echo -e "${BLUE}[*] Удаляю директорию $TARGET_DIR...${NC}"
rm -rf "$TARGET_DIR"

echo
echo -e "${GREEN}🎉 Нода $NODE_NAME успешно удалена 🎉${NC}"
echo

# ================== Возврат в меню ==================
echo "Нажмите Enter, чтобы открыть меню установки..."
read -r

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)