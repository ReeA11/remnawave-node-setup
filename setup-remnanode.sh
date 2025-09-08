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

# --- Запрос порта с дефолтом 2222 ---
read -p "[*] Введите порт для приложения (по умолчанию 2222): " APP_PORT </dev/tty
APP_PORT=${APP_PORT:-2222}

# --- Запрос сертификата ---
read -p "[*] Вставьте строку сертификата (формат SSL_CERT=CERT_FROM_MAIN_PANEL): " CERT_CONTENT </dev/tty

# --- Создание .env ---
echo "[*] Создаю .env..."
cat > .env <<EOF
APP_PORT=$APP_PORT

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

# --- Настройка UFW (если включен) ---
if command -v ufw &> /dev/null; then
    UFW_STATUS=$(ufw status | head -n1)
    if [[ "$UFW_STATUS" == "Status: active" ]]; then
        echo "[*] UFW включен. Разрешаю TCP-порт $APP_PORT..."
        ufw allow "$APP_PORT"/tcp
    else
        echo "[*] UFW установлен, но не активен. Пропускаем настройку порта."
    fi
else
    echo "[*] UFW не найден. Пропускаем настройку порта."
fi

# --- Запуск контейнера ---
echo "[*] Запускаю контейнер..."
docker compose up -d
docker compose logs -f -t