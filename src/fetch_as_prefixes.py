#!/usr/bin/env python3
"""
Получает IPv4 префиксы из указанных AS через RIPE stat API
"""

import subprocess
import re
import ipaddress
from pathlib import Path
import json
import urllib.request

CONFIG_FILE = Path("/root/bgp_geo/config.json")
OUTPUT_DIR = Path("/root/bgp_geo")
AS_PREFIXES_DIR = OUTPUT_DIR / "as_prefixes"
AS_PREFIXES_DIR.mkdir(exist_ok=True)


def get_as_list():
    """Читает AS из config.json"""
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            config = json.load(f)
            return config.get("as_numbers", {})
    return {}


def is_valid_ipv4_prefix(prefix: str) -> bool:
    """Проверка валидности IPv4 префикса"""
    try:
        network = ipaddress.ip_network(prefix, strict=False)
        return isinstance(network, ipaddress.IPv4Network) and network.prefixlen <= 24
    except ValueError:
        return False


def fetch_prefixes_ripe_stat(as_number: str) -> set:
    """Получает префиксы через RIPE stat API"""
    prefixes = set()

    try:
        # Убираем 'AS' префикс
        as_num = as_number.replace('AS', '')

        url = f"https://stat.ripe.net/data/announced-prefixes/data.json?resource={as_number}"
        response = urllib.request.urlopen(url, timeout=15)
        data = json.loads(response.read())

        if data.get('data') and data['data'].get('prefixes'):
            for p in data['data']['prefixes']:
                prefix = p.get('prefix', '')
                # Только IPv4
                if ':' not in prefix and is_valid_ipv4_prefix(prefix):
                    prefixes.add(prefix)

    except Exception as e:
        print(f"  RIPE stat ошибка: {e}")

    return prefixes


def fetch_prefixes_routeviews(as_number: str) -> set:
    """Получает префиксы через RouteViews API"""
    prefixes = set()

    try:
        as_num = as_number.replace('AS', '')
        # RouteViews raw data URL
        url = f"http://www.routeviews.org/routeviews/?prefix={as_num}"

        # Альтернативно - используя bgpsummary
        url2 = f"https://api.bgpsummary.com/{as_num}"
        response = urllib.request.urlopen(url2, timeout=10)
        data = json.loads(response.read())

        if data.get('data') and 'prefixes' in data['data']:
            for p in data['data']['prefixes']['ipv4']:
                if is_valid_ipv4_prefix(p):
                    prefixes.add(p)

    except Exception as e:
        pass  # Тихий провал

    return prefixes


def fetch_all_prefixes_for_as(as_number: str, name: str):
    """Получает префиксы из всех источников"""
    print(f"\n[{as_number}] {name}")

    all_prefixes = set()

    # RIPE stat API
    print("  RIPE stat API...", end="", flush=True)
    ripe_prefixes = fetch_prefixes_ripe_stat(as_number)
    print(f" {len(ripe_prefixes)} префиксов")
    all_prefixes.update(ripe_prefixes)

    # RouteViews как backup
    if not all_prefixes:
        print("  RouteViews API...", end="", flush=True)
        rv_prefixes = fetch_prefixes_routeviews(as_number)
        print(f" {len(rv_prefixes)} префиксов")
        all_prefixes.update(rv_prefixes)

    # Агрегируем в /24 где возможно
    aggregated = set()
    for prefix in all_prefixes:
        try:
            network = ipaddress.ip_network(prefix, strict=False)
            if network.prefixlen > 24:
                # Агрегируем в /24
                aggregated.add(str(ipaddress.IPv4Network(f"{network.network_address}/24", strict=False)))
            else:
                aggregated.add(prefix)
        except:
            aggregated.add(prefix)

    # Сохраняем
    if aggregated:
        output_file = AS_PREFIXES_DIR / f"{as_number}.txt"
        with open(output_file, 'w') as f:
            for prefix in sorted(aggregated):
                f.write(f"{prefix}\n")
        print(f"  Сохранено: {output_file} ({len(aggregated)} префиксов)")
    else:
        print(f"  ПРЕДУПРЕЖДЕНИЕ: Не найдено префиксов для {as_number}")

    return len(aggregated)


def main():
    print("=" * 60)
    print("Получение префиксов из указанных AS")
    print("=" * 60)

    as_list = get_as_list()
    if not as_list:
        print("No AS numbers found in config.json")
        return

    print(f"Found {len(as_list)} AS\n")

    total = 0
    results = {}

    for as_number, name in as_list.items():
        count = fetch_all_prefixes_for_as(as_number, name)
        results[as_number] = count
        total += count

    print("\n" + "=" * 60)
    print("Итого по AS:")
    for as_num, count in results.items():
        print(f"  {as_num}: {count} префиксов")
    print(f"\nВсего: {total} префиксов")
    print("=" * 60)


if __name__ == "__main__":
    main()
