#!/bin/bash
clear
set -Eeuo pipefail
IFS=$'\n\t'

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

# ================== Режим вывода (тихо/подробно) ==================
# По умолчанию скрипт работает в "user friendly" режиме: минимум технических логов.
# Включить подробный режим можно так:
#   VERBOSE=1 bash setup-remnanode.sh
VERBOSE="${VERBOSE:-0}"

# ================== Порты Xray (inbounds) ==================
# Внутри контейнера RemnaNode Xray слушает стандартные порты (обычно 443 и 8443).
# Чтобы клиент мог подключиться (например, к EXTERNAL_IP:8443), эти порты нужно публиковать наружу.
XRAY_PORT_HTTPS="443"
XRAY_PORT_ALT="8443"
PUBLISH_XRAY_PORTS_DEFAULT="true"

# ================== Без мусора при ошибках ==================
STAGE_DIR=""
TARGET_DIR=""
CREATED_NETWORK_BY_SCRIPT="false"
NETWORK_NAME=""
INSTALL_SUCCESS="false"
CONTAINER_STARTED="false"
NODE_NAME=""

cleanup() {
  # удаляем только staging (в /tmp), чтобы не оставлять мусор
  if [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR:-}" ]]; then
    rm -rf "${STAGE_DIR}" 2>/dev/null || true
  fi

  # если контейнер уже успел стартовать, а установка упала — гасим его, чтобы не оставлять полусконфигуренное состояние
  if [[ "${INSTALL_SUCCESS:-false}" != "true" && "${CONTAINER_STARTED:-false}" == "true" && -n "${NODE_NAME:-}" ]]; then
    docker rm -f "${NODE_NAME}" >/dev/null 2>&1 || true
  fi

  # ранее скрипт мог создавать custom docker network; сейчас этот режим отключён,
  # но оставляем совместимость на случай старых версий/прерванных установок.
  if [[ "${INSTALL_SUCCESS:-false}" != "true" && "${CREATED_NETWORK_BY_SCRIPT:-false}" == "true" && -n "${NETWORK_NAME:-}" ]]; then
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  fi
}

on_err() {
  local exit_code=$?
  echo
  echo -e "${RED}❌ код: ${exit_code})${NC}"
  cleanup
  exit "${exit_code}"
}

trap on_err ERR
trap cleanup EXIT

# ================== Проверка root ==================
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${GRAY}Запусти скрипт от root: sudo $0${NC}"
  exit 1
fi

# ================== Базовые зависимости (Ubuntu/Debian) ==================
ensure_packages() {
  local missing=()
  for cmd in ip awk sed grep cut tr; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  command -v curl >/dev/null 2>&1 || missing+=("curl")

  if [[ "${#missing[@]}" -gt 0 ]]; then
    # ставим пакеты только если есть apt-get
    if command -v apt-get >/dev/null 2>&1; then
      echo -e "${GRAY}🔧 Устанавливаю зависимости: curl, iproute2 ...${NC}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y curl ca-certificates iproute2 >/dev/null
    else
      echo -e "${YELLOW}⚠ Не найден apt-get. Убедитесь, что установлены: curl, iproute2${NC}"
    fi
  fi
}

ensure_packages

# ================== Helpers: routing / iptables / sysctl ==================
get_default_gw_for_iface() {
  local iface="$1"
  ip route show default dev "${iface}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true
}

get_default_gw_for_src() {
  local src_ip="$1"
  ip route show default 2>/dev/null | grep -m1 "src ${src_ip}" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true
}

ensure_rt_table_id() {
  local table_name="$1"
  local id=""
  if [[ -f /etc/iproute2/rt_tables ]]; then
    id="$(awk -v n="$table_name" '$2==n {print $1; exit}' /etc/iproute2/rt_tables 2>/dev/null || true)"
  fi
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  for candidate in $(seq 201 250); do
    if ! awk -v c="$candidate" '$1==c {found=1} END{exit found?0:1}' /etc/iproute2/rt_tables 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  echo "250"
}

ensure_ip_rule_prio_from_lookup() {
  local prio="$1"
  local from="$2"
  local lookup="$3"
  if ip rule show 2>/dev/null | grep -qE "^${prio}:.*from ${from}.*lookup ${lookup}"; then
    return 0
  fi
  if ip rule show 2>/dev/null | grep -qE "^${prio}:.*from ${from} "; then
    ip rule del priority "${prio}" 2>/dev/null || true
  fi
  ip rule add priority "${prio}" from "${from}" lookup "${lookup}" 2>/dev/null || true
}

