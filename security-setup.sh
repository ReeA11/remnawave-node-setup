#!/bin/bash
clear
set -e

echo "=== RemnaNode Security Setup Script ==="

# --- Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

# --- Получение порта RemnaNode ---
REMNANODE_PORT=""
if [ -f "/opt/remnanode/.env" ]; then
    REMNANODE_PORT=$(grep "^APP_PORT=" /opt/remnanode/.env | cut -d'=' -f2)
    echo "[*] Обнаружен порт RemnaNode: $REMNANODE_PORT"
else
    read -p "[*] Введите порт RemnaNode (по умолчанию 2222): " REMNANODE_PORT </dev/tty
    REMNANODE_PORT=${REMNANODE_PORT:-2222}
fi

# --- Enable UFW ---
ufw --force enable

# --- Запрос блокировки пинга ---
read -p "[*] Желаете запретить пинг сервера? Правила before.rules будут перезаписаны (y/N): " BLOCK_PING </dev/tty
BLOCK_PING=${BLOCK_PING:-N}

if [[ "$BLOCK_PING" =~ ^[Yy]$ ]]; then
    echo "[*] Блокирую пинг сервера..."

    # Перезаписываем правила
    cat > /etc/ufw/before.rules <<'EOF'
#
# rules.before
#
# Rules that should be run before the ufw command line added rules. Custom
# rules should be added to one of these chains:
#   ufw-before-input
#   ufw-before-output
#   ufw-before-forward
#
# Don't delete these required lines, otherwise there will be errors
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]
# End required lines
# allow all on loopback
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-output -o lo -j ACCEPT
# quickly process packets for which we already have a connection
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# drop INVALID packets (logs these in loglevel medium and higher)
-A ufw-before-input -m conntrack --ctstate INVALID -j ufw-logging-deny
-A ufw-before-input -m conntrack --ctstate INVALID -j DROP
# ok icmp codes for INPUT
-A ufw-before-input -p icmp --icmp-type destination-unreachable -j DROP
-A ufw-before-input -p icmp --icmp-type time-exceeded -j DROP
-A ufw-before-input -p icmp --icmp-type parameter-problem -j DROP
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP
-A ufw-before-input -p icmp --icmp-type source-quench -j DROP
# ok icmp code for FORWARD
-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j DROP
-A ufw-before-forward -p icmp --icmp-type time-exceeded -j DROP
-A ufw-before-forward -p icmp --icmp-type parameter-problem -j DROP
-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP
# allow dhcp client to work
-A ufw-before-input -p udp --sport 67 --dport 68 -j ACCEPT
#
# ufw-not-local
#
-A ufw-before-input -j ufw-not-local
# if LOCAL, RETURN
-A ufw-not-local -m addrtype --dst-type LOCAL -j RETURN
# if MULTICAST, RETURN
-A ufw-not-local -m addrtype --dst-type MULTICAST -j RETURN
# if BROADCAST, RETURN
-A ufw-not-local -m addrtype --dst-type BROADCAST -j RETURN
# all other non-local packets are dropped
-A ufw-not-local -m limit --limit 3/min --limit-burst 10 -j ufw-logging-deny
-A ufw-not-local -j DROP
# allow MULTICAST mDNS for service discovery (be sure the MULTICAST line above
# is uncommented)
-A ufw-before-input -p udp -d 224.0.0.251 --dport 5353 -j ACCEPT
# allow MULTICAST UPnP for service discovery (be sure the MULTICAST line above
# is uncommented)
-A ufw-before-input -p udp -d 239.255.255.250 --dport 1900 -j ACCEPT
# don't delete the 'COMMIT' line or these rules won't be processed
COMMIT
EOF

    echo "[*] Пинг сервера заблокирован."
    ufw reload
fi

# --- Настройка UFW ---
echo "[*] Настраиваю фаервол..."

# Определяем текущий SSH-порт
SSH_PORT=$(ss -tnlp | grep -i sshd | awk '{print $4}' | sed 's/.*://g' | sort -u | head -n1)

echo "[*] Добавляю необходимые порты..."

# Добавляем SSH порт (стандартный 22)
if [[ "$SSH_PORT" = "22" ]]; then
  ufw allow 22/tcp
  echo "[*] ✓ Добавлен порт SSH: 22"
fi

# Добавляем текущий SSH порт (если он нестандартный)
if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" && "$SSH_PORT" != "$REMNANODE_PORT" && "$SSH_PORT" != "443" ]]; then
    ufw allow ${SSH_PORT}/tcp
    echo "[*] ✓ Добавлен текущий SSH-порт: $SSH_PORT"
fi

# Добавляем порт RemnaNode
ufw allow "$REMNANODE_PORT"/tcp
echo "[*] ✓ Добавлен порт RemnaNode: $REMNANODE_PORT"

# Добавляем HTTPS порт
ufw allow 443/tcp
echo "[*] ✓ Добавлен порт HTTPS: 443"

echo ""
echo "=== Настройка безопасности завершена ==="
echo "Активные порты:"
echo "  - SSH: $SSH_PORT"
echo "  - RemnaNode: $REMNANODE_PORT"
echo "  - HTTPS: 443"
echo ""
if [[ "$BLOCK_PING" =~ ^[Yy]$ ]]; then
    echo "✓ Пинг сервера заблокирован"
fi
echo "✓ UFW включен и настроен"
echo
echo "Нажмите Enter, чтобы вернуться в меню..."
read -r   # ждём нажатия Enter

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)