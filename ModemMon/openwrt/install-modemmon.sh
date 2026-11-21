#!/bin/sh
# ModemMon: установка пакетов medvemodem на OpenWrt (24.10 / 25.12)
# + встроенный RNDIS-патч телеметрии (для модемов, которых не видит ModemManager).
# Запускать на самом роутере (SSH): sh install-modemmon.sh
# Пакеты: https://github.com/Medvedolog/medvemodem
set -e

TAG="v0.16.0-alpha1-r1"
VER_PKG="0.16.0-alpha1-r1"
BASE="https://github.com/Medvedolog/medvemodem/releases/download/$TAG"
# Все цели, которые собирает Medvedolog (см. .github/workflows/build.yml):
# aarch64_cortex-a53, aarch64_generic, x86_64 x OpenWrt 24.10.8 / 25.12.6
BUNDLES="aarch64_cortex-a53-24.10.8 aarch64_cortex-a53-25.12.6 aarch64_generic-24.10.8 aarch64_generic-25.12.6 x86_64-24.10.8 x86_64-25.12.6"

. /etc/openwrt_release 2>/dev/null || { echo "Это не OpenWrt?"; exit 1; }
ARCH="$DISTRIB_ARCH"
REL="$DISTRIB_RELEASE"

# Версия OpenWrt -> набор пакетов из релиза
case "$REL" in
    24.10*)  VER="24.10.8" ;;
    25.12*)  VER="25.12.6" ;;
    *) VER="" ;;
esac

# Архитектура должна совпадать с собранными пакетами
case "$ARCH" in
    aarch64_cortex-a53|aarch64_generic|x86_64) ;;
    *) ARCH="" ;;
esac

if [ -z "$VER" ] || [ -z "$ARCH" ]; then
    echo "Для '$REL' / '$ARCH' пакетов нет — автор собирает только под:"
    for b in $BUNDLES; do echo "  medvemodem-$VER_PKG-$b.tar.gz"; done
    echo "Скачай подходящий вручную: $BASE"
    exit 1
fi

TARBALL="medvemodem-$VER_PKG-$ARCH-$VER.tar.gz"
URL="$BASE/$TARBALL"

echo "Архитектура: $ARCH, OpenWrt: $VER"
echo "Скачиваю: $URL"
cd /tmp
if ! (curl -sL "$URL" -o medve.tar.gz 2>/dev/null || uclient-fetch "$URL" -O medve.tar.gz 2>/dev/null || wget -O medve.tar.gz "$URL"); then
    echo "Ошибка скачивания. Проверь связь с github.com"; exit 1
fi

mkdir -p medve
tar -xzf medve.tar.gz -C medve
echo "Устанавливаю пакеты:"
ls medve/*.apk
apk add --allow-untrusted medve/*.apk

rm -rf medve medve.tar.gz

# --- RNDIS-патч телеметрии -----------------------------------------------
# Модемы в RNDIS-режиме (Fibocom FM350-GL и подобные) ModemManager не видит —
# телеметрия получает данные через движок medvemodem (AT-опрос).
# Идемпотентен: повторный запуск ничего не меняет.
T=/usr/bin/modem-telemetry.sh
if [ -f "$T" ] && ! grep -q "RNDIS-fallback" "$T" 2>/dev/null; then
    echo "Применяю RNDIS-патч телеметрии…"
    cp "$T" "$T.bak-rndis"

    # Блок 1: функции движка (id устройства, AT-запрос, парсер температуры)
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

    # Блок 2: вызов температуры через движок вместо прямого AT^TEMP
    awk 'index($0, "run_limited medvemodem at") && index($0, "AT^TEMP?") { print "            at_temperature_output=$(rndis_temp_cmd)"; next } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

    # Блок 3: если PA/Skin/TSENS не сработали — парсим ответ GTSENRDTEMP
    awk 'index($0, "temp_sensor=\"PA\"") && !done { print "            if [ -z \"$temp_c\" ]; then"; print "                temp_c=$(mm_temp_of \"$at_temperature_output\")"; print "                temp_sensor=\"GTSENRDTEMP\""; print "            fi"; done=1 } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

    # Блок 4: сигнал/оператор/регистрация из движка (RNDIS-fallback)
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

    # Блок 5: RNDIS v3 — SIM ICCID/IMSI, IP, MTU, сессия, роуминг, APN, NR NSA
    cat > /tmp/mm_patch_c.txt <<'MMEOF'
    # RNDIS v3: SIM ICCID/IMSI (маскированные), APN, сессия, роуминг/пакетный сервис, NR NSA
    v=$(uf '@.sim.iccid'); if [ -n "$v" ]; then iccid=$v; iccid_masked=$(mask_id "$iccid"); fi
    v=$(uf '@.sim.imsi'); if [ -n "$v" ]; then imsi=$v; imsi_masked=$(mask_id "$imsi"); fi
    v=$(ip -4 addr show eth1 2>/dev/null | grep -oE "inet [0-9./]+" | awk '{print $2}'); if [ -n "$v" ]; then ipv4_address=${v%%/*}; ipv4_prefix=${v#*/}; fi
    v=$(cat /sys/class/net/eth1/mtu 2>/dev/null); [ -n "$v" ] && ipv4_mtu=$v
    v=$(uf '@.session.since'); if [ -n "$v" ]; then connect_time=$((temperature_now - v)); fi
    cgd=$(rndis_at_cmd 'AT+CGDCONT?' 2>/dev/null)
    v=$(printf '%s\n' "$cgd" | grep -oE '"[a-z0-9.\-]+"' | sed -n '2p' | tr -d '"')
    [ -n "$v" ] && apn=$v
    case "$registration" in
        home) roaming=false; packet_service=есть ;;
    esac
    case "$signal_history_json" in *nr-nsa*) nr_nsa=1 ;; esac
MMEOF
    awk -v ins="$(cat /tmp/mm_patch_c.txt)" 'index($0, "modemmanager.sim_card.operator_code") && !done { print ins; done=1 } { print }' "$T" > "$T.new" && mv "$T.new" "$T"

    chmod +x "$T"
    rm -f /tmp/mm_patch_b.txt /tmp/mm_patch_a.txt /tmp/mm_patch_c.txt
    echo "RNDIS-патч применён ✓"
fi

echo ""
echo "Готово. Дальше: LuCI -> Сервисы -> medvemodem."
echo "ModemMon (приложение) подключай к этому роутеру по ubus."