ensure_iptables_rule() {
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "${table}" -C "${chain}" "$@" 2>/dev/null; then
    return 0
  fi
  iptables -t "${table}" -A "${chain}" "$@" 2>/dev/null || true
}

persist_iptables_if_possible() {
  if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save 2>/dev/null || true
  elif command -v iptables-save &> /dev/null; then
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

ensure_iptables_persistence() {
  # На Debian/Ubuntu iptables правила НЕ переживают reboot сами по себе.
  # Нужен netfilter-persistent/iptables-persistent (или свой systemd unit).
  if command -v netfilter-persistent &> /dev/null; then
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    # без диалогов во время установки
    if command -v debconf-set-selections >/dev/null 2>&1; then
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections || true
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections || true
    fi
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
  fi
}

# ================== Docker ==================
if ! command -v docker &> /dev/null; then
  echo "🔍 Docker не найден. Устанавливаю..."
  curl -fsSL https://get.docker.com | sh
else
  echo "🔍 Docker установлен."
  systemctl is-active --quiet docker || systemctl start docker
fi

# ================== ПРЕДВАРИТЕЛЬНЫЙ расчёт директории ==================
BASE_DIR="/opt/remnanode"
TARGET_DIR="$BASE_DIR"
IDX=1

while [ -d "$TARGET_DIR" ]; do
  IDX=$((IDX+1))
  TARGET_DIR="${BASE_DIR}${IDX}"
done

NODE_NAME="$(basename "$TARGET_DIR")"

echo -e "${GREEN}📁 Будет использована директория:${NC} ${YELLOW}$TARGET_DIR${NC}"
echo -e "${GREEN}🐳 Имя контейнера:${NC} ${YELLOW}$NODE_NAME${NC}"
echo

# ================== Порт ==================
read -p "📝 Введите порт для приложения (по умолчанию 2222): " NODE_PORT </dev/tty
NODE_PORT=${NODE_PORT:-2222}

# ================== Выбор сетевого интерфейса ==================
echo
echo -e "${CYAN}🌐 Доступные IPv4 адреса (интерфейс → локальный IP → внешний/публичный IP):${NC}"

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.1[6-9]\. ]] && return 0
  [[ "$ip" =~ ^172\.2[0-9]\. ]] && return 0
  [[ "$ip" =~ ^172\.3[0-1]\. ]] && return 0
  [[ "$ip" =~ ^100\.6[4-9]\. ]] && return 0
  [[ "$ip" =~ ^100\.(7[0-9]|[8-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  return 1
}

declare -a IF_NAMES
declare -a IF_IPS
declare -a IF_EXTERNALS

# берем только глобальные IPv4, исключаем lo и типичные виртуальные интерфейсы docker
mapfile -t ADDR_LINES < <(ip -o -4 addr show scope global | awk '{print $2, $4}' | sed 's#/.*##')

# фильтрация: lo/ docker/br/veth/virbr/lxcbr
for line in "${ADDR_LINES[@]}"; do
  IF_NAME="$(awk '{print $1}' <<< "$line")"
  IF_IP="$(awk '{print $2}' <<< "$line")"

  [[ "$IF_NAME" == "lo" ]] && continue
  [[ "$IF_NAME" =~ ^(docker|br-|veth|virbr|lxcbr) ]] && continue

  IF_NAMES+=("$IF_NAME")
  IF_IPS+=("$IF_IP")
done

if [[ "${#IF_NAMES[@]}" -eq 0 ]]; then
  # fallback: если фильтрация “съела всё”, показываем все scope global, кроме lo
  for line in "${ADDR_LINES[@]}"; do
    IF_NAME="$(awk '{print $1}' <<< "$line")"
    IF_IP="$(awk '{print $2}' <<< "$line")"
    [[ "$IF_NAME" == "lo" ]] && continue
    IF_NAMES+=("$IF_NAME")
    IF_IPS+=("$IF_IP")
  done
fi

if [[ "${#IF_NAMES[@]}" -eq 0 ]]; then
  echo -e "${RED}❌ Не найдено IPv4 адресов (scope global).${NC}"
  exit 1
fi

echo -e "${GRAY}Определяю внешний IP для приватных адресов (если есть NAT)...${NC}"
for i in "${!IF_NAMES[@]}"; do
  IF_NAME="${IF_NAMES[$i]}"
  IF_IP="${IF_IPS[$i]}"

  if is_private_ipv4 "$IF_IP"; then
    EXTERNAL_IP="$(curl -4 -s --interface "${IF_NAME}" --max-time 2 ifconfig.me 2>/dev/null || true)"
    IF_EXTERNALS[$i]="${EXTERNAL_IP:-}"
  else
    # если IP уже публичный — он и есть внешний для входящих подключений
    IF_EXTERNALS[$i]="$IF_IP"
  fi
done

echo
for i in "${!IF_NAMES[@]}"; do
  IF_NAME="${IF_NAMES[$i]}"
  IF_IP="${IF_IPS[$i]}"
  EXTERNAL_IP="${IF_EXTERNALS[$i]:-}"

  if [[ -n "$EXTERNAL_IP" ]]; then
    printf " ${GREEN}[%d]${NC} %-12s → ${YELLOW}%s${NC} ${GRAY}→ внешний: %s${NC}\n" "$((i+1))" "$IF_NAME" "$IF_IP" "$EXTERNAL_IP"
  else
    printf " ${GREEN}[%d]${NC} %-12s → ${YELLOW}%s${NC} ${GRAY}→ внешний: (не определён)${NC}\n" "$((i+1))" "$IF_NAME" "$IF_IP"
  fi
done

echo
read -p "👉 Выберите IP/интерфейс для этой ноды [1-${#IF_NAMES[@]}]: " IF_CHOICE </dev/tty

if ! [[ "$IF_CHOICE" =~ ^[0-9]+$ ]] || (( IF_CHOICE < 1 || IF_CHOICE > ${#IF_NAMES[@]} )); then
  echo -e "${RED}❌ Неверный выбор интерфейса${NC}"
  exit 1
fi

SELECTED_IFACE="${IF_NAMES[$((IF_CHOICE-1))]}"
BIND_IP="${IF_IPS[$((IF_CHOICE-1))]}"
EXTERNAL_IP_DETECTED="${IF_EXTERNALS[$((IF_CHOICE-1))]:-}"

# Формируем информацию о внешнем IP
EXTERNAL_IP_INFO=""
if [[ -n "$EXTERNAL_IP_DETECTED" ]]; then
  EXTERNAL_IP_INFO=" (внешний IP: ${EXTERNAL_IP_DETECTED})"
fi

echo
echo -e "${GREEN}✔ Локальный IP интерфейса:${NC} ${YELLOW}$BIND_IP${NC}${EXTERNAL_IP_INFO}"
echo -e "${GREEN}✔ Интерфейс:${NC} ${YELLOW}$SELECTED_IFACE${NC}"

# ================== Режим установки ==================
USE_CUSTOM_NETWORK="false"
NETWORK_NAME=""
CONTAINER_IP=""
NETWORK_SUBNET=""
PUBLISH_XRAY_PORTS="${PUBLISH_XRAY_PORTS_DEFAULT}"
ROUTING_TABLE_ID=""
ROUTING_TABLE_NAME=""
HOST_RULE_PRIORITY=""
SUBNET_RULE_PRIORITY=""
DOCKER_NET_NAME=""
DOCKER_NET_SUBNET=""
DOCKER_BRIDGE_IFACE=""

# - стандартная docker bridge сеть
# - публикация портов + policy routing/NAT для multi-IP

# ================== SECRET_KEY ==================
echo
echo -e "${CYAN}🔑 SECRET_KEY для этой ноды${NC}"
read -p "📝 Вставьте значение SECRET_KEY для этой ноды: " SECRET_KEY </dev/tty

if [[ -z "$SECRET_KEY" ]]; then
  echo -e "${RED}❌ SECRET_KEY не может быть пустым${NC}"
  exit 1
fi

# Очистка SECRET_KEY
# Обрабатываем случаи: SSL_CERT="1234", SSL_CERT='1234', "1234", '1234', 1234
SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]*SSL_CERT[[:space:]]*=[[:space:]]*//')
SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]*["'\'']?//' | sed -E 's/["'\'']?[[:space:]]*$//')
SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:]]+$//')

if [[ -z "$SECRET_KEY" ]]; then
  echo -e "${RED}❌ SECRET_KEY не может быть пустым после обработки${NC}"
  exit 1
fi

is_secret_key_unique() {
  local candidate="$1"
  local env_file sk node
  while IFS= read -r -d '' env_file; do
    sk="$(grep -E '^SECRET_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- || true)"
    sk="$(echo "$sk" | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
    if [[ -n "$sk" && "$sk" == "$candidate" ]]; then
      node="$(basename "$(dirname "$env_file")")"
      echo -e "${RED}❌ Такой SECRET_KEY уже используется нодой: ${node}${NC}"
      return 1
    fi
  done < <(find /opt -maxdepth 1 -type f -name ".env" -path "/opt/remnanode*/.env" -print0 2>/dev/null || true)
  return 0
}

while ! is_secret_key_unique "$SECRET_KEY"; do
  echo -e "${YELLOW}Введите ДРУГОЙ уникальный SECRET_KEY.${NC}"
  read -p "📝 SECRET_KEY: " SECRET_KEY </dev/tty
  SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]*SSL_CERT[[:space:]]*=[[:space:]]*//')
  SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]*["'\'']?//' | sed -E 's/["'\'']?[[:space:]]*$//')
  SECRET_KEY=$(echo "$SECRET_KEY" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:]]+$//')
  [[ -n "$SECRET_KEY" ]] || { echo -e "${RED}❌ SECRET_KEY не может быть пустым${NC}"; }
