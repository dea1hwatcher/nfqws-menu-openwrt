# NFQWS-MENU (OpenWrt)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Интерактивное меню установки и управления пакетами **nfqws-keenetic**, **nfqws2-keenetic** и **nfqws-keenetic-web** для роутеров на **OpenWrt** (нативно, opkg и apk).

Это форк [**rndnaame/nfqws-menu**](https://github.com/rndnaame/nfqws-menu), адаптированный исключительно под чистый OpenWrt: автоматическое определение архитектуры, нативные фиды пакетов nfqws, procd-сервисы, DNS/hosts через UCI и dnsmasq, поддержка apk (OpenWrt 25.x).

Репозиторий также служит хранилищем готовых **стратегий** обхода DPI, **blobs** и **lists**.

- Скрипт: [`nfqws-menu.sh`](nfqws-menu.sh) (текущая версия **0.1.9**)
- Стратегии: [`strategies/`](strategies/)
- Hosts: [`hosts`](hosts)
- Контрольные суммы: [`SHA256SUMS`](SHA256SUMS), [`strategies/blobs/SHA256SUMS`](strategies/blobs/SHA256SUMS)

### Официальные проекты

| Пакет | Репозиторий |
| --- | --- |
| nfqws-keenetic (v1) | https://github.com/nfqws/nfqws-keenetic |
| nfqws2-keenetic (v2) | https://github.com/nfqws/nfqws2-keenetic |
| Веб-интерфейс | https://github.com/nfqws/nfqws-keenetic-web |

### Источник стратегий

Стратегии в этом репозитории сделаны на базе проекта\
[**Flowseal/zapret-discord-youtube**](https://github.com/Flowseal/zapret-discord-youtube)\
и адаптированы под формат конфигов `nfqws-keenetic` / `nfqws2-keenetic`.

Подготовлены пользователем [**@Nare51**](https://github.com/Nare51) с использованием искусственного интеллекта.

---

## Быстрый старт

SSH на роутер (логин `root`).

> **Рекомендуется jsDelivr** — `raw.githubusercontent.com` у части провайдеров отвечает **404** (DPI), хотя файл в репозитории есть.

### Установка через jsDelivr (предпочтительно)

```bash
opkg update && opkg install curl wget-ssl
wget -O /usr/bin/nfqws-menu.sh https://cdn.jsdelivr.net/gh/Dea1hwa1cher/nfqws-menu-openwrt@main/nfqws-menu.sh && chmod +x /usr/bin/nfqws-menu.sh && sh /usr/bin/nfqws-menu.sh
```

или curl:

```bash
curl -fsSL -o /usr/bin/nfqws-menu.sh https://cdn.jsdelivr.net/gh/Dea1hwa1cher/nfqws-menu-openwrt@main/nfqws-menu.sh && chmod +x /usr/bin/nfqws-menu.sh && sh /usr/bin/nfqws-menu.sh
```

Запасное зеркало (Fastly):

```bash
wget -O /usr/bin/nfqws-menu.sh https://fastly.jsdelivr.net/gh/Dea1hwa1cher/nfqws-menu-openwrt@main/nfqws-menu.sh && chmod +x /usr/bin/nfqws-menu.sh && sh /usr/bin/nfqws-menu.sh
```

### Установка с GitHub raw (если не режется)

```bash
wget -O /usr/bin/nfqws-menu.sh https://raw.githubusercontent.com/Dea1hwa1cher/nfqws-menu-openwrt/main/nfqws-menu.sh && chmod +x /usr/bin/nfqws-menu.sh && sh /usr/bin/nfqws-menu.sh
```

или ghproxy:

```bash
wget -O /usr/bin/nfqws-menu.sh https://ghproxy.net/https://raw.githubusercontent.com/Dea1hwa1cher/nfqws-menu-openwrt/main/nfqws-menu.sh && chmod +x /usr/bin/nfqws-menu.sh && sh /usr/bin/nfqws-menu.sh
```

На OpenWrt 25.x+ с `apk` вместо `opkg install` используется `apk add curl wget-ssl` (или curl / wget из базы). После первого запуска создаётся symlink для быстрого старта:

```bash
menu        # /usr/bin/menu → /usr/bin/nfqws-menu.sh
```

---

## Особенности на OpenWrt

Скрипт определяет ОС автоматически (OpenWrt / ImmortalWrt) и настраивает пути, пакетные фиды и сервисы:

| Параметр | Реализация на OpenWrt |
| --- | --- |
| Конфиги | `/etc/nfqws/nfqws.conf`, `/etc/nfqws2/nfqws2.conf` |
| Сервисы | `/etc/init.d/nfqws-keenetic`, `/etc/init.d/nfqws2-keenetic` (procd) |
| Пакетный менеджер | `opkg` (OpenWrt ≤24.10) или `apk` (25.x+) — определяется автоматически |
| Фид пакетов | `https://nfqws.github.io/nfqws-keenetic/openwrt` (+ GPG-ключ: `.pub` через `opkg-key add` / `.pem` в `/etc/apk/keys`) |
| Symlink меню | `/usr/bin/menu` → `/usr/bin/nfqws-menu.sh` |
| Веб-интерфейс | Нативно из фида `https://nfqws.github.io/nfqws-keenetic-web/openwrt` |
| Hosts (п. 7) | Блок с маркерами `# >>> nfqws-menu hosts >>>` в `/etc/hosts` + reload dnsmasq |
| DoH (п. 8) | Пакет `https-dns-proxy` (uci) + dnsmasq per-domain (DoH) |

Стратегии в репозитории сконфигурированы под нативные пути OpenWrt (`/etc/nfqws*`, `/var/log*`).

Сторонние утилиты на OpenWrt:

| Утилита | OpenWrt |
| --- | --- |
| 10. dpi-detector | ставится нативно (бинарь в `/usr/bin`) |
| 11. awg-openwrt | AmneziaWG 3.1 (ядро `kmod-amneziawg`, утилиты `amneziawg-tools`, LuCI `luci-proto-amneziawg`) |
| 12. MagiTrickle | нативный пакет (opkg/apk-фид, сервис `/etc/init.d/magitrickle`) |
| 13. luci-app-telemt | нативный пакет MTProxy + веб-интерфейс LuCI (`luci-app-telemt` + `telemt`) |
| 14. tg-ws-proxy-rs | нативная ветка установщика (LuCI, `/usr/bin`, `/etc/init.d/tg-ws-proxy-rs`) |

Проверено на реальном устройстве: Xiaomi Mi Router R3, OpenWrt 24.10.1 (mipsel_24kc, fw4).

---

## Что делает меню

При запуске скрипт:

1. Определяет ОС (`/etc/openwrt_release` → `/etc/os-release` → `uci`) и архитектуру: **`opkg print-architecture`** / **`apk --print-arch`** → при ошибке **opkg.conf** → fallback `uname -m`.
2. Заголовок: **Модель / Title / ARCH** — из `/tmp/sysinfo/model` и `/etc/openwrt_release`. ARCH зелёный (из opkg/openwrt_release) или жёлтый (из conf/uname). Предупреждение, если нет модулей NFQUEUE: `kmod-nft-queue` (fw4) / `kmod-ipt-nfqueue` (fw3).
3. Показывает **только установленные** компоненты (версии и статус) одним проходом awk по status/process-кэшу:
   - пакеты NFQWS / web, **awg-openwrt**, **tg-ws-proxy-rs**, magitrickle, **luci-app-telemt** / telemt;
   - dpi-detector, cron, dropbear;
   - **⚡** — сервис запущен; **⭡** — доступна более новая версия (фоновая проверка, **TTL 10 мин**, перерисовка меню без Enter).
4. Интерфейс **RU / EN** (пункт **77**): подписи меню и общие промпты (`Your choice [0]:` / `Ваш выбор [0]:`). Подпись `Language: RU|EN` всегда латиницей.
5. Предлагает меню:

```
[::]  КОМПОНЕНТЫ
      1.  Установка NFQWS / NFQWS2

[::]  СТРАТЕГИИ / СПИСКИ
      2.  Выбор стратегии
      3.  Обновить IPSet List
      4.  Загрузить rkn.list (125k+ доменов)
      5.  Обход блокировки DoT/DoH
      6.  Смена активных fake:blob
      7.  Обновление hosts
      8.  Управление DoT/DoH

[::]  УТИЛИТЫ
      10. dpi-detector
      11. awg-openwrt (AmneziaWG)
      12. MagiTrickle
      13. luci-app-telemt (MTProxy)
      14. TG WS Proxy Rust

[::]  СЕРВИС [S]  |  Language: RU|EN [77]
      88. Удаление пакетов
      99. Обновить скрипт
      00. Выход
```

Горячие клавиши: **S** — сервисные утилиты (UPX, upgrade пакетов); **U** — обновление всех пакетов; **77** — смена языка RU↔EN.

Пример блока статуса:

```
Установленные компоненты:
  nfqws2-keenetic        1.3.1 ⚡
  nfqws-keenetic-web     3.0.24 ⚡
  tg-ws-proxy-rs         2.x ⚡
  dpi-detector           …
  ⭡ - доступна более новая версия
```

### 1. Установка NFQWS / NFQWS2

Подменю:

```
1) nfqws-keenetic
2) nfqws2-keenetic
3) nfqws-keenetic-web
0) Назад
```

- **1–2** — зависимости (`ca-certificates`, `wget-ssl`), официальный репозиторий и установка пакета: нативный фид `https://nfqws.github.io/<repo>/openwrt` с GPG-ключом (opkg: `opkg-key add` .pub; apk: .pem в `/etc/apk/keys`). При v2, если стоит v1 — предложение удалить старый пакет. После установки — предложение поставить веб.
- **3** — веб-интерфейс (lighttpd + PHP, порт **90**): `http://<IP-роутера>:90`. Ставится из нативного фида; логин/пароль — учётные данные root роутера (отключается в `/etc/nfqws_web.conf`: `enabled = false`).

> Фикс TLS reasm с **NFQWS2 ≥ 1.3.1** входит в официальный пакет.

### 2. Выбор стратегии

- Если ни одна версия NFQWS не установлена — предлагает установить.
- Показывает список `.conf` из:
  - `strategies/nfqws1/` — для v1
  - `strategies/nfqws2/` — для v2
- Список стратегий: **`SHA256SUMS`** → GitHub API → **локальный offline-кэш** (`/etc/nfqws-menu/strategies/…`).
- Скачивание: основной raw GitHub → зеркала **jsDelivr / Fastly jsDelivr / ghproxy** → fallback через туннель-интерфейсы (`awg0`, `t2s0`, …); успешный файл сохраняется в offline-кэш.
- Делает **бэкап** текущего конфига и применяет стратегию.
- Перед записью **нормализует CRLF → LF** (иначе `source`/iptables: `: not found`, `invalid port/service`).
- На OpenWrt пути blob/list-файлов в стратегии автоматически переписываются под `/etc/nfqws*`.
- **Пункт 99** — восстановление из backup: `.bak.*` от свежего к старому (самый свежий выделен), рядом имя стратегии из `general (…)`; `fix_isp_interface`, перезапуск сервиса.
- После применения выполняет пост-настройку:

#### ISP_INTERFACE / IPV6_ENABLED

- Определяет интерфейс провайдера из default route (`ip route` / `route`), сравнивает с `ISP_INTERFACE` в конфиге и при необходимости предлагает установить правильное значение. При чтении значения снимаются `\r`, кавычки и пробелы (защита от CRLF в выводе меню).
- Проверяет наличие **глобального IPv6** (`scope global`: 2a00, 2a02, 2606, 2001, …) на выбранном `ISP_INTERFACE` (или default route) и выставляет `IPV6_ENABLED=0|1`. Несколько iface через пробел — достаточно одного с global.

#### Восстановление rkn.list

- Если до смены стратегии в `MODE_LIST` уже был `--hostlist=…/rkn.list`, привязка **восстанавливается** автоматически.

#### Проверка blobs (наличие + SHA256)

Парсит установленный конфиг и находит используемые `.bin` (`--blob=…`, `--dpi-desync-fake-tls=…`, `--dpi-desync-fake-quic=…` и абсолютные пути).

- Сверяет локальные файлы с эталоном [`strategies/blobs/SHA256SUMS`](strategies/blobs/SHA256SUMS) (`sha256sum` или `openssl dgst -sha256`; кэш SUMS ~1 ч).
- Отсутствующие или **устаревшие/повреждённые** (хеш не совпал) предлагает скачать заново; после загрузки — повторная проверка SHA256 (при несовпадении файл удаляется).

#### Обновление lists

По запросу обновляет из `strategies/lists/`: `user.list`, `exclude.list`, `ipset.list`, `ipset_exclude.list`.  
`auto.list` **не трогается** — его заполняет демон.

После всех шагов соответствующий сервис перезапускается.

### 3. Обновление IPSet List

Скачивает актуальный IP/CIDR-список из\
[Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)\
и записывает в `ipset.list`:

| Версия | Путь |
| --- | --- |
| nfqws-keenetic (v1) | `/etc/nfqws/ipset.list` |
| nfqws2-keenetic (v2) | `/etc/nfqws2/lists/ipset.list` |

Бэкап, очистка пустых строк/комментариев, перезапуск сервиса. При двух установленных версиях — можно обновить обе.

### 4. Загрузить rkn.list (125k+ доменов)

Доступно при установленном **nfqws-keenetic** (v1) и/или **nfqws2-keenetic** (v2). При обеих версиях — выбор: 1 / 2 / обе.

- Если `rkn.list` уже есть — показывает размер в **КБ** (без медленного подсчёта 125k строк) и спрашивает, обновлять ли список (**по умолчанию: Нет**). При отказе скачивание пропускается.
- Скачивает большой список доменов РКН из [IndeecFOX/zapret4rocket](https://github.com/IndeecFOX/zapret4rocket)\
  (`extra_strats/TCP/RKN/List.txt`). Сначала **GitHub raw**, затем jsDelivr / Fastly / ghproxy; при недоступности — зеркало `mizulina.shit.vc`.
- Записывает: v1 → `/etc/nfqws/rkn.list`, v2 → `/etc/nfqws2/lists/rkn.list`.
- Добавляет `--hostlist=…/rkn.list` в `MODE_LIST` соответствующего конфига (с бэкапом), если его ещё нет. Вставка через **awk** (устойчиво к CRLF, пробелам, пустым кавычкам).
- **Перезапуск** сервиса только при реальных изменениях (обновлён список и/или изменён `MODE_LIST`). Если hostlist уже был в конфиге и список не обновляли — перезапуск не выполняется.

### 5. Обход блокировки DoT/DoH

Доступно при установленном **nfqws-keenetic** и/или **nfqws2-keenetic** (при обеих версиях — выбор v1 / v2 / обе).

Добавляет в `NFQWS_ARGS_CUSTOM` стратегию обхода блокировок публичных DoT/DoH DNS:

- **nfqws1** — [`strategies/dns_filter_nfqws1`](strategies/dns_filter_nfqws1) (классический `--dpi-desync`)
- **nfqws2** — [`strategies/dns_filter_nfqws2`](strategies/dns_filter_nfqws2) (lua-desync)

Покрывает Cloudflare, Google, AdGuard, NextDNS, Quad9, DNS.SB, Alibaba, Xbox-DNS, Geohide и др.; при необходимости добавляет порт `853` в `TCP_PORTS` / `UDP_PORTS` и перезапускает соответствующий сервис. Стратегия сначала скачивается с GitHub, при недоступности сети — встроенный fallback (пути blob-файлов подставляются под платформу).

### 6. Смена активных fake:blob

Позволяет заменить используемые в конфиге `fake:blob=NAME` на другой `.bin`-файл (переназначает путь в `--blob=NAME:…`).

- Быстрый разбор конфига (v1/v2) одним проходом **awk**: секции `NFQWS_*ARGS*`, map `--blob=name:path`, уникальные `fake:blob=` (hex пропускаются).
- Показывает список найденных имён по секциям.
- Кандидаты `.bin`: локальные → имена из **`strategies/blobs/SHA256SUMS`** → GitHub API → встроенный fallback.
- При выборе файла из репозитория — скачивает его, обновляет `--blob=…`, бэкап конфига.
- Перезапуск сервиса — по подтверждению (по умолчанию Да).

### 7. Обновление hosts

Статические DNS-привязки через управляемый блок с маркерами `# >>> nfqws-menu hosts >>>` в `/etc/hosts`; dnsmasq подхватывает его автоматически, после изменений сервис перечитывается. Удаление — чистка блока, чужие записи в `/etc/hosts` не затрагиваются.

- Скачивает файл `hosts` из репозитория.
- Секции задаются комментариями `# Имя секции`; внутри — строки `IP DOMAIN`.
- Можно выбрать одну или несколько секций, **все**, либо **88** — удалить записи, **99** — просмотреть текущие.
- Только **IPv4**; битые домены (`..`, ведущая `.`) пропускаются; **один IP на домен**.

### 8. Управление DoT/DoH

Управление DNS через пакет `https-dns-proxy` (DoH): серверы как uci-секции, привязка домена — `server=/домен/127.0.0.1#порт` в `dhcp.@dnsmasq[0].server`. Режим выборочных доменов: остальной DNS идёт как раньше.

Подменю:

```
1) Добавить DoH сервер (https-dns-proxy)
2) Привязать домен к DoH серверу
3) Удалить привязку домена
4) Удалить DoH сервер
0) Назад
```

Возможности:
- Просмотр текущих DoH-серверов и персональных привязок к доменам
- Пресеты DoH: Cloudflare, Google, Quad9, AdGuard, DNS.SB, CleanBrowsing и др., либо ручной ввод
- Удаление upstream-ов и привязок с автоперезапуском сервисов

### 10. dpi-detector

Инструмент для анализа цензуры трафика в России: обнаруживает и классифицирует блокировки сайтов, хостингов и CDN (TCP16–20 блокировки), а также подмену DNS-запросов провайдером.

Актуальная версия [dpi-detector](https://github.com/Runnin4ik/dpi-detector) (ветка `rust`). Бинарник сохраняется в `/usr/bin/dpi-detector`.

Если бинарник уже есть — сразу запускает его.

### 11. awg-openwrt (AmneziaWG)

Интеграция [2Grey/awg-openwrt](https://github.com/2Grey/awg-openwrt) — поддержка протокола AmneziaWG (AWG 3.1) для OpenWrt:

- **Автоматическая установка** через официальный feed-скрипт с поддержкой `opkg` (OpenWrt ≤24.10) и `apk` (OpenWrt 25.x+):
  - Модуль ядра `kmod-amneziawg`
  - Утилиты управления `amneziawg-tools` (`awg`)
  - Протокол LuCI `luci-proto-amneziawg` (поддержка интервалов keepalive и параметров обфускации)
  - Опциональный русский перевод интерфейса LuCI (`luci-i18n-amneziawg-ru`)
- **Диагностика системы** через официальный скрипт `amneziawg-check.sh` (проверка релизов, архитектуры, фидов, парсера LuCI и версии модуля).
- **Просмотр состояния** интерфейсов и пиров (`awg show`).
- **Корректное удаление** пакетов и сторонних репозиториев/ключей из системы.

### 12. MagiTrickle

Утилита для точечной маршрутизации сетевого трафика по заданным доменным именам.

Установка / обновление [MagiTrickle](http://bin.magitrickle.dev/):
- **Не установлен** — добавление репозитория (`add_repo.sh`) + установка пакета + запуск сервиса
- **Установлен** → обновление пакета + restart сервиса
- Init: `/etc/init.d/magitrickle` (procd)
- Удаление — в п. 88 (с опциональным удалением файла репозитория)

### 13. luci-app-telemt (MTProxy)

MTProto-прокси на C с веб-интерфейсом LuCI ([Medvedolog/luci-app-telemt](https://github.com/Medvedolog/luci-app-telemt)):
- Нативная установка пакетов `luci-app-telemt` и ядра `telemt` из релизов GitHub.
- Веб-интерфейс в LuCI: `Службы` → `Telemt MTProxy`.
- Управление сервисом (`/etc/init.d/telemt` start/stop/restart), просмотр логов и параметров подключения.

### 14. TG WS Proxy Rust (tg-ws-proxy-rs)

[tg-ws-proxy-rs](https://github.com/valnesfjord/tg-ws-proxy-rs) — MTProto-прокси на Rust с LuCI-интеграцией на OpenWrt 24.10+. Меню добавляет:

- **секрет и порт прежней установки** (если осталась) — ссылки `tg://` не меняются;
- **выбор сборки** — обычная или компактная (UPX), таблицей: размер на флеше и потребление памяти;
- **подбор параметров по замерам** — CF-домены и варианты лестницы проверяются штатной пробой бинаря, затем выводится список с временем каждого;
- **проверка связи до выдачи ссылки** — `resPQ` от DC Telegram, то есть вся цепочка, а не «порт открыт».

Пути: `/usr/bin/tg-ws-proxy-rs`, `/etc/init.d/tg-ws-proxy-rs`, конфиги `/etc/tg-ws-proxy-rs/`.

### S. Сервисные утилиты

В главном меню: клавиша **S** (или раздел «СЕРВИС»).

| Пункт | Действие |
| --- | --- |
| 1 | **Сжать бинарники утилит (UPX)** — `upx --lzma --best` для установленных бинарников (`nfqws`, `nfqws2`, `tg-ws-proxy-rs`, `dpi-detector`, `telemt`, `magitrickle`, `awg`) в `/usr/bin` и `/usr/sbin` |
| U | **Обновить все пакеты** — `opkg update && opkg upgrade` / `apk update && apk upgrade` (также клавиша **U** из главного меню) |

### 77. Change language

Мгновенное переключение интерфейса **ru ↔ en** (файл `/etc/nfqws-menu/nfqws-menu.lang`).

### 88. Удаление пакетов

Показывает установленные компоненты и позволяет удалить выборочно:

```
Удаление:
  [N] nfqws2-keenetic / nfqws-keenetic-web / awg-openwrt / dpi-detector /
      tg-ws-proxy-rs / magitrickle / luci-app-telemt
  [a] Удалить все пакеты NFQWS
  [b] Удалить резервные копии (.bak.* / *-opkg)
  [0] Назад
```

- Пакеты NFQWS — `opkg remove` / `apk del`
- **awg-openwrt** — удаление пакетов AmneziaWG + очистка фидов и ключей
- **dpi-detector** — `/usr/bin/dpi-detector`
- **tg-ws-proxy-rs** — бинарь, init, конфиги
- **magitrickle** — удаление пакета + запрос на удаление файла репозитория
- **luci-app-telemt** — удаление веб-интерфейса LuCI и ядра `telemt` + запрос на удаление `/etc/config/telemt`
- **a)** — все пакеты NFQWS + dpi-detector
- **b)** — `*.bak.*`, `*.conf-opkg`, `*.list-opkg` в каталогах конфигов nfqws

### 99. Обновить скрипт

Скачивает свежую версию **этого форка**, перезаписывает скрипт (`/usr/bin/nfqws-menu.sh`), обновляет symlink `menu`, сразу перезапускает меню (`exec`).

---

## Changelog

### 0.1.9

- **Корректное определение WAN-интерфейса провайдера (`detect_isp_interface`)**:
  - Приоритетный запрос нативного статуса сети OpenWrt через `ubus` (`network.interface.wan` / `wan6` -> `.l3_device` / `.device`) и UCI (`network.wan.device` / `network.wan.ifname`).
  - Фильтрация виртуальных туннелей (`wg*`, `tun*`, `tap*`, `tailscale*`, `docker*`, `br-*`) в `ip route`, предотвращающая ошибочный перехват VPN-интерфейса вместо физического WAN при активном WireGuard / OpenVPN.
- **Сохранение кэша `SHA256SUMS` при сетевых сбоях**:
  - `ensure_blobs_sha256sums` и `ensure_repo_sha256sums` скачивают данные во временный файл (`.tmp.$$`) и атомарно заменяют кэш только при успешной непустой загрузке. Локальный кэш больше не уничтожается при временной недоступности GitHub.
- **Защита от гонки сигналов `SIGUSR1`**:
  - Ранняя установка `trap '' USR1` при старте скрипта и сброс ловушек перед `exec sh "$dest"` при самообновлении — предотвращает аварийное завершение BusyBox `ash` сигналом 138 (`User defined signal 1`).
- **Синхронизация списков с upstream (v0.10.21)**:
  - Актуализированы CIDR/IPSet списки (`ipset_as.list`, `as.conf`, `google.list`, списки хостингов Contabo, Creanova, FranTech, Iomart, Melbicom).
- **Оптимизация и устранение дублирования**:
  - Добавлен BusyBox fallback (`date -r`) для проверки mtime в `list_repo_blobs`.
  - Дедуплицирована очистка временных файлов в `menu_change_fake_blob` через локальный хелпер `_fb_cleanup`.

### 0.1.8

- **Исправления функциональных багов**:
  - **П. S → 3 (Починка OPKG)**: восстановлена пауза после проверки (`pause_press_enter` вместо несуществующей `pause`) — результат починки больше не «пролетает» мимо экрана.
  - **П. 9 → 2 (Привязка доменов к DoH)**: меню выбора сервера больше не захватывается в переменную — раньше список серверов был невидим, а в привязку dnsmasq записывался мусор вместо порта.
  - **Заголовок меню**: `ver_gt` отсекает ревизионный суффикс opkg (`-1`, `-rN`) — убраны ложные метки «доступно обновление» для установленных версий вида `X.Y.Z-1`.
  - **П. 99 (Обновить скрипт)**: запись нового файла атомарна (`.new` + `mv`) — обрыв при нехватке места больше не оставляет испорченное меню без отката.
  - **П. 1 → 3 (веб-интерфейс)**: результат `pkg_install` проверяется; при неудаче — явная ошибка вместо «Веб-интерфейс установлен».
  - **П. S → 1 (UPX)**: сервисы останавливаются на время сжатия и запускаются обратно (UPX не может переписать бинарник запущенного процесса — ETXTBSY), сбои сжатия больше не глушатся.
- **Мелкие исправления**: `ensure_single_instance` больше не убивает посторонние процессы (`tail`/`vim` на файлах меню) и не трогает родительский процесс; EOF в запросе `ISP_INTERFACE` больше не принимает изменение молча; двойное «0 0» в счётчиках починки OPKG; запись `/etc/hosts` атомарна (temp + `mv`); bootstrap-эвристика DoH принимает только точный IPv4 (не `1.2.3.4.example.com`); явный контракт счётчика `_LIST_CLEAN_COUNT` вместо скрытого динамического скоупа; вставка `--blob` в конфиг переписана с ручного цикла (с недостижимой веткой) на awk.
- **Рефакторинг**: удалён мёртвый код (неиспользуемые ветки `service_is_up`, `LBL_CANCEL`/`LBL_CHOICE`, no-op `killall` с путём); блок разрешения конфликта nfqws ↔ nfqws2 вынесен в `resolve_nfqws_conflict` (было 5 копий); `stop_nfqws1/2_hard` объединены в `_stop_nfqws_hard`; ipset-флоу сведён к хелперу `_ipset_fetch_apply`; `rkn_hostlist_arg` использует `rkn_list_path`.

### 0.1.6

- **Доменные пресеты DoH и GeoHide (пункт 9 / 6)**:
  - Добавлено меню быстрого выбора популярных заблокированных сервисов при точечной привязке доменов к DoH (`owrt_bind_domain_menu`): **Instagram / Meta**, **Twitch**, **Supercell / Brawl Stars**, **Rutor / NTC**, **Discord**, а также полный список **GeoHide** (350+ доменов зарубежных сервисов с геоблоком РФ).
  - Реализован автоматический парсинг и автосоздание рабочего инстанса `https-dns-proxy` (`owrt_doh_get_or_add_port`), если на роутере ещё не настроен DoH-резолвер.
  - Оптимизирована пакетная запись доменов через UCI (один атомарный `uci commit` и один перезапуск dnsmasq вместо сотен последовательных коммитов).
  - Добавлена очистка привязок GeoHide (`g) Удалить только привязки GeoHide`) и защита длинных списков от убегания экрана терминала.
- **Прямая standalone-установка .ipk / .apk (пункт 1 → 4)**:
  - Добавлен пункт «Прямая установка .ipk / .apk (обход фида)» в меню установки NFQWS.
  - Автоматически определяет формат пакетов роутера (`.apk` для OpenWrt 25.x, `.ipk` для OpenWrt ≤ 24.10) и архитектуру.
  - Скачивает официальные релизные бинарные пакеты `nfqws-keenetic`, `nfqws2-keenetic` и `nfqws-keenetic-web` напрямую с GitHub Releases через CDN-зеркала (`ghproxy.net`, jsDelivr) в обход недоступных или сломанных локальных фидов opkg/apk.
- **Менеджер зеркал OpenWrt в сервисном меню (пункт S → 2)**:
  - Автоматическое определение текущего источника дистрибутива в `/etc/opkg/distfeeds.conf`, `/etc/opkg/*.conf` или `/etc/apk/repositories`.
  - Быстрое переключение на проверенные высокоскоростные зеркала: **Alibaba Cloud** (`mirrors.aliyun.com/openwrt`), **Tsinghua TUNA** (`mirrors.tuna.tsinghua.edu.cn/openwrt`), **USTC** (`mirrors.ustc.edu.cn/openwrt`), **Accum.se** (`mirror.accum.se/mirror/openwrt.org`), официальный upstream (`downloads.openwrt.org`) или произвольный пользовательский URL.
  - Переключатель протоколов **HTTPS ↔ HTTP** для обхода ошибок верификации сертификатов при отсутствии `libustream-openssl` или сбитых системных часах (NTP).
  - Безопасное резервное копирование (`.orig`, `.bak`) и автоматический откат при неудачной проверке доступности репозиториев (`pkg_update`).

### 0.1.5

- **Исправление функциональных багов**:
  - **П. 7 (Обновление hosts)**: исправлено зависание цикла чтения выбранных секций (`while read` перехватывал интерактивный `stdin` у `confirm_yes`), исправлено удаление блока записей (`88`), которое раньше не срабатывало при отсутствии секций и выводило неверный счётчик доменов
  - **Детекция запущенных процессов**: `proc_running` и статус главного меню переведены на точное совпадение имени бинарника по границам токенов, исключено ложное срабатывание статуса `nfqws` (v1) от запущенного `nfqws-menu.sh` или `nfqws2`
  - **П. S → 1 (UPX)**: `service_upx_compress` переведён с несуществующего `/opt/*` и неподдерживаемого в BusyBox флага `find -executable` на безопасное сжатие установленных пользовательских бинарников в `/usr/bin` и `/usr/sbin`
- **Глубокая очистка мёртвого кода (~540 строк)**:
  - Удалены недостижимые на OpenWrt функции ручной распаковки Entware `.ipk` (`install_ipk_from_repo`, `menu_install_ipk_direct` и связанные хелперы)
  - Удалён скрытый legacy-пункт `opera-proxy` (Entware-only) и остаточные ветки `/opt/etc/...` во всех модулях
- **Устранение дублирования и рефакторинг**:
  - Вынесены общие хелперы `pkg_install_file` и `get_lan_ip`, дедуплицированы `tg_ws_proxy_rs_target`, `upd_legend`, `load_dot_doh_strategy` и `menu_dot_doh`
  - Вложенные функции в `update_ipset_list` и `update_rkn_list` вынесены на верхний уровень (`_ipset_write_file`, `_ipset_apply_and_restart`, `_rkn_apply_for_ver`)

### 0.1.4

- **Рефакторинг и очистка кода**: удалены мёртвые обёртки и устаревшие функции `menu_awg_manager`, `remove_awg_manager` и `is_awg_manager_installed`
- **Исправление багов**: добавлен недостающий хелпер `pause_press_enter`, устранено аварийное завершение скрипта при вызовах диагностики и статуса интерфейсов AmneziaWG
- **Нумерация утилит**: нумерация сторонних инструментов в главном меню выстроена последовательно (10. dpi-detector, 11. awg-openwrt, 12. MagiTrickle, 13. luci-app-telemt, 14. TG WS Proxy Rust) с сохранением обратной совместимости ввода
- **Документация**: актуализирован `README.md`, добавлено описание интеграции `luci-app-telemt`

### 0.1.3

- **AmneziaWG (пункт 11)**: замена устаревшего `awg-manager` на нативный проект для OpenWrt [2Grey/awg-openwrt](https://github.com/2Grey/awg-openwrt) (AWG 3.1) с автоматической установкой feed, проверкой совместимости LuCI, диагностикой `amneziawg-check.sh` и поддержкой русского языка (`-r`)
- **Очистка от Entware**: удалены привязки к `sing-box`, `/opt/etc/awg-manager` и legacy-путям
- **Удаление пакетов (пункт 88)**: поддержка корректного удаления компонентов AmneziaWG и очистки настроенных фидов opkg/apk
- **Целостность**: синхронизация контрольных сумм в `SHA256SUMS`

### 0.1.2

- **Стратегии**: все пути в `strategies/nfqws1/*.conf`, `strategies/nfqws2/*.conf`, `strategies/dns_filter_nfqws1` и служебных скриптах переведены на нативные пути OpenWrt (`/etc/nfqws*`, `/var/log/*`)
- **README.md**: добавлены быстрые зеркала установки (jsDelivr, Fastly, ghproxy, GitHub raw), полностью удалены Keenetic/Entware-разделы
- **Очистка кода**: удалены `dropbear_fix`, `menu-dns.sh`, вызовы `ndmc`, проверки RCI, KeenKit и зависимости от Entware
- **Целостность**: обновлён `.gitattributes` (`eol=lf` для `.list` и `dns_filter_*`), пересчитан `SHA256SUMS`

### 0.1.1

Ревью кода после адаптации: мёртвый код, дубли, найденные баги.

- **Зеркала установки** — добавлены быстрые зеркала jsDelivr / Fastly / ghproxy / GitHub raw
- **П. 99 (обновить скрипт)** — обновление пишет в тот же файл, на который ссылается `menu` (`menu_script_target()`), и перелинковывает symlink; раньше обновление в `/usr/bin/nfqws-menu.sh` оставляло `menu` указывать на старую копию
- **П. 7 (hosts, OpenWrt)** — новые записи **добавляются к существующему блоку**, а не заменяют его (раньше ранее добавленные домены молча стирались); общий хелпер `hosts_strip_block()`/`hosts_existing_pairs()`
- **П. 8 (DoH, OpenWrt)** — `hdp_instances()` считает **эффективный** порт инстанса (пакет выдаёт `listen_port` по счётчику от 5053 на каждый инстанс), поэтому `hdp_next_port()` больше не может выдать уже занятый порт
- **П. 16 (tg-ws-proxy-rs)** — архитектура OpenWrt содержит суффиксы через `_` (`mipsel_24kc`, `aarch64_cortex-a53`): цель определяется по префиксу, добавлен fallback на `apk --print-arch` и `uname -m`; таблица размеров больше не пустая на типовых роутерах
- **П. 88 (MagiTrickle)** — на apk файл репозитория ищется по подстроке в `/etc/apk/repositories.d`, а не только по имени `/etc/opkg/magitrickle.conf`
- **П. 7** — имена секций hosts с пробелами больше не теряются (чтение построчно вместо word splitting)
- `/opt/etc/nfqws*` → `/etc/nfqws*` в стратегиях вынесено в `strategy_retarget_paths()` (было три копии)
- Очистка Keenetic-only кода: удалены `dropbear_fix`, `menu-dns.sh`, `ndmc_cli`, RCI-проверки, KeenKit
- Добавлен `.gitattributes` — `.sh`/`.conf`/`hosts`/`SHA256SUMS` всегда LF (CRLF ломает busybox ash)

### 0.1.0 (форк Dea1hwa1cher/nfqws-menu-openwrt)

Первый релиз адаптации под OpenWrt. База — апстрим 0.9.41; вся история апстрима (0.4.0–0.9.41) — в [исходном репозитории](https://github.com/rndnaame/nfqws-menu#changelog).

- **Определение ОС** — OpenWrt / ImmortalWrt; переменные платформы (пути, статус opkg, фиды), модель/версия из `/tmp/sysinfo/model` и `/etc/openwrt_release`
- **Пакеты** — нативный фид `https://nfqws.github.io/<repo>/openwrt` с GPG-ключом; поддержка `apk` (OpenWrt 25.x: `packages.adb` в `/etc/apk/repositories.d`, `.pem` в `/etc/apk/keys`); обёртки `pkg_update/install/remove` над opkg/apk
- **Пути** — все конфиги/сервисы/списки через `CONF_BASE_DIR`/`INIT_BASE_DIR`; сервисы procd `nfqws-keenetic` / `nfqws2-keenetic`; sed-подмена `/opt/etc/nfqws*` → `/etc/nfqws*` при применении стратегий
- **П. 7 (hosts)** — на OpenWrt блок-маркеры в `/etc/hosts` + reload dnsmasq
- **П. 8 (DoT/DoH)** — на OpenWrt менеджер `https-dns-proxy` (uci) + привязки доменов через dnsmasq per-domain
- **П. 5 (DoT/DoH-стратегия)** — полностью работает на OpenWrt
- **Web** — нативная установка `nfqws-keenetic-web` из фида `.../openwrt`
- **Утилиты** — dpi-detector (`/usr/local/bin`), MagiTrickle (нативный пакет), tg-ws-proxy-rs (OpenWrt/LuCI-ветка установщика)
- **Совместимость busybox ash** (проверено на устройстве OpenWrt 24.10): без переносов строк с операторами `||`/`&&`/`|` в начале продолжения; обновление скрипта (п. 99) и стратегии качаются из этого форка

---

## Структура репозитория

```
nfqws-menu-openwrt/
├── nfqws-menu.sh          # Главный скрипт меню
├── hosts                  # Секции IP DOMAIN для п. 7
├── SHA256SUMS             # Хеши файлов репозитория (список стратегий без API)
├── README.md
├── .github/workflows/
│   └── sha256sums.yml     # Автообновление SHA256SUMS
└── strategies/
    ├── blobs/
    │   ├── *.bin          # Бинарные шаблоны
    │   └── SHA256SUMS     # Эталоны для проверки blobs на роутере
    ├── lists/             # Готовые списки доменов / IP
    │   ├── user.list
    │   ├── exclude.list
    │   ├── ipset.list
    │   └── ipset_exclude.list
    ├── nfqws1/            # Стратегии для nfqws-keenetic (v1)
    └── nfqws2/            # Стратегии для nfqws2-keenetic (v2)
```

### Как добавить свою стратегию

1. Файл `имя.conf` в `strategies/nfqws1/` или `strategies/nfqws2/`.
2. Полный конфиг (`ISP_INTERFACE=`, `NFQWS_ARGS=` / `NFQWS_BASE_ARGS=` и т.д.).
3. При необходимости — `.bin` в `strategies/blobs/`, списки в `strategies/lists/`.
4. После push workflow обновит `SHA256SUMS` / `strategies/blobs/SHA256SUMS`; скрипт подхватит стратегию из SUMS (или через GitHub API).

---

## Требования

1. OpenWrt 23.05+ (opkg) или 25.x+ (apk); ImmortalWrt — тоже работает.
2. Модули NFQUEUE: `kmod-nft-queue` (fw4 / nftables, 22.03+) или `kmod-ipt-nfqueue` + `iptables-mod-nfqueue` (fw3). Меню предупреждает, если их нет.
3. Для веб-интерфейса ничего дополнительно ставить не нужно — пакет придёт с фидом.

---

## Полезные команды вручную

```bash
# Статус сервисов
service nfqws-keenetic status          # v1
service nfqws2-keenetic status         # v2
/etc/init.d/magitrickle status         # MagiTrickle
/etc/init.d/tg-ws-proxy-rs status      # TG WS Proxy Rust

# Перезапуск
service nfqws-keenetic restart
service nfqws2-keenetic restart

# Информация о пакете
opkg info nfqws-keenetic               # или apk info nfqws-keenetic (25.x+)
opkg info nfqws2-keenetic
opkg info nfqws-keenetic-web

# Конфиги
vi /etc/nfqws/nfqws.conf
vi /etc/nfqws2/nfqws2.conf

# Привязки доменов DNS (п. 8, https-dns-proxy)
uci show https-dns-proxy

# Быстрый запуск меню
menu
```

---

## Отказ от ответственности

Материалы подготовлены в ознакомительных и научно-технических целях.\
Использование на свой страх и риск. Автор не несёт ответственности за последствия.

Стратегии адаптированы на основе [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube),\
подготовлены [@Nare51](https://github.com/Nare51) с использованием искусственного интеллекта.\
Официальные пакеты NFQWS: [nfqws](https://github.com/nfqws).\
База меню: [rndnaame/nfqws-menu](https://github.com/rndnaame/nfqws-menu); адаптация под OpenWrt: [@Dea1hwa1cher](https://github.com/Dea1hwa1cher).
