#!/bin/bash
set -e

# === Настройка системы ===
apt update -y && apt upgrade -y

# === Настройка firewall ===
ufw allow 22/tcp
ufw allow 4444/tcp
ufw allow 443/tcp
ufw --force enable

# === Установка 3x-ui ===
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# === Генерация случайных данных ===
PANEL_USER="admin$(openssl rand -hex 2)"
PANEL_PASS="$(openssl rand -hex 4)"
SERVER_IP=$(hostname -I | awk '{print $1}')
UUID=$(cat /proc/sys/kernel/random/uuid)
REMARK="TT-$(shuf -i 1-999 -n 1)"
PRIVATE_KEY=$(openssl ecparam -genkey -name prime256v1 -noout | openssl ec -text | grep "priv:" -A3 | tail -n +2 | tr -d '[:space:]:' | tr -d '\n')
SHORT_IDS=$(for i in {1..5}; do head /dev/urandom | tr -dc a-f0-9 | head -c $(shuf -i 2-16 -n 1); echo -n ','; done | sed 's/,$//')

# === Настройка панели ===
x-ui setting -username $PANEL_USER -password $PANEL_PASS >/dev/null 2>&1
systemctl restart x-ui

# === Создание inbound через CLI ===
x-ui add inbound \
  --remark "$REMARK" \
  --port 443 \
  --protocol vless \
  --settings "{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"xtls-rprx-vision\",\"email\":\"$REMARK\"}]}" \
  --streamSettings "{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"dest\":\"github.com:443\",\"serverNames\":[\"github.com\",\"www.github.com\"],\"privateKey\":\"$PRIVATE_KEY\",\"shortIds\":[$(echo $SHORT_IDS | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')],\"settings\":{\"publicKey\":\"p4zOp0WTebsKgH-hv4mWzKiZBzVE0w0w5kY3AFwz_D4\",\"fingerprint\":\"chrome\"}}}" \
  --sniffing "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"]}" >/dev/null 2>&1

# === Перезапуск панели ===
systemctl restart x-ui

# === Вывод данных ===
echo "==========================================="
echo "✅ 3x-ui успешно установлена и настроена"
echo "-------------------------------------------"
echo "🌐 Панель: http://$SERVER_IP:4444"
echo "👤 Логин: $PANEL_USER"
echo "🔑 Пароль: $PANEL_PASS"
echo "📦 Remark: $REMARK"
echo "🆔 UUID: $UUID"
echo "==========================================="