#!/bin/bash
# Интерактивное меню управления BGP маршрутами

PROJECT_DIR="/root/bgp_geo"
CONFIG_FILE="$PROJECT_DIR/config.json"
ALLOW_DOMAINS_DIR="$PROJECT_DIR/allow-domains"
AS_PREFIXES_DIR="$PROJECT_DIR/as_prefixes"

# Цвета
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
M='\033[0;35m'
C='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Функции
header() {
    clear
    echo -e "${B}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${B}${BOLD}║${NC}${BOLD}          BGP Route Server - Управление                    ${NC}${B}${BOLD}║${NC}"
    echo -e "${B}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

get_services() {
    find "$ALLOW_DOMAINS_DIR" -name "*.lst" -not -path "*/.git/*" -not -path "*/src/*" -not -path "*/proto/*" 2>/dev/null | while read -r f; do
        basename "$f" .lst | tr '[:upper:]' '[:lower:]'
    done | sort -u
}

get_enabled_services() {
    python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(' '.join(c.get('services',[])))" 2>/dev/null
}

get_as_list() {
    python3 -c "import json; c=json.load(open('$CONFIG_FILE')); d=c.get('as_numbers',{}); [print(f'{k} {v}') for k,v in d.items()]" 2>/dev/null
}

get_route_count() {
    birdc "show route count" 2>/dev/null | grep "of.*routes" | head -1 | awk '{print $1}'
}

get_bgp_status() {
    birdc "show protocols" 2>/dev/null | grep "client" | awk '{print $4}'
}

toggle_service() {
    local svc=$1
    local enabled=$(get_enabled_services)

    if echo "$enabled" | grep -qw "$svc"; then
        # Отключаем
        python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if '$svc' in c.get('services', []):
    c['services'].remove('$svc')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print("$svc отключён")
EOF
    else
        # Включаем
        python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if 'services' not in c:
    c['services'] = []
if '$svc' not in c['services']:
    c['services'].append('$svc')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print("$svc включён")
EOF
    fi
}

add_as() {
    local as_num=$1
    local name=$2

    if [[ ! "$as_num" =~ ^AS[0-9]+$ ]]; then
        as_num="AS${as_num}"
    fi

    echo -e "${C}Получение префиксов $as_num...${NC}"

    python3 << EOF
import urllib.request
import json
import ipaddress

as_num = "${as_num}".replace('AS', '')
url = f"https://stat.ripe.net/data/announced-prefixes/data.json?resource={as_num}"

try:
    response = urllib.request.urlopen(url, timeout=15)
    data = json.loads(response.read())

    prefixes = []
    if data.get('data') and data['data'].get('prefixes'):
        for p in data['data']['prefixes']:
            prefix = p.get('prefix', '')
            if ':' not in prefix:
                try:
                    network = ipaddress.ip_network(prefix, strict=False)
                    if network.prefixlen <= 24:
                        prefixes.append(prefix)
                except:
                    pass

    if prefixes:
        with open('$AS_PREFIXES_DIR/${as_num}.txt', 'w') as f:
            f.write('\n'.join(sorted(prefixes)))

        with open('$CONFIG_FILE') as f:
            c = json.load(f)
        if 'as_numbers' not in c:
            c['as_numbers'] = {}
        c['as_numbers']['${as_num}'] = '${name}'
        with open('$CONFIG_FILE', 'w') as f:
            json.dump(c, f, indent=2)

        print(f"[+] {as_num}: {len(prefixes)} префиксов")
    else:
        print(f"[-] Не найдено префиксов для {as_num}")
except Exception as e:
    print(f"[-] Ошибка: {e}")
EOF
}

remove_as() {
    local as_num=$1
    if [[ ! "$as_num" =~ ^AS[0-9]+$ ]]; then
        as_num="AS${as_num}"
    fi

    python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if 'as_numbers' in c and '$as_num' in c['as_numbers']:
    del c['as_numbers']['$as_num']
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(c, f, indent=2)
    print(f"[+] $as_num удалён")
else:
    print(f"[*] $as_num не найден")
EOF

    rm -f "$AS_PREFIXES_DIR/${as_num}.txt"
}

add_domain() {
    local domain=$1
    local name=${2:-$domain}

    echo -e "${C}Резолвинг $domain...${NC}"

    ips=$(dig +short +time=2 A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -20)

    if [ -n "$ips" ]; then
        ip_count=$(echo "$ips" | wc -l)

        # Создаём /24
        slash24s=$(echo "$ips" | while read ip; do
            IFS='.' read -r a b c d <<< "$ip"
            echo "$a.$b.$c.0/24"
        done | sort -u)

        slash24_count=$(echo "$slash24s" | wc -l)

        # Формируем JSON массивы
        ips_json="[$(echo "$ips" | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')]"
        slash24s_json="[$(echo "$slash24s" | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')]"

        python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if 'custom_domains' not in c:
    c['custom_domains'] = {}
c['custom_domains']['$domain'] = {
    'name': '${name}',
    'ips': $ips_json,
    'slash24s': $slash24s_json
}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
EOF

        echo -e "${G}[+]${NC} $domain: $ip_count IP → $slash24_count /24"
    else
        echo -e "${R}[-]${NC} Не удалось резолвить $domain"
    fi
}

generate() {
    echo -e "${C}Генерация конфига...${NC}"
    python3 "$PROJECT_DIR/bgpctl.py" generate 2>&1 | tail -5
}

show_status() {
    local enabled=$(get_enabled_services)
    local as_list=$(get_as_list)
    local routes=$(get_route_count)
    local bgp=$(get_bgp_status)

    echo -e "${BOLD}Состояние BGP:${NC} $bgp"
    echo -e "${BOLD}Маршрутов:${NC} $routes"
    echo ""

    echo -e "${BOLD}Включённые сервисы ($(echo $enabled | wc -w)):${NC}"
    if [ -n "$enabled" ]; then
        echo "$enabled" | tr ' ' '\n' | nl -w2 -s'. '
    else
        echo "  (нет)"
    fi
    echo ""

    echo -e "${BOLD}AS ($(echo "$as_list" | wc -l)):${NC}"
    if [ -n "$as_list" ]; then
        echo "$as_list" | while read -r line; do
            echo "  • $line"
        done
    else
        echo "  (нет)"
    fi
}

# Меню сервисов
menu_services() {
    local page=0
    local per_page=20

    while true; do
        header
        echo -e "${BOLD}[1] Управление сервисами${NC}"
        echo ""

        # Показываем сервисы с постраничной навигацией
        local all_services=$(get_services)
        local total=$(echo "$all_services" | wc -l)
        local enabled=$(get_enabled_services)

        echo "$all_services" | tail -n +$((page * per_page + 1)) | head -n $per_page | nl -v $((page * per_page + 1)) -w2 -s'. '

        echo ""
        if [ $((page * per_page + per_page)) -lt $total ]; then
            echo "  n. Следующая страница"
        fi
        if [ $page -gt 0 ]; then
            echo "  p. Предыдущая страница"
        fi
        echo -e "${B}[0]${NC} Назад"
        echo ""
        echo -ne "${C}Выбор (номер или 0):${NC} "
        read -r choice

        if [ "$choice" = "0" ]; then
            break
        elif [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
            page=$((page + 1))
        elif [ "$choice" = "p" ] || [ "$choice" = "P" ]; then
            if [ $page -gt 0 ]; then
                page=$((page - 1))
            fi
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            svc=$(echo "$all_services" | sed -n "${choice}p")
            if [ -n "$svc" ]; then
                # Подменю управления сервисом
                while true; do
                    header
                    echo -e "${BOLD}Сервис: $svc${NC}"
                    echo ""

                    if echo "$enabled" | grep -qw "$svc"; then
                        echo -e "Текущий статус: ${G}ВКЛЮЧЁН${NC}"
                    else
                        echo -e "Текущий статус: ${R}ВЫКЛЮЧЕН${NC}"
                    fi
                    echo ""
                    echo "Действия:"
                    echo "  1. Включить"
                    echo "  2. Отключить"
                    echo "  0. Назад"
                    echo ""
                    echo -ne "${C}Выбор:${NC} "
                    read -r action

                    if [ "$action" = "0" ]; then
                        break
                    elif [ "$action" = "1" ]; then
                        toggle_service "$svc"
                        enabled=$(get_enabled_services)
                        echo ""
                        echo -e "${G}Нажмите Enter...${NC}"
                        read
                    elif [ "$action" = "2" ]; then
                        toggle_service "$svc"
                        enabled=$(get_enabled_services)
                        echo ""
                        echo -e "${G}Нажмите Enter...${NC}"
                        read
                    fi
                done
            fi
        fi
    done
}

# Меню AS
menu_as() {
    while true; do
        header
        echo -e "${BOLD}[2] Управление AS${NC}"
        echo ""
        echo "Текущие AS:"
        get_as_list | while read -r line; do
            echo "  • $line"
        done
        echo ""
        echo "Действия:"
        echo "  1. Добавить AS"
        echo "  2. Удалить AS"
        echo "  0. Назад"
        echo ""
        echo -ne "${C}Выбор:${NC} "
        read -r choice

        if [ "$choice" = "0" ]; then
            break
        fi

        if [ "$choice" = "1" ]; then
            echo -ne "AS номер (например 12876): "
            read -r as_num
            echo -ne "Название: "
            read -r as_name
            add_as "$as_num" "$as_name"
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        elif [ "$choice" = "2" ]; then
            echo -ne "AS номер для удаления: "
            read -r as_num
            remove_as "$as_num"
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        fi
    done
}

# Меню кастомных маршрутов
menu_custom() {
    while true; do
        header
        echo -e "${BOLD}[3] Кастомные маршруты${NC}"
        echo ""

        # Показываем кастомные домены
        local domains=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
for d, v in c.get('custom_domains', {}).items():
    ips = ', '.join(v.get('ips', []))
    slash24s = ', '.join(v.get('slash24s', []))
    print(f'  {d} -> {slash24s}')
" 2>/dev/null)
        if [ -n "$domains" ]; then
            echo -e "${BOLD}Домены:${NC}"
            echo "$domains"
        else
            echo -e "${BOLD}Домены:${NC} (нет)"
        fi
        echo ""

        # Показываем кастомные подсети
        local subnets=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
for s, name in c.get('custom_subnets', {}).items():
    print(f'  {s} ({name})')
" 2>/dev/null)
        if [ -n "$subnets" ]; then
            echo -e "${BOLD}Подсети:${NC}"
            echo "$subnets"
        else
            echo -e "${BOLD}Подсети:${NC} (нет)"
        fi
        echo ""

        echo "Действия:"
        echo "  1. Добавить домен"
        echo "  2. Добавить подсеть"
        echo "  3. Удалить домен"
        echo "  4. Удалить подсеть"
        echo "  0. Назад"
        echo ""
        echo -ne "${C}Выбор:${NC} "
        read -r choice

        if [ "$choice" = "0" ]; then
            break
        fi

        if [ "$choice" = "1" ]; then
            echo -ne "Домен: "
            read -r domain
            add_domain "$domain"
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        elif [ "$choice" = "2" ]; then
            echo -ne "Подсеть (например 1.1.1.0/24): "
            read -r subnet
            echo -ne "Описание: "
            read -r desc
            python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if 'custom_subnets' not in c:
    c['custom_subnets'] = {}
c['custom_subnets']['$subnet'] = '$desc'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(c, f, indent=2)
print("[+] $subnet добавлен")
EOF
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        elif [ "$choice" = "3" ]; then
            echo -ne "Домен для удаления: "
            read -r domain
            python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if '$domain' in c.get('custom_domains', {}):
    del c['custom_domains']['$domain']
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(c, f, indent=2)
    print("[+] $domain удалён")
else:
    print("[-] $domain не найден")
EOF
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        elif [ "$choice" = "4" ]; then
            echo -ne "Подсеть для удаления: "
            read -r subnet
            python3 << EOF
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
if '$subnet' in c.get('custom_subnets', {}):
    del c['custom_subnets']['$subnet']
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(c, f, indent=2)
    print("[+] $subnet удалена")
else:
    print("[-] $subnet не найдена")
EOF
            echo ""
            echo -e "${G}Нажмите Enter...${NC}"
            read
        fi
    done
}

# Главное меню
main_menu() {
    while true; do
        header
        show_status
        echo ""
        echo -e "${BOLD}Меню:${NC}"
        echo "  1. Сервисы"
        echo "  2. AS"
        echo "  3. Кастомные маршруты"
        echo "  4. Генерировать и применить"
        echo "  5. Обновить все (резолв+AS)"
        echo "  0. Выход"
        echo ""
        echo -ne "${C}Выбор:${NC} "
        read -r choice

        case $choice in
            1) menu_services ;;
            2) menu_as ;;
            3) menu_custom ;;
            4)
                generate
                echo ""
                echo -e "${G}Нажмите Enter...${NC}"
                read
                ;;
            5)
                header
                echo -e "${C}Полное обновление...${NC}"
                echo ""
                python3 "$PROJECT_DIR/src/resolve_all.py" 2>&1 | tail -5
                echo ""
                python3 "$PROJECT_DIR/src/fetch_as_prefixes.py" 2>&1 | tail -5
                echo ""
                generate
                echo ""
                echo -e "${G}Нажмите Enter...${NC}"
                read
                ;;
            0) break ;;
            q) break ;;
            Q) break ;;
        esac
    done
}

# Запуск
main_menu