done

# ================== Выбор версии RemnaNode ==================
echo
echo -e "${CYAN}📦 Выберите версию RemnaNode:${NC}"
echo -e " ${GREEN}[1]${NC} Old 2.2.3"
echo -e " ${GREEN}[2]${NC} latest"
echo -e " ${GREEN}[3]${NC} Выбрать версию вручную"
echo
read -p "👉 Ваш выбор [1-3]: " VERSION_CHOICE </dev/tty

case $VERSION_CHOICE in
  1)
    NODE_VERSION="2.2.3"
    ;;
  2)
    NODE_VERSION="latest"
    ;;
  3)
    read -p "📝 Введите версию (например, 2.3.0): " NODE_VERSION </dev/tty
    if [[ -z "$NODE_VERSION" ]]; then
      echo -e "${RED}❌ Версия не может быть пустой${NC}"
      exit 1
    fi
    ;;
  *)
    echo -e "${RED}❌ Неверный выбор. Используется версия по умолчанию: 2.2.3${NC}"
    NODE_VERSION="2.2.3"
    ;;
esac

echo -e "${GREEN}✔ Выбрана версия:${NC} ${YELLOW}$NODE_VERSION${NC}"

echo "[*] Проверяю доступность порта и IP..."

# Проверка занятости Xray портов (443/8443) на выбранном IP (если публикуем)
is_port_in_use() {
  local ip="$1"
  local port="$2"
  local proto="$3" # tcp|udp

  if [[ "$proto" == "tcp" ]]; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^${ip}:${port}$|^0\\.0\\.0\\.0:${port}$|^\\[::\\]:${port}$)" && return 0
  elif [[ "$proto" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^${ip}:${port}$|^0\\.0\\.0\\.0:${port}$|^\\[::\\]:${port}$)" && return 0
  fi
  return 1
}

