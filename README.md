# BGP Block Server

BGP-сервер для выборочного анонса маршрутов популярных сервисов и CDN через BIRD2. Позволяет управлять списками IP-адресов из нескольких источников (домены, AS-префиксы, кастомные подсети) и генерировать конфигурацию BIRD для blackhole-маршрутизации.

## Возможности

- Управление сервисами через CLI или интерактивное меню
- Резолвинг доменов в /24 подсети
- Получение префиксов автономных систем через RIPE API
- Добавление произвольных подсетей и доменов
- Автоматическое обновление маршрутов по cron
- Генерация и применение конфигурации BIRD2

## Установка

```bash
git clone git@github.com:xyzmean/bgp_block_server.git
cd bgp_block_server

# Получить списки доменов/подсетей
git clone https://github.com/itdoginfo/allow-domains.git allow-domains

# Сделать скрипты исполняемыми
chmod +x bgpctl.py bgpctl.sh src/*.sh

# (Опционально) Создать символические ссылки для удобства
ln -sf $(pwd)/bgpctl.py /usr/local/bin/bgpctl
ln -sf $(pwd)/bgpctl.sh /usr/local/bin/bgp-menu
```

### Зависимости

- Python 3.6+
- BIRD2 (`bird`, `birdc`)
- `dig` (из пакета `dnsutils` / `bind-utils`)

## Использование

### CLI (`bgpctl.py`)

```bash
bgpctl list                          # Показать все сервисы и их статус
bgpctl enable meta twitter discord   # Включить сервисы
bgpctl disable roblox                # Отключить сервис
bgpctl add-as AS15169 google         # Добавить AS и загрузить префиксы
bgpctl remove-as AS15169             # Удалить AS
bgpctl add-domain example.com        # Добавить домен (резолвится в /24)
bgpctl add-subnet 1.1.1.0/24         # Добавить произвольную подсеть
bgpctl status                        # Текущая конфигурация
bgpctl generate                      # Сгенерировать конфиг BIRD и применить
```

### Интерактивное меню (`bgpctl.sh`)

```bash
bgpctl.sh    # Запуск TUI-меню
```

### Автообновление

Добавьте в crontab для автоматического обновления маршрутов каждые 6 часов:

```
0 */6 * * * /root/bgp_geo/src/auto_update.sh
```

## Структура проекта

```
bgp_block_server/
├── bgpctl.py              # Основной CLI-инструмент
├── bgpctl.sh              # Интерактивное bash-меню
├── src/
│   ├── auto_update.sh     # Скрипт автообновления (для cron)
│   ├── resolve_all.py     # Резолвинг доменов
│   ├── fetch_as_prefixes.py # Загрузка AS-префиксов из RIPE
│   ├── generate_bird2_config.py # Генерация конфига BIRD2
│   └── analyze_routes.py  # Анализ маршрутов
├── allow-domains/         # Списки доменов и подсетей (внешний репозиторий)
├── as_prefixes/           # Загруженные AS-префиксы (генерируется)
└── config.json            # Локальная конфигурация (генерируется)
```

## Как это работает

1. **Сбор данных** — IP-адреса собираются из доменов (`allow-domains/Services/`), подсетей (`allow-domains/Subnets/`), AS-префиксов (RIPE API) и пользовательских записей
2. **Резолвинг** — домены резолвятся через `dig`, IP агрегируются в /24 префиксы
3. **Генерация** — создаётся `bird.conf` со static-маршрутами (blackhole)
4. **Применение** — конфиг копируется в `/etc/bird/bird.conf` и BIRD перезагружается

## Лицензия

MIT
