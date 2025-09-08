#!/bin/bash
set -e

echo "=== RemnaNode Setup Script ==="

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

# --- Установка docker ---
echo "[*] Устанавливаю Docker..."
curl -fsSL https://get.docker.com | sh

# --- Создание папки ---
echo "[*] Готовлю окружение..."
mkdir -p /opt/remnanode
cd /opt/remnanode

# --- Запрос сертификата ---
echo "[*] Вставьте сертификат (введите 'EOF' на новой строке для завершения):"
CERT_CONTENT=""
while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    CERT_CONTENT+="${line}\n"
done

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