check_xray_ports_or_exit() {
  local ip="$1"
  [[ "${PUBLISH_XRAY_PORTS:-true}" == "true" ]] || return 0

  for p in "${XRAY_PORT_HTTPS}" "${XRAY_PORT_ALT}"; do
    local conflict="false"
    if is_port_in_use "$ip" "$p" "tcp"; then conflict="true"; fi
    if is_port_in_use "$ip" "$p" "udp"; then conflict="true"; fi

    # Проверяем, не занят ли порт Docker'ом (пробросами других контейнеров)
    if docker ps --format '{{.Ports}}' | grep -qE "${ip}:${p}"; then
      conflict="true"
    fi

    if [[ "$conflict" == "true" ]]; then
      echo -e "${RED}❌ Порт ${p} (tcp/udp) на IP ${ip} уже занят.${NC}"
      echo -e "${YELLOW}Что сделать:${NC}"
      echo -e "${GRAY}- Освободить порт ${p} на этом IP (остановить сервис/контейнер, который слушает)${NC}"
      echo -e "${GRAY}- Или выбрать другой IP/интерфейс для ноды${NC}"
      echo -e "${GRAY}- Или запустить установку с отключением публикации Xray-портов: PUBLISH_XRAY_PORTS_DEFAULT=false${NC}"
      exit 1
    fi
  done
}

# Сначала проверяем Xray порты, чтобы не поставить ноду, к которой клиент не сможет подключиться
check_xray_ports_or_exit "${BIND_IP}"

# Проверка занятости порта на выбранном IP
if docker ps --format '{{.Ports}}' | grep -q "${BIND_IP}:${NODE_PORT}"; then
  OCCUPIED_CONTAINER=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep "${BIND_IP}:${NODE_PORT}" | awk '{print $1}' | head -1)
  echo -e "${RED}❌ Порт ${NODE_PORT} на IP ${BIND_IP} уже занят контейнером: ${OCCUPIED_CONTAINER}${NC}"
  read -p "📝 Введите другой порт (или нажмите Enter для отмены): " NEW_PORT </dev/tty
  if [[ -n "$NEW_PORT" ]]; then
    NODE_PORT="$NEW_PORT"
    echo -e "${GREEN}✔ Используется порт: ${NODE_PORT}${NC}"
  else
    echo -e "${RED}❌ Установка отменена${NC}"
    exit 1
  fi
