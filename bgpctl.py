#!/usr/bin/env python3
"""Интерактивный интерфейс управления BGP маршрутами"""

import sys
import subprocess
import json
import re
from pathlib import Path
from collections import defaultdict
import urllib.request
import ipaddress

PROJECT_DIR = Path("/root/bgp_geo")
ALLOW_DOMAINS = PROJECT_DIR / "allow-domains"
SUBNETS_DIR = ALLOW_DOMAINS / "Subnets" / "IPv4"
SERVICES_DIR = ALLOW_DOMAINS / "Services"
AS_PREFIXES_DIR = PROJECT_DIR / "as_prefixes"
CONFIG_FILE = PROJECT_DIR / "config.json"

AS_PREFIXES_DIR.mkdir(exist_ok=True)


class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'


def print_header(text):
    print(f"\n{Colors.HEADER}{Colors.BOLD}{'=' * 60}{Colors.END}")
    print(f"{Colors.HEADER}{Colors.BOLD}{text:^60}{Colors.END}")
    print(f"{Colors.HEADER}{Colors.BOLD}{'=' * 60}{Colors.END}\n")


def print_success(text):
    print(f"{Colors.GREEN}[+]{Colors.END} {text}")


def print_error(text):
    print(f"{Colors.RED}[!]{Colors.END} {text}")


def print_info(text):
    print(f"{Colors.CYAN}[i]{Colors.END} {text}")


def print_warning(text):
    print(f"{Colors.YELLOW}[*]{Colors.END} {text}")


def load_config():
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {"services": [], "as_numbers": {}, "custom_domains": {}, "custom_subnets": {}}


def save_config(config):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)


def get_available_services():
    services = set()
    # Services
    if SERVICES_DIR.exists():
        for f in SERVICES_DIR.glob("*.lst"):
            services.add(f.stem.lower())
    # Subnets/IPv4
    if SUBNETS_DIR.exists():
        for f in SUBNETS_DIR.glob("*.lst"):
            services.add(f.stem.lower())
    # Categories
    categories_dir = ALLOW_DOMAINS / "Categories"
    if categories_dir.exists():
        for f in categories_dir.glob("*.lst"):
            services.add(f.stem.lower())
    # Russia
    services.add("russia_inside")
    services.add("russia_outside")
    # Ukraine
    services.add("ukraine_inside")
    services.add("ukraine_outside")
    return sorted(services)


def fetch_as_prefixes(as_number: str) -> set:
    prefixes = set()
    try:
        as_num = as_number.replace('AS', '').upper()
        url = f"https://stat.ripe.net/data/announced-prefixes/data.json?resource={as_num}"
        response = urllib.request.urlopen(url, timeout=15)
        data = json.loads(response.read())
        if data.get('data') and data['data'].get('prefixes'):
            for p in data['data']['prefixes']:
                prefix = p.get('prefix', '')
                if ':' not in prefix:
                    try:
                        network = ipaddress.ip_network(prefix, strict=False)
                        if network.prefixlen <= 24:
                            prefixes.add(prefix)
                    except:
                        pass
    except Exception as e:
        print_error(f"Ошибка: {e}")
    return prefixes


def resolve_domains(domains: list) -> set:
    ips = set()
    for domain in domains:
        try:
            result = subprocess.run(
                ['dig', '+short', '+time=2', 'A', domain],
                capture_output=True, text=True, timeout=3
            )
            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    line = line.strip()
                    if line and re.match(r'^\d+\.\d+\.\d+\.\d+$', line):
                        ips.add(line)
        except:
            pass
    return ips


def cmd_list(args):
    print_header("СПИСОК СЕРВИСОВ")
    available = get_available_services()
    enabled = load_config().get("services", [])
    as_numbers = load_config().get("as_numbers", {})

    print(f"{Colors.BOLD}Доступные сервисы:{Colors.END}")
    for svc in available:
        status = f"{Colors.GREEN}ON{Colors.END}" if svc in enabled else f"{Colors.RED}OFF{Colors.END}"
        print(f"  [{status}] {svc}")

    print(f"\n{Colors.BOLD}Дополнительные AS:{Colors.END}")
    if as_numbers:
        for as_num, name in as_numbers.items():
            print(f"  {as_num} ({name})")
    else:
        print(f"  {Colors.YELLOW}Нет добавленных AS{Colors.END}")


def cmd_enable(args):
    config = load_config()
    count = 0
    for svc in args:
        svc = svc.lower()
        available = get_available_services()
        if svc in available:
            if svc not in config["services"]:
                config["services"].append(svc)
                print_success(f"'{svc}' включён")
                count += 1
        else:
            print_error(f"'{svc}' не найден")
    if count > 0:
        save_config(config)
        print_warning("Запустите 'bgpctl generate' для применения")


