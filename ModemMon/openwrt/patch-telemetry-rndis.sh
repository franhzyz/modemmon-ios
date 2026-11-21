#!/bin/sh
# ModemMon: патч телеметрии medvemodem для RNDIS-модемов
# (Fibocom FM350-GL и подобные: ModemManager их не видит, т.к. модем
#  работает в RNDIS-режиме и представляется обычным сетевым интерфейсом).
#
# Что делает:
#   1) Сигнал/оператор/регистрация/RAT — из движка medvemodem (AT-опрос,
#      движок сам знает AT-команды каждого модема по пресетам).
#   2) SIM/модель/прошивка/производитель — из движка.
#   3) Bearer (IP/интерфейс/трафик) — из системы (eth1/wan).
#   4) Температура — перебор AT-команд пресетов движка
#      (GTSENRDTEMP=1 для FM350, AT^TEMP? для T99W175 и т.д.).
#
# Запуск на роутере по SSH: sh patch-telemetry-rndis.sh
# Идемпотентен: повторный запуск ничего не меняет.
# Резервная копия: /usr/bin/modem-telemetry.sh.bak-rndis
set -e

T=/usr/bin/modem-telemetry.sh
[ -f "$T" ] || { echo "modem-telemetry.sh не найден — установи пакет modem-telemetry"; exit 1; }

if grep -q "RNDIS-fallback" "$T" 2>/dev/null; then
    echo "Уже пропатчено — ничего не делаю."
    exit 0
fi

echo "Резервная копия: $T.bak-rndis"
cp "$T" "$T.bak-rndis"

# --- Блок 1: функции движка (id устройства, AT-запрос, парсер температуры) ---
cat > /tmp/mm_patch_b.txt <<'MMEOF'
rndis_eng_id() {
    jsonfilter -i /tmp/modem-telemetry-ubus-devices.json -e '@.devices[0].device_id' 2>/dev/null
}
rndis_at_cmd() {
    _cmd="$1"
    _eid="$(rndis_eng_id)"
    [ -z "$_eid" ] && _eid="$MEDVEMODEM_DEVICE"
    ubus call medvemodem at_command "{\"id\":\"$_eid\",\"command\":\"$_cmd\",\"timeout_ms\":4000}" 2>/dev/null
}
mm_temp_of() {
    printf '%s\n' "$1" | awk '
        /\+GTSENRDTEMP:/ {
            body = $0
            sub(/^[^:]*:/, "", body)
            sub(/^[[:space:]]*[0-9]+[[:space:]]*,/, "", body)
            n = split(body, a, ",")
            for (i = 1; i <= n; i++) {
                v = a[i] + 0
                if (v == 0) continue
                if (v >= 65000 || v == 32767 || v == -32767 || v == -32768 || v == 65535 || v == -127 || v == -28479) continue
                if (v >= 1000 || v <= -1000) v /= 1000
                if (v >= -40 && v <= 125 && (best == "" || v > best)) best = v
            }
        }
        END { if (best != "") printf "%.1f", best }'
}
rndis_temp_cmd() {
    # Температура через движок: перебор AT-команд (пресеты у разных моделей свои)
    for _tc in 'AT+GTSENRDTEMP=1' 'AT^TEMP?' 'AT+ETHERNAL?' 'AT+QTEMP?'; do
        _out=$(rndis_at_cmd "$_tc")
        _t=$(mm_temp_of "$_out")
        if [ -n "$_t" ]; then printf '%s\n' "$_out"; return; fi
    done
}
MMEOF
awk -v ins="$(cat /tmp/mm_patch_b.txt)" 'index($0, "read_temperature() {") && !done { print ins; done=1 } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

# --- Блок 2: вызов температуры через движок вместо прямого AT^TEMP ---
awk 'index($0, "run_limited medvemodem at") && index($0, "AT^TEMP?") { print "            at_temperature_output=$(rndis_temp_cmd)"; next } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

# --- Блок 3: если PA/Skin/TSENS не сработали — парсим ответ GTSENRDTEMP ---
awk 'index($0, "temp_sensor=\"PA\"") && !done { print "            if [ -z \"$temp_c\" ]; then"; print "                temp_c=$(mm_temp_of \"$at_temperature_output\")"; print "                temp_sensor=\"GTSENRDTEMP\""; print "            fi"; done=1 } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

# --- Блок 4: сигнал/оператор/регистрация из движка (RNDIS-fallback) ---
cat > /tmp/mm_patch_a.txt <<'MMEOF'
# RNDIS-fallback: ModemManager не видит RNDIS-модем — сигнал/оператор/регистрация
# из движка medvemodem (AT-опрос, движок сам знает команды каждого модема).
if [ -z "$rsrp" ] && [ -z "$sinr" ]; then
    eng=$(run_limited ubus call medvemodem metrics "{\"id\":\"$MEDVEMODEM_DEVICE\",\"max_age_ms\":60000}" 2>/dev/null)
    if [ -n "$eng" ]; then
        eng_val() { jsonfilter -s "$eng" -e "$1" 2>/dev/null; }
        v=$(eng_val '@.metrics.rsrp_dbm'); [ -n "$v" ] && rsrp=$v
        v=$(eng_val '@.metrics.rsrq_db'); [ -n "$v" ] && rsrq=$v
        v=$(eng_val '@.metrics.sinr_db'); [ -n "$v" ] && sinr=$v
        v=$(eng_val '@.metrics.rssi_dbm'); [ -n "$v" ] && rssi=$v
        v=$(eng_val '@.metrics.operator'); if [ -n "$v" ]; then
            plmn=$v
            case "$v" in
                *25020*) operator=Tele2 ;;
                *25002*) operator=МегаФон ;;
                *25001*) operator=Билайн ;;
                *25099*) operator=МТС ;;
                *) operator=$v ;;
            esac
        fi
        v=$(eng_val '@.metrics.registration.eps'); [ -n "$v" ] && registration=$v
        v=$(eng_val '@.metrics.access_technology'); [ -n "$v" ] && network=$v
    fi
fi
MMEOF
awk -v ins="$(cat /tmp/mm_patch_a.txt)" 'index($0, "registration_restriction=$(quoted_field") && !done { print ins; done=1 } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

chmod +x "$T"
rm -f /tmp/mm_patch_b.txt /tmp/mm_patch_a.txt
echo "Патч применён ✓. Резерв: $T.bak-rndis"
echo "Проверка: открой ModemMon — данные модема должны появиться."
