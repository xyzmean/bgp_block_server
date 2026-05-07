#!/usr/bin/env python3
"""
Генератор BIRD2 конфигурации с агрегацией IP в /24
Включает префиксы из дополнительных AS
"""

from pathlib import Path
import subprocess
import ipaddress
from collections import defaultdict

# Основные сервисы
SERVICES = {
    "meta", "twitter", "discord", "telegram",
    "cloudflare", "hetzner", "ovh", "digitalocean", "cloudfront",
    "youtube", "tiktok", "hdrezka", "google_ai",
    "roblox", "google_meet",
}

# Дополнительные AS
AS_LIST = {
    "AS12876": "scaleway",
    "AS60068": "cdnn",
    "AS20940": "akamai",
    "AS54253": "asu",
}

SUBNETS_DIR = Path("/root/bgp_geo/allow-domains/Subnets/IPv4")
OUTPUT_DIR = Path("/root/bgp_geo")
AS_PREFIXES_DIR = OUTPUT_DIR / "AS_prefixes"

SERVER_AS = 65200
CLIENT_AS = 65433
CLIENT_IP = "5.187.45.110"
SERVER_IP = "78.17.28.39"


def load_routes():
    """Загружает маршруты с агрегацией /32 в /24"""
    routes = set()
    ips_for_aggregation = defaultdict(set)
    stats = defaultdict(int)

    # 1. Основные сервисы
    for service in SERVICES:
        # Подсети
        subnet_file = SUBNETS_DIR / f"{service}.lst"
        if subnet_file.exists():
            with open(subnet_file) as f:
                for line in f:
                    line = line.strip()
                    if line and '/' in line:
                        if line.endswith('/32'):
                            ip = line[:-3]
                            ips_for_aggregation[ip].add(service)
                        else:
                            routes.add(line)
                            stats['service_subnets'] += 1

        # IP от доменов
        ip_file = OUTPUT_DIR / f"ips_{service}.txt"
        if ip_file.exists():
            with open(ip_file) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        ips_for_aggregation[line].add(service)
                        stats['service_ips'] += 1

    # 2. Дополнительные AS
    for as_number, name in AS_LIST.items():
        as_file = AS_PREFIXES_DIR / f"{as_number}.txt"
        if as_file.exists():
            with open(as_file) as f:
                for line in f:
                    line = line.strip()
                    if line and '/' in line:
                        routes.add(line)
                        stats['as_prefixes'] += 1

    # Агрегируем IP в /24
    aggregated = set()
    for ip in ips_for_aggregation.keys():
        try:
            network = ipaddress.IPv4Network(f"{ip}/24", strict=False)
            aggregated.add(str(network))
        except:
            aggregated.add(f"{ip}/32")

    routes.update(aggregated)

    print(f"Статистика источников:")
    print(f"  Сервисы (подсети): {stats['service_subnets']}")
    print(f"  Сервисы (IP): {stats['service_ips']} -> {len(aggregated)} /24")
    print(f"  Доп. AS: {stats['as_prefixes']} префиксов")

    return sorted(routes)


def generate_bird2_config(routes):
    """Генерирует конфиг BIRD2"""

    config = f"""# BIRD2 Configuration - BGP Route Server
# Server AS: {SERVER_AS}
# Server IP: {SERVER_IP}
# Client: {CLIENT_IP} AS {CLIENT_AS}
# Routes: {len(routes)} prefixes
#
# Sources:
#   - Services: meta, twitter, discord, telegram, cloudflare, hetzner, ovh,
#               digitalocean, cloudfront, youtube, tiktok, hdrezka, google_ai
#   - AS: 12876 (Scaleway), 60068 (CDNN), 20940 (Akamai), 54253 (ASU)

router id 192.168.255.1;

protocol device {{
    scan time 10;
}}

protocol direct {{
    interface "lo";
}}

protocol kernel {{
    ipv4 {{
        export none;
    }};
}}

protocol static all_routes {{
    ipv4;
"""

    for route in routes:
        config += f"    route {route} blackhole;\n"

    config += f"""}}

protocol bgp client {{
    local {SERVER_IP} as {SERVER_AS};
    neighbor {CLIENT_IP} as {CLIENT_AS};
    multihop;
    hold time 240;

    ipv4 {{
        import none;
        export all;
    }};
}}
"""

    return config


def main():
    print("Loading routes with AS prefixes...")
    routes = load_routes()
    print(f"Total routes: {len(routes)}")

    config = generate_bird2_config(routes)

    config_file = OUTPUT_DIR / "bird.conf"
    with open(config_file, 'w') as f:
        f.write(config)

    with open(OUTPUT_DIR / "routes.txt", 'w') as f:
        f.write('\n'.join(routes))

    print(f"Config saved to: {config_file}")

    result = subprocess.run(['/usr/sbin/bird', '-p', '-c', str(config_file)],
                           capture_output=True, text=True)
    if result.returncode == 0:
        print("Syntax OK!")

        from collections import Counter
        prefix_lens = Counter(r.split('/')[-1] for r in routes)
        print("\nPrefix distribution:")
        for pl in sorted(prefix_lens.keys()):
            print(f"  /{pl}: {prefix_lens[pl]} routes")
    else:
        print("Syntax errors:")
        print(result.stderr)


if __name__ == "__main__":
    main()