fi

# Доп. проверка: если порт слушается на 0.0.0.0 или на выбранном IP — это конфликт
if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^${BIND_IP}:${NODE_PORT}$|^0\.0\.0\.0:${NODE_PORT}$|^\[::\]:${NODE_PORT}$)"; then
  echo -e "${YELLOW}⚠ Порт ${NODE_PORT} уже занят процессом на хосте (LISTEN).${NC}"
  read -p "📝 Введите другой порт (или Enter для отмены): " NEW_PORT </dev/tty
  if [[ -n "$NEW_PORT" ]]; then
    NODE_PORT="$NEW_PORT"
    echo -e "${GREEN}✔ Используется порт: ${NODE_PORT}${NC}"
  else
    echo -e "${RED}❌ Установка отменена${NC}"
    exit 1
  fi
fi

# ================== Staging (без /opt/* до успешного запуска) ==================
echo
echo -e "${BLUE}🧪 Подготовка файлов установки во временной директории (будет удалена при ошибке)...${NC}"
mkdir -p /opt
STAGE_DIR="$(mktemp -d /opt/.remnanode-setup.XXXXXX)"
cd "$STAGE_DIR"

# ================== .env ==================
echo "[*] Создаю .env..."
cat > .env <<EOF
COMPOSE_PROJECT_NAME=$NODE_NAME
NODE_NAME=$NODE_NAME
NODE_PORT=$NODE_PORT
BIND_IP=$BIND_IP
SELECTED_IFACE=$SELECTED_IFACE
SECRET_KEY="$SECRET_KEY"
USE_CUSTOM_NETWORK=$USE_CUSTOM_NETWORK
PUBLISH_XRAY_PORTS=$PUBLISH_XRAY_PORTS
XRAY_PORT_HTTPS=$XRAY_PORT_HTTPS
XRAY_PORT_ALT=$XRAY_PORT_ALT
EOF

# ================== docker-compose.yml ==================
echo "[*] Создаю docker-compose.yml..."

# Блок проброса Xray портов (443/8443) — включается/выключается флагом PUBLISH_XRAY_PORTS
XRAY_PORTS_BLOCK=""
if [[ "${PUBLISH_XRAY_PORTS:-true}" == "true" ]]; then
  XRAY_PORTS_BLOCK=$(cat <<'EOF'
      - "${BIND_IP}:${XRAY_PORT_HTTPS}:${XRAY_PORT_HTTPS}/tcp"
      - "${BIND_IP}:${XRAY_PORT_HTTPS}:${XRAY_PORT_HTTPS}/udp"
      - "${BIND_IP}:${XRAY_PORT_ALT}:${XRAY_PORT_ALT}/tcp"
      - "${BIND_IP}:${XRAY_PORT_ALT}:${XRAY_PORT_ALT}/udp"
EOF
)
fi

# Простой режим (стандартная установка)
cat > docker-compose.yml <<EOF
name: $NODE_NAME
services:
  $NODE_NAME:
    container_name: $NODE_NAME
    hostname: $NODE_NAME
    image: remnawave/node:$NODE_VERSION
    restart: always
    env_file:
      - .env
    ports:
      - "\${BIND_IP}:\${NODE_PORT}:\${NODE_PORT}"
${XRAY_PORTS_BLOCK}
EOF

#
# ⚠ Routing/SNAT/ip rule/ip route (ВАЖНО для multi-IP):
# Если сервер имеет несколько внешних IP (каждый сидит на своём внутреннем 10.x/интерфейсе),
# то без policy routing трафик (и ответы) со 2/3 IP может уходить через "первый" интерфейс.
# В итоге:
# - внешний IP не пингуется/порты недоступны,
# - мастер видит "не тот" IP и нода красная (offline),
# - Xray не получает конфиг.
#
# Поэтому после старта контейнера мы настраиваем:
# - ip rule/ip route table для source=BIND_IP/32 через выбранный интерфейс
# - ip rule для docker subnet контейнера через тот же интерфейс
# - MASQUERADE (НЕ SNAT на публичный IP!) для docker subnet через выбранный интерфейс
# - ACCEPT в FORWARD для docker subnet (UFW часто FORWARD policy DROP)
#

# ================== Запуск ==================
echo "[*] Запускаю контейнер $NODE_NAME..."
docker compose up -d

