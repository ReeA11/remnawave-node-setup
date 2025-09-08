#!/bin/bash
set -e

echo "=== RemnaNode Setup Script ==="

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo "[*] Docker не найден. Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
else
    echo "[*] Docker установлен."
    if ! systemctl is-active --quiet docker; then
        echo "[*] Docker установлен, но не запущен. Запускаю сервис..."
        systemctl start docker
    else
        echo "[*] Docker уже запущен."
    fi
fi

# --- Создание папки ---
echo "[*] Готовлю окружение..."
mkdir -p /opt/remnanode
cd /opt/remnanode

# --- Запрос сертификата ---
read -p "[*] Вставьте строку сертификата (формат SSL_CERT=CERT_FROM_MAIN_PANEL): " CERT_CONTENT

# --- Создание .env ---
echo "[*] Создаю .env..."
cat > .env <<EOF
APP_PORT=2222

$CERT_CONTENT
EOF

# --- Создание docker-compose.yml ---
echo "[*] Создаю docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    env_file:
      - .env
EOF

# --- Запуск ---
echo "[*] Запускаю контейнер..."
docker compose up -d
docker compose logs -f -t