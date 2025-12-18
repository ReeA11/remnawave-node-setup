#!/bin/bash
clear
# Не используем set -e, чтобы скрипт продолжал выполнение даже при ошибках
# set -e

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

echo -e "${WHITE}🗑  RemnaNode Removal Script${NC}"
echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
echo

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

  echo -e " ${GREEN}[$((i+1))]${NC} $(printf '%-15s' "$NODE_NAME") → $STATUS"
done

echo
read -p "👉 Выберите ноду для удаления [1-${#NODES[@]}]: " CHOICE </dev/tty

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#NODES[@]} )); then
  echo -e "${RED}❌ Неверный выбор${NC}"
  exit 1
fi

TARGET_DIR="${NODES[$((CHOICE-1))]}"
NODE_NAME="$(basename "$TARGET_DIR")"

# Читаем информацию о сети из .env (если есть)
USE_CUSTOM_NETWORK="false"
NETWORK_NAME=""
NETWORK_SUBNET=""
SELECTED_IFACE=""
BIND_IP=""
NODE_PORT=""
XRAY_PORT_HTTPS="443"
XRAY_PORT_ALT="8443"
HOST_RULE_PRIORITY=""
SUBNET_RULE_PRIORITY=""
DOCKER_NET_NAME=""
DOCKER_NET_SUBNET=""
DOCKER_BRIDGE_IFACE=""
SYSCTL_FILE=""
NET_SCRIPT=""
NET_UNIT=""
ROUTING_TABLE_ID=""
ROUTING_RULE_PRIORITY=""
ROUTING_TABLE_NAME=""