# Проверяем статус контейнера
if docker ps | grep -q "$NODE_NAME"; then
  echo -e "${GREEN}✔ Контейнер $NODE_NAME запущен${NC}"
  CONTAINER_STARTED="true"
  
  # Короткое резюме (по умолчанию)
  if [[ -n "${EXTERNAL_IP_DETECTED:-}" ]]; then
    echo -e "${CYAN}🌍 Доступ извне:${NC} ${YELLOW}${EXTERNAL_IP_DETECTED}:${NODE_PORT}${NC}"
  else
    echo -e "${CYAN}🌍 Доступ извне:${NC} ${YELLOW}${BIND_IP}:${NODE_PORT}${NC}"
  fi

else
  echo -e "${RED}❌ Ошибка запуска контейнера${NC}"
  docker compose logs
  exit 1
fi

# ================== Policy routing + NAT для выбранного IP/интерфейса (multi-IP) ==================
echo
echo -e "${BLUE}🔀 Настраиваю routing/NAT для выхода ноды через ${YELLOW}${SELECTED_IFACE}${NC} (source ${YELLOW}${BIND_IP}${NC})...${NC}"

ROUTING_TABLE_NAME="remnanode_${NODE_NAME}"
ROUTING_TABLE_ID="$(ensure_rt_table_id "${ROUTING_TABLE_NAME}")"
HOST_RULE_PRIORITY="$((11000 + ROUTING_TABLE_ID))"
SUBNET_RULE_PRIORITY="$((12000 + ROUTING_TABLE_ID))"

if ! grep -q -E "^${ROUTING_TABLE_ID}[[:space:]]+${ROUTING_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "${ROUTING_TABLE_ID} ${ROUTING_TABLE_NAME}" >> /etc/iproute2/rt_tables 2>/dev/null || true
fi

GW="$(get_default_gw_for_iface "${SELECTED_IFACE}")"
GW="${GW:-$(get_default_gw_for_src "${BIND_IP}")}"

if [[ -z "${GW:-}" ]]; then
  echo -e "${YELLOW}⚠ Не удалось определить gateway для ${SELECTED_IFACE}. Пропускаю policy routing (на этом IP может не заработать).${NC}"
else
  # Default route for selected iface in our table
  ip route replace default via "${GW}" dev "${SELECTED_IFACE}" table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  # Source-based rule for host IP
  ensure_ip_rule_prio_from_lookup "${HOST_RULE_PRIORITY}" "${BIND_IP}/32" "${ROUTING_TABLE_ID}"
fi

# Discover docker network/subnet/bridge for this container
DOCKER_NET_NAME="$(docker inspect "${NODE_NAME}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "${DOCKER_NET_NAME:-}" ]]; then
  DOCKER_NET_SUBNET="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  DOCKER_NET_ID="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{.Id}}' 2>/dev/null | cut -c1-12 || true)"
  [[ -n "${DOCKER_NET_ID:-}" ]] && DOCKER_BRIDGE_IFACE="br-${DOCKER_NET_ID}" || DOCKER_BRIDGE_IFACE=""
fi

if [[ -n "${DOCKER_NET_SUBNET:-}" && -n "${GW:-}" ]]; then
  # Route to docker subnet in our table (helps reverse/local forwarding)
  [[ -n "${DOCKER_BRIDGE_IFACE:-}" ]] && ip route replace "${DOCKER_NET_SUBNET}" dev "${DOCKER_BRIDGE_IFACE}" scope link table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  # Policy rule for docker subnet
  ensure_ip_rule_prio_from_lookup "${SUBNET_RULE_PRIORITY}" "${DOCKER_NET_SUBNET}" "${ROUTING_TABLE_ID}"

  # NAT + FORWARD for docker subnet out selected iface
  ensure_iptables_rule nat POSTROUTING -s "${DOCKER_NET_SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE
  ensure_iptables_rule filter FORWARD -s "${DOCKER_NET_SUBNET}" -j ACCEPT
  ensure_iptables_rule filter FORWARD -d "${DOCKER_NET_SUBNET}" -j ACCEPT
  ensure_iptables_persistence
  persist_iptables_if_possible
else
  echo -e "${YELLOW}⚠ Не удалось определить docker subnet/bridge или gateway — пропускаю настройку NAT/routing для подсети контейнера.${NC}"
fi

# sysctl: rp_filter на выбранном интерфейсе (важно при multi-IP/асимметрии)
SYSCTL_FILE="/etc/sysctl.d/99-remnanode-${NODE_NAME}.conf"
cat > "${SYSCTL_FILE}" <<EOF
# Managed by RemnaNode setup (${NODE_NAME})
net.ipv4.conf.${SELECTED_IFACE}.rp_filter=0
EOF
sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true

