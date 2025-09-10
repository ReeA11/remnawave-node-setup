#!/bin/bash
set -e

echo "=== RemnaNode Removal Script ==="

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[!] Docker не установлен. Нечего удалять."
    exit 0
fi

# --- Остановка и удаление контейнера ---
if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
    echo "[*] Останавливаю и удаляю контейнер remnanode..."
    docker compose -f /opt/remnanode/docker-compose.yml down 2>/dev/null || true
    docker rm -f remnanode 2>/dev/null || true
else
    echo "[*] Контейнер remnanode не найден. Пропускаю."
fi

# --- Удаление директории ---
if [ -d "/opt/remnanode" ]; then
    echo "[*] Удаляю директорию /opt/remnanode..."
    rm -rf /opt/remnanode
else
    echo "[*] Директория /opt/remnanode не найдена."
fi

echo "=== RemnaNode успешно удалён ==="