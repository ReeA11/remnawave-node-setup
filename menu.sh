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

echo -e "${WHITE}=============================================="
echo "       🚀  RemnaNode Script Menu 🚀"
echo -e "==============================================${NC}"

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${GRAY}Запусти скрипт от root: sudo $0${NC}"
  exit 1
fi

echo ""
echo -e "${WHITE}Выберите действие:${NC}"
echo -e "${GRAY}1) Установить RemnaNode"
echo "2) Удалить RemnaNode"  
echo -e "3) Запретить ping сервера и настроить UFW${NC}"
echo ""
read -p "Ваш выбор (1-3): " CHOICE </dev/tty

case $CHOICE in
    1)
        echo "🚀 Запускаю установку RemnaNode..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/setup-remnanode.sh)
        ;;
    2)
        echo "🚀 Запускаю удаление RemnaNode..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/remove-remnanode.sh)
        ;;
    3)
        echo "🚀 Запускаю настройку безопасности..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/security-setup.sh)
        ;;
    *)
        echo -e "${YELLOW}[!] Неверный выбор. Выход.${NC}"
        exit 1
        ;;
esac