def cmd_disable(args):
    config = load_config()
    count = 0
    for svc in args:
        svc = svc.lower()
        if svc in config["services"]:
            config["services"].remove(svc)
            print_success(f"'{svc}' отключён")
            count += 1
    if count > 0:
        save_config(config)
        print_warning("Запустите 'bgpctl generate' для применения")


def cmd_add_as(args):
    if len(args) < 1:
        print_error("Укажите AS (пример: AS12876)")
        return
    as_number = args[0].upper()
    if not as_number.startswith('AS'):
        as_number = 'AS' + as_number
    name = ' '.join(args[1:]) if len(args) > 1 else as_number

    print_info(f"Добавление {as_number}...")
    prefixes = fetch_as_prefixes(as_number)
    if prefixes:
        with open(AS_PREFIXES_DIR / f"{as_number}.txt", 'w') as f:
            f.write('\n'.join(sorted(prefixes)))
        config = load_config()
        config["as_numbers"][as_number] = name
        save_config(config)
        print_success(f"{as_number}: {len(prefixes)} префиксов")
    else:
        print_error(f"Не удалось получить префиксы")


def cmd_remove_as(args):
    config = load_config()
    for as_num in args:
        as_num = as_num.upper()
        if not as_num.startswith('AS'):
            as_num = 'AS' + as_num
        if as_num in config["as_numbers"]:
            del config["as_numbers"][as_num]
            (AS_PREFIXES_DIR / f"{as_num}.txt").unlink(missing_ok=True)
            print_success(f"{as_num} удалён")
    save_config(config)


def cmd_add_domain(args):
    if len(args) < 1:
        print_error("Укажите домен")
        return
    domain = args[0].lower()
    name = ' '.join(args[1:]) if len(args) > 1 else domain

    print_info(f"Резолвинг {domain}...")
    ips = resolve_domains([domain])
    if ips:
        slash24s = set()
        for ip in ips:
            parts = ip.split('.')
            slash24s.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")
        config = load_config()
        config["custom_domains"][domain] = {"name": name, "ips": list(ips), "slash24s": list(slash24s)}
        save_config(config)
        print_success(f"{domain}: {len(ips)} IP")
    else:
        print_error(f"Не удалось резолвить {domain}")


def cmd_add_subnet(args):
    if len(args) < 1:
        print_error("Укажите подсеть")
        return
    prefix = args[0]
    name = ' '.join(args[1:]) if len(args) > 1 else prefix
    try:
        ipaddress.ip_network(prefix, strict=True)
    except:
        print_error(f"Некорректная подсеть")
        return
    config = load_config()
    config["custom_subnets"][prefix] = name
    save_config(config)
    print_success(f"Подсеть {prefix} добавлена")


def cmd_status(args):
    print_header("СТАТУС BGP")
    config = load_config()
    enabled = config["services"]
    as_nums = config["as_numbers"]

    print(f"{Colors.BOLD}Сервисы ({len(enabled)}):{Colors.END}")
    for svc in enabled[:10]:
        print(f"  • {svc}")
    if len(enabled) > 10:
        print(f"  ... и ещё {len(enabled) - 10}")

    print(f"\n{Colors.BOLD}AS ({len(as_nums)}):{Colors.END}")
    for as_num, name in as_nums.items():
        print(f"  • {as_num} ({name})")

    print(f"\n{Colors.BOLD}Кастомное:{Colors.END}")
    print(f"  Доменов: {len(config['custom_domains'])}")
    print(f"  Подсетей: {len(config['custom_subnets'])}")