if [[ -f "$TARGET_DIR/.env" ]]; then
  USE_CUSTOM_NETWORK=$(grep "^USE_CUSTOM_NETWORK=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "false")
  BIND_IP=$(grep "^BIND_IP=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
  NODE_PORT=$(grep "^NODE_PORT=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
  XRAY_PORT_HTTPS=$(grep "^XRAY_PORT_HTTPS=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "443")
  XRAY_PORT_ALT=$(grep "^XRAY_PORT_ALT=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "8443")
  HOST_RULE_PRIORITY=$(grep "^HOST_RULE_PRIORITY=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
  SUBNET_RULE_PRIORITY=$(grep "^SUBNET_RULE_PRIORITY=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
  DOCKER_NET_NAME=$(grep "^DOCKER_NET_NAME=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  DOCKER_NET_SUBNET=$(grep "^DOCKER_NET_SUBNET=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  DOCKER_BRIDGE_IFACE=$(grep "^DOCKER_BRIDGE_IFACE=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  SYSCTL_FILE=$(grep "^SYSCTL_FILE=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  NET_SCRIPT=$(grep "^NET_SCRIPT=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  NET_UNIT=$(grep "^NET_UNIT=" "$TARGET_DIR/.env" | cut -d'=' -f2- || echo "")
  if [[ "$USE_CUSTOM_NETWORK" == "true" ]]; then
    NETWORK_NAME=$(grep "^NETWORK_NAME=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
    NETWORK_SUBNET=$(grep "^NETWORK_SUBNET=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
    SELECTED_IFACE=$(grep "^SELECTED_IFACE=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
    ROUTING_TABLE_ID=$(grep "^ROUTING_TABLE_ID=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
    ROUTING_RULE_PRIORITY=$(grep "^ROUTING_RULE_PRIORITY=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
    ROUTING_TABLE_NAME=$(grep "^ROUTING_TABLE_NAME=" "$TARGET_DIR/.env" | cut -d'=' -f2 || echo "")
  fi
fi

# ================== Удаление UFW правил (по комментарию) ==================
remove_ufw_rules_for_node() {
  local node="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status | grep -q "Status: active" || return 0

  # Удаляем по номеру правила. Важно: удалять в обратном порядке, т.к. номера сдвигаются.
  mapfile -t nums < <(ufw status numbered 2>/dev/null | grep -F "RemnaNode ${node}" | awk -F'[][]' '{print $2}' | tr -d ' ' | grep -E '^[0-9]+$' | sort -nr)
  if [[ "${#nums[@]}" -eq 0 ]]; then
    return 0
  fi

  echo -e "${BLUE}[*] Удаляю UFW правила для ноды ${node}...${NC}"
  for n in "${nums[@]}"; do
    ufw --force delete "$n" >/dev/null 2>&1 || true
  done
  echo -e "${GREEN}✔ UFW правила удалены${NC}"
}

# ================== Проверка безопасности ==================
# Проверяем, что мы не удаляем системные настройки
SAFETY_CHECK_FAILED="false"

if [[ "$USE_CUSTOM_NETWORK" == "true" ]]; then
  # Проверка имени сети - должно начинаться с "br-" (наша конвенция)
  if [[ -n "$NETWORK_NAME" && ! "$NETWORK_NAME" =~ ^br- ]]; then
    echo -e "${RED}❌ ОШИБКА БЕЗОПАСНОСТИ: Имя сети не соответствует паттерну br-*${NC}"
    echo -e "${RED}   Пропускаю удаление сети для безопасности${NC}"
    SAFETY_CHECK_FAILED="true"
    USE_CUSTOM_NETWORK="false"
  fi
  
  # Проверка подсети - не должна быть системной
  if [[ -n "$NETWORK_SUBNET" ]]; then
    SUBNET_BASE=$(echo "$NETWORK_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1)
    # Проверяем, что это не системные подсети
    if [[ "$SUBNET_BASE" == "127" ]] || [[ "$NETWORK_SUBNET" == "172.17.0.0/16" ]]; then
      echo -e "${RED}❌ ОШИБКА БЕЗОПАСНОСТИ: Попытка удалить системную подсеть${NC}"
      echo -e "${RED}   Пропускаю удаление routing правил для безопасности${NC}"
      SAFETY_CHECK_FAILED="true"
      NETWORK_SUBNET=""
    fi
  fi
  
  # Проверка интерфейса - не должен быть системным
  if [[ -n "$SELECTED_IFACE" ]]; then
    SYSTEM_IFACES=("lo" "docker0" "virbr0" "lxcbr0")
    for sys_iface in "${SYSTEM_IFACES[@]}"; do
      if [[ "$SELECTED_IFACE" == "$sys_iface" ]]; then
        echo -e "${RED}❌ ОШИБКА БЕЗОПАСНОСТИ: Попытка удалить правила для системного интерфейса${NC}"
        echo -e "${RED}   Пропускаю удаление SNAT правил для безопасности${NC}"
        SAFETY_CHECK_FAILED="true"
        SELECTED_IFACE=""
        break
      fi
    done
    
    # Проверяем, что интерфейс существует
    if [[ -n "$SELECTED_IFACE" && ! -d "/sys/class/net/$SELECTED_IFACE" ]]; then
      echo -e "${YELLOW}⚠ Интерфейс $SELECTED_IFACE не найден, пропускаю удаление SNAT${NC}"
      SELECTED_IFACE=""
    fi
    
    # Проверяем, что интерфейс не является основным интерфейсом провайдера (обычно eth0)
    # Это дополнительная защита от удаления базовых настроек
    if [[ -n "$SELECTED_IFACE" ]]; then
      # Проверяем, что это не единственный интерфейс с default route
      MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
      if [[ -n "$MAIN_IFACE" && "$SELECTED_IFACE" == "$MAIN_IFACE" ]]; then
        # Если это основной интерфейс, проверяем, что у нас есть другие интерфейсы
        OTHER_IFACES=$(ip -o -4 addr show | awk '$2 != "lo" && $2 != "docker0" && $2 != "'"$SELECTED_IFACE"'" {print $2}' | wc -l)
        if [[ "$OTHER_IFACES" -eq 0 ]]; then
          echo -e "${YELLOW}⚠ Предупреждение: $SELECTED_IFACE является основным интерфейсом${NC}"
          echo -e "${YELLOW}   Будьте осторожны при удалении SNAT правил${NC}"
        fi
      fi
    fi
  fi
fi

echo
echo -e "${YELLOW}⚠ Будет удалено:${NC}"
echo -e " 📁 Директория: ${RED}$TARGET_DIR${NC}"
echo -e " 🐳 Контейнер:  ${RED}$NODE_NAME${NC}"
if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$NETWORK_NAME" ]]; then
  echo -e " 🌐 Сеть:       ${RED}$NETWORK_NAME${NC}"
  echo -e " 🔀 Routing:    ${RED}правила для $NETWORK_SUBNET${NC}"
  echo -e " 🔀 SNAT:       ${RED}правила для $SELECTED_IFACE${NC}"
fi
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

# ================== Удаление UFW правил этой ноды ==================
remove_ufw_rules_for_node "$NODE_NAME"

# ================== Удаление systemd unit для network rules ==================
if [[ -n "${NET_UNIT:-}" ]]; then
  systemctl disable --now "$(basename "${NET_UNIT}")" >/dev/null 2>&1 || true
  rm -f "${NET_UNIT}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if [[ -n "${NET_SCRIPT:-}" ]]; then
  rm -f "${NET_SCRIPT}" 2>/dev/null || true
fi

# ================== Удаление ip rule/ip route/iptables для этой ноды (новый режим) ==================
if [[ -n "${HOST_RULE_PRIORITY:-}" ]]; then
  ip rule del priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
fi
if [[ -n "${SUBNET_RULE_PRIORITY:-}" ]]; then
  ip rule del priority "${SUBNET_RULE_PRIORITY}" 2>/dev/null || true
fi

# iptables: удаляем по подсети, если она известна (или пытаемся получить из docker network)
SUBNET_CIDR="${DOCKER_NET_SUBNET:-}"
if [[ -z "${SUBNET_CIDR:-}" && -n "${DOCKER_NET_NAME:-}" ]]; then
  SUBNET_CIDR="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
fi
if [[ -n "${SUBNET_CIDR:-}" && -n "${SELECTED_IFACE:-}" ]]; then
  # nat postrouting
  while iptables -t nat -C POSTROUTING -s "${SUBNET_CIDR}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "${SUBNET_CIDR}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || break
  done
  # forward accept
  while iptables -C FORWARD -s "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -s "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null || break
  done
  while iptables -C FORWARD -d "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -d "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null || break
  done
fi

# sysctl drop-in
if [[ -n "${SYSCTL_FILE:-}" && -f "${SYSCTL_FILE}" ]]; then
  rm -f "${SYSCTL_FILE}" 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
fi

# persist iptables if possible
if command -v netfilter-persistent &> /dev/null; then
  netfilter-persistent save 2>/dev/null || true
elif command -v iptables-save &> /dev/null; then
  mkdir -p /etc/iptables 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# ================== Удаление Routing и SNAT правил ==================
if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$NETWORK_SUBNET" && "$SAFETY_CHECK_FAILED" != "true" ]]; then
  echo -e "${BLUE}[*] Удаляю routing и SNAT правила...${NC}"
  
  # Используем временное отключение set -e для этой секции (если бы оно было включено)
  set +e
  
  # Удаляем policy routing правило
  # Новый формат: ROUTING_TABLE_ID/ROUTING_RULE_PRIORITY сохранены в .env
  # Старый формат: lookup 101 priority 1002
  if [[ -z "$ROUTING_TABLE_ID" ]]; then
    ROUTING_TABLE_ID="101"
  fi
  if [[ -z "$ROUTING_TABLE_NAME" ]]; then
    if [[ "$ROUTING_TABLE_ID" == "101" ]]; then
      ROUTING_TABLE_NAME="remnanode"
    else
      ROUTING_TABLE_NAME="remnanode_${NODE_NAME}"
    fi
  fi
  if [[ -z "$ROUTING_RULE_PRIORITY" ]]; then
    ROUTING_RULE_PRIORITY="1002"
  fi

  ROUTING_RULE=$(ip rule show | grep "from ${NETWORK_SUBNET}" | grep "priority ${ROUTING_RULE_PRIORITY}" || true)
  
  if [[ -n "$ROUTING_RULE" ]]; then
    # Дополнительная проверка: убеждаемся, что это наше правило (lookup ROUTING_TABLE_ID)
    if echo "$ROUTING_RULE" | grep -q -E "lookup (${ROUTING_TABLE_ID}|${ROUTING_TABLE_NAME})"; then
      # Проверяем, используется ли эта подсеть другими сетями Docker
      OTHER_NETWORKS_USE_SUBNET="false"
      for net_name in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^${NETWORK_NAME}$"); do
        net_subnet=$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -1)
        if [[ "$net_subnet" == "$NETWORK_SUBNET" ]]; then
          OTHER_NETWORKS_USE_SUBNET="true"
          break
        fi
      done
      
      if [[ "$OTHER_NETWORKS_USE_SUBNET" == "false" ]]; then
        # Удаляем правило только если нет других сетей с этой подсетью
        ip rule del from "${NETWORK_SUBNET}" lookup "${ROUTING_TABLE_ID}" priority "${ROUTING_RULE_PRIORITY}" 2>/dev/null || \
        ip rule del from "${NETWORK_SUBNET}" lookup "${ROUTING_TABLE_NAME}" priority "${ROUTING_RULE_PRIORITY}" 2>/dev/null && {
          echo -e "${GREEN}✔ Правило routing удалено${NC}"
          
          # Удаляем маршрут подсети из нашей таблицы (только для нашей подсети)
          if ip route show table "${ROUTING_TABLE_NAME}" | grep -q "${NETWORK_SUBNET}"; then
            ip route del "${NETWORK_SUBNET}" table "${ROUTING_TABLE_NAME}" 2>/dev/null && {
              echo -e "${GREEN}✔ Маршрут ${NETWORK_SUBNET} удален из table ${ROUTING_TABLE_ID}${NC}"
            } || {
              echo -e "${YELLOW}⚠ Не удалось удалить маршрут из table ${ROUTING_TABLE_ID}${NC}"
            }
          fi
        } || {
          echo -e "${YELLOW}⚠ Не удалось удалить правило routing (возможно, уже удалено)${NC}"
        }
      else
        echo -e "${GRAY}⚠ Правило routing не удалено (используется другими сетями)${NC}"
        echo -e "${GRAY}⚠ Маршрут в table ${ROUTING_TABLE_ID} не удален (используется другими сетями)${NC}"
      fi
    else
      echo -e "${YELLOW}⚠ Правило routing найдено, но имеет другой lookup table (не наше правило)${NC}"
      echo -e "${YELLOW}   Пропускаю удаление для безопасности${NC}"
    fi
  else
    echo -e "${GRAY}⚠ Правило routing не найдено (возможно, уже удалено)${NC}"
  fi
  
  # Дополнительная проверка: удаляем маршрут из нашей таблицы только если он точно наш
  # Проверяем, что маршрут существует и соответствует нашей подсети
  if [[ -n "$NETWORK_SUBNET" && "$SAFETY_CHECK_FAILED" != "true" ]]; then
    ROUTE_IN_TABLE=$(ip route show table "${ROUTING_TABLE_ID}" | grep "${NETWORK_SUBNET}" | head -1)
    if [[ -n "$ROUTE_IN_TABLE" ]]; then
      # Проверяем, что маршрут идет через наш интерфейс (если указан)
      if [[ -n "$SELECTED_IFACE" ]]; then
        if echo "$ROUTE_IN_TABLE" | grep -q "dev ${SELECTED_IFACE}"; then
          # Это наш маршрут, удаляем его
          ip route del "${NETWORK_SUBNET}" table "${ROUTING_TABLE_ID}" 2>/dev/null && {
            echo -e "${GREEN}✔ Маршрут ${NETWORK_SUBNET} удален из table ${ROUTING_TABLE_ID}${NC}"
          } || {
            echo -e "${YELLOW}⚠ Не удалось удалить маршрут из table ${ROUTING_TABLE_ID}${NC}"
          }
        else
          echo -e "${YELLOW}⚠ Маршрут ${NETWORK_SUBNET} в table ${ROUTING_TABLE_ID} идет через другой интерфейс${NC}"
          echo -e "${YELLOW}   Пропускаю удаление для безопасности${NC}"
        fi
      else
        # Если интерфейс не указан, удаляем маршрут только если нет других сетей с этой подсетью
        OTHER_NETWORKS_USE_SUBNET="false"
        for net_name in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^${NETWORK_NAME}$"); do
          net_subnet=$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -1)
          if [[ "$net_subnet" == "$NETWORK_SUBNET" ]]; then
            OTHER_NETWORKS_USE_SUBNET="true"
            break
          fi
        done
        
        if [[ "$OTHER_NETWORKS_USE_SUBNET" == "false" ]]; then
          ip route del "${NETWORK_SUBNET}" table "${ROUTING_TABLE_ID}" 2>/dev/null && {
            echo -e "${GREEN}✔ Маршрут ${NETWORK_SUBNET} удален из table ${ROUTING_TABLE_ID}${NC}"
          } || {
            echo -e "${YELLOW}⚠ Не удалось удалить маршрут из table ${ROUTING_TABLE_ID}${NC}"
          }
        else
          echo -e "${GRAY}⚠ Маршрут в table ${ROUTING_TABLE_ID} не удален (используется другими сетями)${NC}"
        fi
      fi
    fi
    
    # ВАЖНО: НЕ удаляем default route из routing table, даже если он там есть
    # Это может быть базовая настройка провайдера или других сервисов
    DEFAULT_ROUTE_EXISTS=$(ip route show table "${ROUTING_TABLE_ID}" | grep -c "^default" || echo "0")
    if [[ "$DEFAULT_ROUTE_EXISTS" -gt 0 ]]; then
      echo -e "${GRAY}ℹ Default route в table ${ROUTING_TABLE_ID} не удален (может быть базовой настройкой)${NC}"
    fi
  fi
  
fi

# ================== Очистка rt_tables (если запись относится к ноде) ==================
# Старые версии setup могли писать строку вида: "<id> remnanode_<NODE_NAME>".
if [[ -n "${ROUTING_TABLE_ID:-}" && -n "${ROUTING_TABLE_NAME:-}" && -f /etc/iproute2/rt_tables ]]; then
  if grep -q -E "^${ROUTING_TABLE_ID}[[:space:]]+${ROUTING_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
    # Удаляем только если имя таблицы явно привязано к этой ноде
    if [[ "$ROUTING_TABLE_NAME" == "remnanode_${NODE_NAME}" || "$ROUTING_TABLE_NAME" == "remnanode_remnanode2" || "$ROUTING_TABLE_NAME" == "remnanode_remnanode3" ]]; then
      # Пытаемся удалить строку аккуратно
      sed -i -E "/^${ROUTING_TABLE_ID}[[:space:]]+${ROUTING_TABLE_NAME}$/d" /etc/iproute2/rt_tables 2>/dev/null || true
      echo -e "${GRAY}ℹ Удалена запись из /etc/iproute2/rt_tables: ${ROUTING_TABLE_ID} ${ROUTING_TABLE_NAME}${NC}"
    fi
  fi
fi

# Удаление SNAT правил (только если интерфейс валиден)
if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$SELECTED_IFACE" && -n "$NETWORK_SUBNET" && "$SAFETY_CHECK_FAILED" != "true" ]]; then
  echo -e "${BLUE}[*] Удаляю SNAT правила...${NC}"
  
  # Удаляем SNAT правило
  if [[ -n "$BIND_IP" ]]; then
    # Пробуем удалить SNAT правило с известным BIND_IP и интерфейсом
    if iptables -t nat -C POSTROUTING -s "${NETWORK_SUBNET}" -o "${SELECTED_IFACE}" -j SNAT --to-source "${BIND_IP}" 2>/dev/null; then
      iptables -t nat -D POSTROUTING -s "${NETWORK_SUBNET}" -o "${SELECTED_IFACE}" -j SNAT --to-source "${BIND_IP}" 2>/dev/null && {
        echo -e "${GREEN}✔ Правило SNAT удалено${NC}"
        
        # Сохраняем изменения iptables
        if command -v netfilter-persistent &> /dev/null; then
          netfilter-persistent save 2>/dev/null || true
        elif command -v iptables-save &> /dev/null && [ -d /etc/iptables ]; then
          iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
      } || {
        echo -e "${YELLOW}⚠ Не удалось удалить правило SNAT${NC}"
      }
    else
      # Пробуем найти и удалить SNAT правило по подсети и интерфейсу
      # Ищем правило, которое точно соответствует нашей подсети и интерфейсу
      SNAT_FOUND="false"
      while IFS= read -r line; do
        LINE_NUM=$(echo "$line" | awk '{print $1}')
        if [[ -n "$LINE_NUM" && "$LINE_NUM" =~ ^[0-9]+$ ]]; then
          # Проверяем, что это правило для нашей подсети и интерфейса
          RULE_DETAILS=$(iptables -t nat -L POSTROUTING -n --line-numbers | sed -n "${LINE_NUM}p")
          if echo "$RULE_DETAILS" | grep -q "${NETWORK_SUBNET}" && echo "$RULE_DETAILS" | grep -q "${SELECTED_IFACE}"; then
            # Проверяем, что это SNAT правило (не MASQUERADE)
            if echo "$RULE_DETAILS" | grep -q "SNAT"; then
              iptables -t nat -D POSTROUTING "$LINE_NUM" 2>/dev/null && {
                echo -e "${GREEN}✔ Правило SNAT удалено${NC}"
                SNAT_FOUND="true"
                
                # Сохраняем изменения iptables
                if command -v netfilter-persistent &> /dev/null; then
                  netfilter-persistent save 2>/dev/null || true
                elif command -v iptables-save &> /dev/null && [ -d /etc/iptables ]; then
                  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
                break
              }
            fi
          fi
        fi
      done < <(iptables -t nat -L POSTROUTING -n --line-numbers | grep -n "${NETWORK_SUBNET}" | grep "${SELECTED_IFACE}")
      
      if [[ "$SNAT_FOUND" == "false" ]]; then
        echo -e "${GRAY}⚠ Правило SNAT не найдено (возможно, уже удалено)${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}⚠ BIND_IP не найден в .env, пропускаю удаление SNAT${NC}"
  fi
else
  if [[ "$USE_CUSTOM_NETWORK" == "true" && "$SAFETY_CHECK_FAILED" == "true" ]]; then
    echo -e "${YELLOW}⚠ Удаление SNAT правил пропущено из-за проверок безопасности${NC}"
  fi
fi

# ================== Удаление Docker Network ==================
if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$NETWORK_NAME" && "$SAFETY_CHECK_FAILED" != "true" ]]; then
  echo -e "${BLUE}[*] Проверяю сеть ${NETWORK_NAME}...${NC}"
  
  if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    # Проверяем, что это не системная сеть Docker
    SYSTEM_NETWORKS=("bridge" "host" "none")
    IS_SYSTEM_NETWORK="false"
    for sys_net in "${SYSTEM_NETWORKS[@]}"; do
      if [[ "$NETWORK_NAME" == "$sys_net" ]]; then
        IS_SYSTEM_NETWORK="true"
        break
      fi
    done
    
    if [[ "$IS_SYSTEM_NETWORK" == "true" ]]; then
      echo -e "${RED}❌ ОШИБКА БЕЗОПАСНОСТИ: Попытка удалить системную сеть Docker${NC}"
      echo -e "${RED}   Пропускаю удаление сети для безопасности${NC}"
    else
      # Проверяем, используется ли сеть другими контейнерами
      CONTAINERS_IN_NETWORK=$(docker network inspect "${NETWORK_NAME}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -v "^$" | grep -v "^${NODE_NAME}$" | wc -l)
      
      if [[ "$CONTAINERS_IN_NETWORK" -eq 0 ]]; then
        echo -e "${BLUE}[*] Удаляю Docker network ${NETWORK_NAME}...${NC}"
        docker network rm "${NETWORK_NAME}" 2>/dev/null && {
          echo -e "${GREEN}✔ Сеть ${NETWORK_NAME} удалена${NC}"
        } || {
          echo -e "${YELLOW}⚠ Не удалось удалить сеть ${NETWORK_NAME}${NC}"
        }
      else
        echo -e "${GRAY}⚠ Сеть ${NETWORK_NAME} не удалена (используется другими контейнерами)${NC}"
      fi
    fi
  else
    echo -e "${GRAY}Сеть ${NETWORK_NAME} не найдена${NC}"
  fi
fi

# ================== Удаление директории ==================
# Удаление директории выполняется всегда, даже если были ошибки выше
echo -e "${BLUE}[*] Удаляю директорию $TARGET_DIR...${NC}"

if [[ -d "$TARGET_DIR" ]]; then
  # Пробуем удалить директорию
  if rm -rf "$TARGET_DIR" 2>/dev/null; then
    # Проверяем, что директория действительно удалена
    if [[ ! -d "$TARGET_DIR" ]]; then
      echo -e "${GREEN}✔ Директория $TARGET_DIR удалена${NC}"
    else
      echo -e "${YELLOW}⚠ Директория $TARGET_DIR все еще существует${NC}"
      echo -e "${YELLOW}   Пробую принудительное удаление...${NC}"
      # Пробуем принудительное удаление
      rm -rf "$TARGET_DIR"/* "$TARGET_DIR"/.* 2>/dev/null || true
      rmdir "$TARGET_DIR" 2>/dev/null && {
        echo -e "${GREEN}✔ Директория $TARGET_DIR удалена${NC}"
      } || {
        echo -e "${RED}❌ Не удалось удалить директорию $TARGET_DIR${NC}"
        echo -e "${RED}   Проверьте права доступа и содержимое директории${NC}"
        echo -e "${GRAY}   Выполните вручную: rm -rf $TARGET_DIR${NC}"
      }
    fi
  else
    echo -e "${YELLOW}⚠ Ошибка при удалении директории $TARGET_DIR${NC}"
    echo -e "${YELLOW}   Пробую принудительное удаление...${NC}"
    rm -rf "$TARGET_DIR"/* "$TARGET_DIR"/.* 2>/dev/null || true
    rmdir "$TARGET_DIR" 2>/dev/null || {
      echo -e "${RED}❌ Не удалось удалить директорию $TARGET_DIR${NC}"
      echo -e "${GRAY}   Выполните вручную: rm -rf $TARGET_DIR${NC}"
    }
  fi
else
  echo -e "${GRAY}Директория $TARGET_DIR не найдена (возможно, уже удалена)${NC}"
fi

echo
echo -e "${GREEN}🎉 Нода $NODE_NAME успешно удалена 🎉${NC}"
echo

# ================== Возврат в меню ==================
echo "Нажмите Enter, чтобы открыть меню установки..."
read -r

bash <(curl -Ls https://raw.githubusercontent.com/ReeA11/remnawave-node-setup/refs/heads/master/menu.sh)
