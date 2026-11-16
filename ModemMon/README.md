# ModemMon iOS

iOS-приложение (SwiftUI) для управления OpenWrt-роутером с LTE-модемом —
порт Android-версии [ModemMon](https://github.com/franhzyz/modemmon-android).

## Требования

Приложение работает только с пакетами из репозитория
[https://github.com/Medvedolog/medvemodem](https://github.com/Medvedolog/medvemodem)
(medvemodem, luci-app-forkop, sing-box-forkop и связанные пакеты).

## Возможности

- Обзор модема: сигнал, антенны, bearer, трафик, телеметрия (schema v2)
- Соты/бэнды, SMS · USSD · AT-команды
- Сеть: интерфейсы, Wi-Fi, маршруты, DHCP
- **Переключение модемов** (основной ↔ резервный) через uci-метрики
- Форкоп: статус, дашборд, тест секций, диагностика, редактор секций и ссылок
- Спидтест (Яндекс.Интернетометр) с роутера по выбранному каналу
- VPN (WireGuard/AmneziaWG), Службы, Конфиг UCI, Терминал, Файлы, Wake-on-LAN, Диагностика

## Сборка

Unsigned-сборка через [Codemagic](https://codemagic.io); установка на iPhone —
через [Sideloadly](https://sideloadly.io).