# ================== Persist policy routing after reboot (systemd) ==================
# ip rule/ip route не переживают reboot. Создаём per-node unit, который применяет правила заново.
NET_SCRIPT="/usr/local/sbin/remnanode-net-${NODE_NAME}.sh"
NET_UNIT="/etc/systemd/system/remnanode-net-${NODE_NAME}.service"

cat > "${NET_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

NODE_NAME="__NODE_NAME__"
CONF="/opt/__NODE_NAME__/.env"

getv() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true; }

BIND_IP="$(getv BIND_IP)"
SELECTED_IFACE="$(getv SELECTED_IFACE)"
ROUTING_TABLE_ID="$(getv ROUTING_TABLE_ID)"
HOST_RULE_PRIORITY="$(getv HOST_RULE_PRIORITY)"
SUBNET_RULE_PRIORITY="$(getv SUBNET_RULE_PRIORITY)"
ROUTING_TABLE_NAME="$(getv ROUTING_TABLE_NAME)"
DOCKER_NET_NAME="$(getv DOCKER_NET_NAME)"
SYSCTL_FILE="$(getv SYSCTL_FILE)"

[[ -n "${BIND_IP:-}" && -n "${SELECTED_IFACE:-}" && -n "${ROUTING_TABLE_ID:-}" ]] || exit 0

GW="$(ip route show default dev "${SELECTED_IFACE}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
if [[ -z "${GW:-}" ]]; then
  GW="$(ip route show default 2>/dev/null | grep -m1 "src ${BIND_IP}" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
fi
[[ -n "${GW:-}" ]] || exit 0

# table routes
ip route replace default via "${GW}" dev "${SELECTED_IFACE}" table "${ROUTING_TABLE_ID}" 2>/dev/null || true

# host source rule
if [[ -n "${HOST_RULE_PRIORITY:-}" ]]; then
  ip rule del priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
  ip rule add priority "${HOST_RULE_PRIORITY}" from "${BIND_IP}/32" lookup "${ROUTING_TABLE_ID}" 2>/dev/null || true
fi

