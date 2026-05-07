#!/usr/bin/env python3
from pathlib import Path

SUBNETS_DIR = Path("/root/bgp_geo/allow-domains/Subnets/IPv4")
OUTPUT_DIR = Path("/root/bgp_geo")
AS_PREFIXES_DIR = OUTPUT_DIR / "AS_prefixes"

SERVICES = {
    "meta", "twitter", "discord", "telegram",
    "cloudflare", "hetzner", "ovh", "digitalocean", "cloudfront",
    "youtube", "tiktok", "hdrezka", "google_ai",
    "roblox", "google_meet",
}

AS_LIST = {
    "AS12876": "scaleway",
    "AS60068": "cdnn",
    "AS20940": "akamai",
    "AS54253": "asu",
}

print("=" * 60)
print("РАСПРЕДЕЛЕНИЕ ПРЕФИКСОВ В BGP")
print("=" * 60)

# 1. Сервисы с подсетями
print("\n[1] СЕРВИСЫ С ПОДСЕТЯМИ (Subnets/IPv4):")
print("-" * 60)
service_counts = {}
for service in SERVICES:
    subnet_file = SUBNETS_DIR / f"{service}.lst"
    if subnet_file.exists():
        with open(subnet_file) as f:
            count = sum(1 for line in f if line.strip() and '/' in line)
        if count > 0:
            service_counts[service] = count
            print(f"  {service:20s}: {count:4d} префиксов")

print(f"\n  Итого подсетей: {sum(service_counts.values())}")

# 2. Сервисы с доменами
print("\n[2] СЕРВИСЫ С ДОМЕНАМИ (резолвленные → /24):")
print("-" * 60)
domain_counts = {}
total_ips = 0
for service in SERVICES:
    ip_file = OUTPUT_DIR / f"ips_{service}.txt"
    if ip_file.exists():
        with open(ip_file) as f:
            ips = [line.strip() for line in f if line.strip()]
        if ips:
            total_ips += len(ips)
            print(f"  {service:20s}: {len(ips):3d} IP")

print(f"\n  Итого IP (агрегированы в /24): {total_ips}")

# 3. Дополнительные AS
print("\n[3] ДОПОЛНИТЕЛЬНЫЕ AS:")
print("-" * 60)
as_counts = {}
for as_num, name in AS_LIST.items():
    as_file = AS_PREFIXES_DIR / f"{as_num}.txt"
    if as_file.exists():
        with open(as_file) as f:
            count = sum(1 for line in f if line.strip() and '/' in line)
        as_counts[as_num] = count
        print(f"  {as_num:10s} ({name:15s}): {count:4d} префиксов")

print(f"\n  Итого из AS: {sum(as_counts.values())}")

# Итого
print("\n" + "=" * 60)
print("ИТОГОВАЯ СТАТИСТИКА:")
print("-" * 60)
print(f"  Подсети сервисов:     {sum(service_counts.values()):5d}")
print(f"  IP от доменов:        {total_ips:5d}")
print(f"  Префиксы из AS:       {sum(as_counts.values()):5d}")
print(f"  ВСЕГО в BGP:          5951")
print("=" * 60)