def cmd_generate(args):
    print_header("ГЕНЕРАЦИЯ КОНФИГА")
    config = load_config()
    routes = set()

    # От сервисов (Subnets/IPv4 - подсети, Services - домены для резолвинга)
    for svc in config.get("services", []):
        # Subnets/IPv4/*.lst - готовые подсети
        subnet_file = SUBNETS_DIR / f"{svc}.lst"
        if subnet_file.exists():
            with open(subnet_file) as f:
                for line in f:
                    line = line.strip()
                    if line and '/' in line:
                        routes.add(line)

        # Services/*.lst - домены (резолвим в /24)
        service_file = SERVICES_DIR / f"{svc}.lst"
        if service_file.exists():
            domains = [line.strip() for line in open(service_file) if line.strip()]
            ips = resolve_domains(domains)
            for ip in ips:
                parts = ip.split('.')
                routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")

        # Categories/*.lst - домены (резолвим в /24)
        category_file = ALLOW_DOMAINS / "Categories" / f"{svc}.lst"
        if category_file.exists():
            domains = [line.strip() for line in open(category_file) if line.strip()]
            ips = resolve_domains(domains)
            for ip in ips:
                parts = ip.split('.')
                routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")

        # Russia/inside-raw.lst, Russia/outside-raw.lst
        if svc == "russia_inside":
            russia_file = ALLOW_DOMAINS / "Russia" / "inside-raw.lst"
            if russia_file.exists():
                domains = [line.strip() for line in open(russia_file) if line.strip()]
                ips = resolve_domains(domains)
                for ip in ips:
                    parts = ip.split('.')
                    routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")
        elif svc == "russia_outside":
            russia_file = ALLOW_DOMAINS / "Russia" / "outside-raw.lst"
            if russia_file.exists():
                domains = [line.strip() for line in open(russia_file) if line.strip()]
                ips = resolve_domains(domains)
                for ip in ips:
                    parts = ip.split('.')
                    routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")

        # Ukraine/inside-raw.lst, Ukraine/outside-raw.lst
        if svc == "ukraine_inside":
            ukraine_file = ALLOW_DOMAINS / "Ukraine" / "inside-raw.lst"
            if ukraine_file.exists():
                domains = [line.strip() for line in open(ukraine_file) if line.strip()]
                ips = resolve_domains(domains)
                for ip in ips:
                    parts = ip.split('.')
                    routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")
        elif svc == "ukraine_outside":
            ukraine_file = ALLOW_DOMAINS / "Ukraine" / "outside-raw.lst"
            if ukraine_file.exists():
                domains = [line.strip() for line in open(ukraine_file) if line.strip()]
                ips = resolve_domains(domains)
                for ip in ips:
                    parts = ip.split('.')
                    routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")

        # Старый формат ips_*.txt для совместимости
        ip_file = PROJECT_DIR / f"ips_{svc}.txt"
        if ip_file.exists():
            with open(ip_file) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        parts = line.split('.')
                        routes.add(f"{parts[0]}.{parts[1]}.{parts[2]}.0/24")

    # От AS
    for as_num in config.get("as_numbers", {}):
        as_file = AS_PREFIXES_DIR / f"{as_num}.txt"
        if as_file.exists():
            with open(as_file) as f:
                for line in f:
                    routes.add(line.strip())

    # Кастомное
    for subnet in config.get("custom_subnets", {}):
        routes.add(subnet)
    for data in config.get("custom_domains", {}).values():
        for prefix in data.get("slash24s", []):
            routes.add(prefix)

    routes = sorted(routes)

    # Генерируем BIRD конфиг
    routes_block = "\n".join(f"    route {r} blackhole;" for r in routes)
    bird_conf = f"""# BIRD2 - Generated by bgpctl
# Routes: {len(routes)} prefixes

router id 192.168.255.1;

protocol device {{ scan time 10; }}
protocol direct {{ interface "lo"; }}
protocol kernel {{ ipv4 {{ export none; }}; }}

protocol static all_routes {{ ipv4;
{routes_block}
}}

protocol bgp client {{
    local 78.17.28.39 as 65200;
    neighbor 5.187.45.110 as 65433;
    multihop;
    hold time 240;
    ipv4 {{ import none; export all; }};
}}
"""

    with open(PROJECT_DIR / "bird.conf", 'w') as f:
        f.write(bird_conf)
    with open(PROJECT_DIR / "routes.txt", 'w') as f:
        f.write('\n'.join(routes))

    print_success(f"Конфиг: {len(routes)} маршрутов")

    # Применяем
    subprocess.run(['cp', PROJECT_DIR / "bird.conf", "/etc/bird/bird.conf"])
    subprocess.run(['chown', 'root:bird', "/etc/bird/bird.conf"])
    subprocess.run(['chmod', '640', "/etc/bird/bird.conf"])
    subprocess.run(['birdc', 'configure'], capture_output=True)
    print_success("BIRD перезагружен")


def cmd_help(args):
    print_header("BGPCTL - Управление BGP")
    print("""
Команды:
  bgpctl list              - Показать сервисы
  bgpctl enable <svc>      - Включить сервис
  bgpctl disable <svc>     - Отключить сервис
  bgpctl add-as <AS> [имя] - Добавить AS
  bgpctl remove-as <AS>    - Удалить AS
  bgpctl add-domain <домен> - Добавить домен
  bgpctl add-subnet <подсеть> - Добавить подсеть
  bgpctl status            - Статус
  bgpctl generate          - Сгенерировать и применить
""")


def main():
    if len(sys.argv) < 2:
        cmd_help([])
        return

    cmd = sys.argv[1].lower()
    args = sys.argv[2:]

    commands = {
        'list': cmd_list, 'ls': cmd_list,
        'enable': cmd_enable, 'on': cmd_enable,
        'disable': cmd_disable, 'off': cmd_disable,
        'add-as': cmd_add_as,
        'remove-as': cmd_remove_as, 'rm-as': cmd_remove_as,
        'add-domain': cmd_add_domain,
        'add-subnet': cmd_add_subnet,
        'status': cmd_status, 'info': cmd_status,
        'generate': cmd_generate, 'gen': cmd_generate, 'apply': cmd_generate,
        'help': cmd_help, '-h': cmd_help, '--help': cmd_help,
    }

    if cmd in commands:
        commands[cmd](args)
    else:
        print_error(f"Неизвестная команда: {cmd}")


if __name__ == "__main__":
    main()
