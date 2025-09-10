#!/bin/bash
clear
set -e

echo "=============================================="
echo "        RemnaNode Management Script"
echo "=============================================="

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

echo ""
echo "Выберите действие:"
echo "1) Установить RemnaNode"
echo "2) Удалить RemnaNode"  
echo "3) Запретить ping сервера и настроить UFW"
echo ""
read -p "Ваш выбор (1-3): " CHOICE </dev/tty

case $CHOICE in
    1)
        echo "[*] Запускаю установку RemnaNode..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/setup-remnanode.sh)
        ;;
    2)
        echo "[*] Запускаю удаление RemnaNode..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/remove-remnanode.sh)
        ;;
    3)
        echo "[*] Запускаю настройку безопасности..."
        bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/security-setup.sh)
        ;;
    *)
        echo "[!] Неверный выбор. Выход."
        exit 1
        ;;
esac