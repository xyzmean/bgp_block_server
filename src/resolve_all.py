#!/usr/bin/env python3
"""
Резолвит домены всех сервисов в IP и сохраняет по категориям
"""

from pathlib import Path
import subprocess
import socket
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import json

CONFIG_FILE = Path("/root/bgp_geo/config.json")
ALLOW_DOMAINS = Path("/root/bgp_geo/allow-domains")
SERVICES_DIR = ALLOW_DOMAINS / "Services"
SUBNETS_DIR = ALLOW_DOMAINS / "Subnets" / "IPv4"
CATEGORIES_DIR = ALLOW_DOMAINS / "Categories"
OUTPUT_DIR = Path("/root/bgp_geo")

DNS_CACHE = {}


def get_enabled_services():
    """Читает включенные сервисы из config.json"""
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            config = json.load(f)
            return set(config.get("services", []))
    return set()


def is_domain_service(service: str) -> bool:
    """Проверяет, является сервис доменным (Services/ или Categories/)"""
    return (SERVICES_DIR / f"{service}.lst").exists() or (CATEGORIES_DIR / f"{service}.lst").exists()


def load_domains(service: str) -> list:
    """Загружает домены из Services или Categories"""
    # Проверяем Services
    filepath = SERVICES_DIR / f"{service}.lst"
    if not filepath.exists():
        # Проверяем Categories
        filepath = CATEGORIES_DIR / f"{service}.lst"
    if not filepath.exists():
        return []

    domains = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                domains.append(line)
    return domains


def is_valid_ipv4(ip: str) -> bool:
    try:
        parts = ip.split('.')
        return len(parts) == 4 and all(0 <= int(p) <= 255 for p in parts)
    except:
        return False


def resolve_domain(domain: str) -> set:
    """Резолвит домен в IPv4"""
    if domain in DNS_CACHE:
        return DNS_CACHE[domain]

    ips = set()
    try:
        result = subprocess.run(
            ['dig', '+short', '+time=1', '+tries=1', 'A', domain],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                if line and is_valid_ipv4(line):
                    ips.add(line)
    except:
        pass

    DNS_CACHE[domain] = ips
    return ips


def process_service(service: str):
    """Обрабатывает один сервис"""
    print(f"\n[{service.upper()}]")

    # 1. Подсети
    subnet_file = SUBNETS_DIR / f"{service}.lst"
    subnet_count = 0
    if subnet_file.exists():
        with open(subnet_file) as f:
            subnet_count = sum(1 for line in f if line.strip() and '/' in line)
        print(f"  Subnets: {subnet_count} prefixes")

    # 2. Домены -> IP
    domains = load_domains(service)
    if not domains:
        print(f"  Domains: none")
        return service, subnet_count, 0

    print(f"  Resolving {len(domains)} domains...", end="", flush=True)

    all_ips = set()
    with ThreadPoolExecutor(max_workers=30) as executor:
        futures = {executor.submit(resolve_domain, d): d for d in domains}
        for i, future in enumerate(as_completed(futures)):
            all_ips.update(future.result())
            if (i + 1) % 20 == 0:
                print(f" {i+1}", end="", flush=True)

    print(f" done! {len(all_ips)} unique IPs")

    # Сохраняем IP
    ip_file = OUTPUT_DIR / f"ips_{service}.txt"
    with open(ip_file, 'w') as f:
        f.write('\n'.join(sorted(all_ips)))

    return service, subnet_count, len(all_ips)


def main():
    print("=" * 60)
    print("Resolving all service domains to IPs")
    print("=" * 60)

    services = get_enabled_services()
    if not services:
        print("No enabled services found in config.json")
        return

    print(f"Found {len(services)} enabled services\n")

    results = []
    start = time.time()

    for service in sorted(services):
        result = process_service(service)
        results.append(result)

    elapsed = time.time() - start

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"Time: {elapsed:.1f} seconds\n")

    total_subnets = 0
    total_ips = 0

    for service, subnets, ips in sorted(results, key=lambda x: x[1] + x[2], reverse=True):
        total_subnets += subnets
        total_ips += ips
        total = subnets + ips
        print(f"  {service:15s}: {total:5d} routes ({subnets} subnets + {ips} IPs)")

    print(f"\n  {'TOTAL':15s}: {total_subnets + total_ips:5d} routes")


if __name__ == "__main__":
    main()
