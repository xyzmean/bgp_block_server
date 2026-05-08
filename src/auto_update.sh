#!/bin/bash
#
# BGP Routes Auto-Update Script
# Добавьте в cron: 0 */6 * * * /root/bgp_geo/auto_update.sh
#

set -e

SCRIPT_DIR="/root/bgp_geo"
LOG_FILE="/var/log/bgp_update.log"
LOCK_FILE="/var/run/bgp_update.lock"
MAX_LOCK_AGE=3600

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Проверка блокировки
if [ -f "$LOCK_FILE" ]; then
    LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    CURRENT_TIME=$(date +%s)
    AGE=$((CURRENT_TIME - LOCK_TIME))

    if [ $AGE -lt $MAX_LOCK_AGE ]; then
        log "Уже запущен (lock file age: ${AGE}s)"
        exit 1
    else
        rm -f "$LOCK_FILE"
    fi
fi

touch "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

log "=== Начало обновления BGP маршрутов ==="

cd "$SCRIPT_DIR"

# 1. Резолвинг доменов
log "[1/5] Резолвинг доменов..."
if python3 resolve_all.py >> "$LOG_FILE" 2>&1; then
    DOMAINS_OK="OK"
else
    log "ОШИБКА при резолвинге доменов"
    DOMAINS_OK="FAIL"
fi

# 2. Получение префиксов из AS
log "[2/5] Получение префиксов из AS (12876, 60068, 20940, 54253)..."
if python3 fetch_as_prefixes.py >> "$LOG_FILE" 2>&1; then
    AS_OK="OK"
else
    log "ОШИБКА при получении AS префиксов"
    AS_OK="FAIL"
fi

# 3. Генерация конфига
log "[3/5] Генерация конфига..."
if python3 generate_bird2_config.py >> "$LOG_FILE" 2>&1; then
    NEW_ROUTES=$(python3 -c "print(len(open('routes.txt').readlines()))" 2>/dev/null || echo "?")
    CONFIG_OK="OK (${NEW_ROUTES} routes)"
else
    log "ОШИБКА при генерации конфига"
    CONFIG_OK="FAIL"
    exit 1
fi

# 4. Проверка изменений
OLD_ROUTES=$(birdc "show route count" 2>/dev/null | grep "of.*routes" | head -1 | awk '{print $1}' || echo "0")

if [ "$NEW_ROUTES" = "$OLD_ROUTES" ]; then
    log "[4/5] Изменений нет ($OLD_ROUTES -> $NEW_ROUTES)"
    log "=== Обновление завершено (изменений нет) ==="
    exit 0
fi

log "[4/5] Маршруты изменились: $OLD_ROUTES -> $NEW_ROUTES"

# 5. Применение
log "[5/5] Применение конфига..."
cp bird.conf /etc/bird/bird.conf
chown root:bird /etc/bird/bird.conf
chmod 640 /etc/bird/bird.conf

if birdc "configure" >> "$LOG_FILE" 2>&1; then
    sleep 2
    ACTUAL_ROUTES=$(birdc "show route count" 2>/dev/null | grep "of.*routes" | head -1 | awk '{print $1}' || echo "?")
    BGP_STATE=$(birdc "show protocols" 2>/dev/null | grep client | awk '{print $4}')

    log "Успешно! Маршрутов: $ACTUAL_ROUTES, BGP: $BGP_STATE"
    log "=== Обновление завершено ==="
else
    log "ОШИБКА при применении конфига!"
    exit 1
fi
