# ModemMon для iPhone (iOS)

Нативный SwiftUI-порт **ModemMon 2.6** (Android, `ru.franh.modemmon`) — управление роутером OpenWrt с LTE-модемом (medvemodem) с телефона.

Подключается так же, как Android-версия:

- **ubus JSON-RPC через HTTP** (`http://192.168.2.1/ubus`), логин root → сессия, keepalive
- ставит на роутер **ACL** `/usr/share/rpcd/acl.d/modemmon.json` (как `assets/acl-modemmon.json` в APK)
- терминал через **`/usr/bin/mmterm`** (start/poll/stop, base64 — скрипт перенесён из `assets/mmterm.sh` байт-в-байт)
- модем — через **medvemodem CGI**: `/cgi-bin/modem` (статус, SMS, USSD, AT, бэнды), `/cgi-bin/modem-telemetry`
- WoL через `etherwake`, проверка аплинка `curl --interface wwan0 http://connectivitycheck.gstatic.com/generate_204`
- **безопасный режим**: тот же регэксп опасных команд (reboot / sysupgrade / rm -rf / …), что и в Android

## Экраны (паритет с Android)

| Раздел | Что внутри |
|---|---|
| Обзор модема | оператор, регистрация, LTE/NR RSRP/RSRQ/SINR/RSSI, качество %, график RSRP, трафик, uptime/load/mem/CPU-темп |
| Соты | текущая сота + соседи (EARFCN/PCI/RSRP/RSRQ) |
| Бэнды | supported/active, чекбоксы, лок бэндов |
| SMS · USSD · AT | список/отправка/удаление SMS, USSD-запросы с поллингом ответа, AT-консоль |
| Сеть | интерфейсы (ifup/ifdown/renew), metric/failover, DHCP-аренды, network reload |
| Wi-Fi | радио, точки доступа из uci, клиенты (iwinfo assoclist), скан окружения |
| VPN | WireGuard/AmneziaWG: инстансы, пиры, рукопожатия, трафик, ifup/ifdown |
| Маршруты | ip route |
| Система | CPU/частоты, пакеты (apk/opkg), сервисы init.d, процессы, crontab, бэкапы sysupgrade, быстрые команды, logread, LED, reboot |
| Конфиг UCI | дерево `uci show`, правка опций с commit |
| Терминал | полноценный шелл через mmterm + редактор файлов с .bak-копией |
| Файлы | браузер файловой системы роутера + чтение/запись |
| Wake-on-LAN | etherwake, свои цели, авто-установка etherwake |
| Диагностика | ping с роутера, curl-пробы 204 по интерфейсам |
| LuCI и телеметрия | ссылки в Safari |
| Прочее | профили роутеров (пароли в Keychain), демо-режим, настройка меню, интервал опроса, безопасный режим |

## Структура

```
ModemMon-iOS/
├─ ModemMon.xcodeproj/          # Xcode 16+ (synchronized groups, iOS 16.0+)
├─ Info.plist                   # права локальной сети, ATS local
├─ codemagic.yaml               # сборка без Mac (unsigned / signed)
└─ ModemMon/                    # исходники (подхватываются проектом целиком)
   ├─ App.swift                 # точка входа
   ├─ Models.swift              # модели + свободный JSON-хелпер J
   ├─ Ubus.swift                # ubus JSON-RPC клиент + file exec/read/write/list + HTTP CGI
   ├─ Install.swift             # ACL + mmterm.sh (как в APK)
   ├─ Profiles.swift            # профили, настройки, Keychain
   ├─ RouterService.swift       # вся работа с роутером (exec, сеть, wifi, vpn, uci, файлы, wol)
   ├─ TerminalSession.swift     # сессия mmterm
   ├─ AppState.swift            # поллинг, тренды, аплинк, баннер ошибок
   ├─ DemoSource.swift          # демо-данные
   ├─ Components.swift          # StatTile/Sparkline/SignalBars/…
   ├─ RootView.swift            # меню + навигация
   ├─ ConnectView.swift         # подключение и профили
   ├─ ModemViews.swift          # обзор/соты/бэнды/SMS/USSD/AT
   ├─ NetworkViews.swift        # сеть/wifi/vpn/маршруты
   ├─ SystemViews.swift         # система/UCI
   ├─ MiscViews.swift           # терминал/файлы/WoL/диагностика/настройки
   └─ …
```

## Сборка

### Вариант 1 — Mac с Xcode

1. Открыть `ModemMon.xcodeproj` (нужен Xcode 16 или новее).
2. В настройках таргета выбрать свою **Team** (бесплатный Apple ID подходит).
3. iPhone: Настройки → Основные → VPN и управление устройствами → доверять разработчику.
4. Run — приложение на телефоне. Бесплатная подписка живёт 7 дней, потом пересобрать.

### Вариант 2 — без Mac (Codemagic)

1. Залить папку в git-репозиторий (GitHub/GitLab/Bitbucket).
2. codemagic.io → Add project → этот репо.
3. Workflow **ios-unsigned** — просто соберёт `Payload.zip` (для AltStore/SideStore).
4. Workflow **ios-signed** — подписанная .ipa: в Codemagic подключи Apple Developer Portal Connection (свой Apple ID), team → `appstore_credentials`.

Бесплатный аккаунт Apple: дев-подпись на 7 дней. Для TestFlight/App Store нужен аккаунт разработчика ($99/год).

### Вариант 3 — AltStore/SideStore на своём ПК

Собери `ios-unsigned`, распакуй `Payload.zip` → `ModemMon.app`, переупакуй в ipa и подписывай через AltServer.

## Что может понадобиться подправить

Медвемодем — твой бэкенд, и если имена `op=` в CGI отличаются от того, что я восстановил из APK, правится **всё в одном месте** — `RouterService.swift`:

- `smsList/smsSend/smsDelete` → `?op=sms_list|sms_send|sms_delete`
- `ussdStart/ussdStatus` → `?op=ussd_start|ussd_status`
- `sendAt` → `?op=at&cmd=…`
- `applyBands` → `?op=bands_set&bands=…`
- имена JSON-ключей статуса — в `Models.swift` (`ModemSnapshot(j:)`, ключи уже поддержаны в двух вариантах: `lte_rsrp`/`rsrp` и т.д.)

Первый запуск: iOS спросит разрешение на **локальную сеть** — это обязательно, иначе до `192.168.2.1` не добраться.

## Отчёт о порте

- Вёрстка своя (нативный SwiftUI, тёмная/светлая тема), не пиксель-в-пиксель как Compose.
- Демо-режим позволяет посмотреть все экраны без роутера.
- Строки UI — русские, как просил.