# docker subnet rule + NAT
if [[ -n "${DOCKER_NET_NAME:-}" ]]; then
  SUBNET="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  NETID="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{.Id}}' 2>/dev/null | cut -c1-12 || true)"
  BRIF=""
  [[ -n "${NETID:-}" ]] && BRIF="br-${NETID}"

  if [[ -n "${SUBNET:-}" && -n "${SUBNET_RULE_PRIORITY:-}" ]]; then
    ip rule del priority "${SUBNET_RULE_PRIORITY}" 2>/dev/null || true
    ip rule add priority "${SUBNET_RULE_PRIORITY}" from "${SUBNET}" lookup "${ROUTING_TABLE_ID}" 2>/dev/null || true
    [[ -n "${BRIF:-}" ]] && ip route replace "${SUBNET}" dev "${BRIF}" scope link table "${ROUTING_TABLE_ID}" 2>/dev/null || true

    iptables -t nat -C POSTROUTING -s "${SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "${SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -s "${SUBNET}" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s "${SUBNET}" -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -d "${SUBNET}" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d "${SUBNET}" -j ACCEPT 2>/dev/null || true
  fi
fi

# sysctl
if [[ -n "${SYSCTL_FILE:-}" && -f "${SYSCTL_FILE}" ]]; then
  sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true
fi

# persist rules if service exists
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
elif command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/iptables 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
EOS

sed -i "s/__NODE_NAME__/${NODE_NAME}/g" "${NET_SCRIPT}" 2>/dev/null || true
chmod 0755 "${NET_SCRIPT}" 2>/dev/null || true

cat > "${NET_UNIT}" <<EOF
[Unit]
Description=RemnaNode network rules for ${NODE_NAME}
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${NET_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now "remnanode-net-${NODE_NAME}.service" >/dev/null 2>&1 || true

# Сохраняем параметры в .env (для корректного remove)
for kv in \
  "ROUTING_TABLE_ID=${ROUTING_TABLE_ID}" \
  "ROUTING_TABLE_NAME=${ROUTING_TABLE_NAME}" \
  "HOST_RULE_PRIORITY=${HOST_RULE_PRIORITY}" \
  "SUBNET_RULE_PRIORITY=${SUBNET_RULE_PRIORITY}" \
  "DOCKER_NET_NAME=${DOCKER_NET_NAME:-}" \
  "DOCKER_NET_SUBNET=${DOCKER_NET_SUBNET:-}" \
  "DOCKER_BRIDGE_IFACE=${DOCKER_BRIDGE_IFACE:-}" \
  "SYSCTL_FILE=${SYSCTL_FILE}" \
  "NET_SCRIPT=${NET_SCRIPT}" \
  "NET_UNIT=${NET_UNIT}"; do
  k="${kv%%=*}"
  v="${kv#*=}"
  if grep -q "^${k}=" .env 2>/dev/null; then
    sed -i "s#^${k}=.*#${k}=${v}#" .env 2>/dev/null || true
  else
    echo "${k}=${v}" >> .env
  fi
done

# ================== UFW: открыть порт точечно (только выбранный интерфейс/IP) ==================
if command -v ufw &> /dev/null; then
  if ufw status | grep -q "Status: active"; then
    echo
    echo -e "${CYAN}🛡 UFW активен. Добавить правила для ноды (API + Xray порты) только для выбранного интерфейса/IP?${NC}"
    echo -e "${GRAY}Будут добавлены правила:${NC}"
    echo -e "${GRAY}- ${BIND_IP}:${NODE_PORT}/tcp (API)${NC}"
    echo -e "${GRAY}- ${BIND_IP}:${XRAY_PORT_HTTPS}/tcp,udp (Xray)${NC}"
    echo -e "${GRAY}- ${BIND_IP}:${XRAY_PORT_ALT}/tcp,udp (Xray)${NC}"
    read -p "👉 Добавить правило UFW? (Y/n): " ADD_UFW </dev/tty
    ADD_UFW=${ADD_UFW:-Y}
    if [[ "$ADD_UFW" =~ ^[Yy]$ ]]; then
      # API
      ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${NODE_PORT}" proto tcp comment "RemnaNode ${NODE_NAME} api tcp ${NODE_PORT}" >/dev/null 2>&1 || true
      # Xray ports (tcp/udp)
      ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_HTTPS}" proto tcp comment "RemnaNode ${NODE_NAME} xray tcp ${XRAY_PORT_HTTPS}" >/dev/null 2>&1 || true
      ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_HTTPS}" proto udp comment "RemnaNode ${NODE_NAME} xray udp ${XRAY_PORT_HTTPS}" >/dev/null 2>&1 || true
      ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_ALT}" proto tcp comment "RemnaNode ${NODE_NAME} xray tcp ${XRAY_PORT_ALT}" >/dev/null 2>&1 || true
      ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_ALT}" proto udp comment "RemnaNode ${NODE_NAME} xray udp ${XRAY_PORT_ALT}" >/dev/null 2>&1 || true
      # routed traffic: docker subnet -> uplink
      if [[ -n "${DOCKER_NET_SUBNET:-}" && -n "${DOCKER_BRIDGE_IFACE:-}" ]]; then
        ufw route allow in on "${DOCKER_BRIDGE_IFACE}" out on "${SELECTED_IFACE}" from "${DOCKER_NET_SUBNET}" to any comment "RemnaNode ${NODE_NAME} routed egress" >/dev/null 2>&1 || true
      fi
      echo -e "${GREEN}✔ UFW правила добавлены (точечно)${NC}"
    else
      echo -e "${GRAY}ℹ UFW правило не добавлено. Если порт недоступен извне — добавьте его вручную.${NC}"
    fi
  fi
fi

# ================== Финализация: перенос в /opt только после успешного старта ==================
echo
echo -e "${BLUE}📁 Переношу файлы установки в ${YELLOW}${TARGET_DIR}${NC}"
mv "$STAGE_DIR" "$TARGET_DIR"
STAGE_DIR=""  # чтобы cleanup не удалил уже перенесённое
cd "$TARGET_DIR"
INSTALL_SUCCESS="true"

echo
read -p "📜 Показать логи контейнера сейчас? (Y/n): " SHOW_LOGS </dev/tty
SHOW_LOGS=${SHOW_LOGS:-Y}
if [[ "$SHOW_LOGS" =~ ^[Yy]$ ]]; then
  echo -e "${GRAY}ℹ Для выхода из логов нажмите Ctrl+C${NC}"
  set +e
  docker compose logs -f -t
  LOG_EXIT=$?
  set -e
  if [[ "$LOG_EXIT" -eq 130 ]]; then
    echo -e "${GRAY}ℹ Вы вышли из логов (Ctrl+C). Установка завершена.${NC}"
  elif [[ "$LOG_EXIT" -ne 0 ]]; then
    echo -e "${YELLOW}⚠ Просмотр логов завершился с кодом ${LOG_EXIT}, но установка уже завершена.${NC}"
  fi
fi

echo
echo "Нажмите Enter, чтобы открыть меню установки..."
read -r

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)