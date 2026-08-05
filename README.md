# xHTTP Mod (podkop-xhttp)

Модифицированный [Podkop](https://github.com/itdoginfo/podkop) **v0.8** с брендом **xHTTP Mod**:
поддержка транспорта **xhttp**, русский язык интерфейса, последний **sing-box-extended** —
всё в одном репозитории, установка одной командой.

Проблема, которую решает: Podkop из коробки не понимает vless:// ссылки с `type=xhttp`
(в его фасаде поддержка только `tcp/raw`, `ws`, `grpc`). Этот проект патчит Podkop,
добавляя транспорт xhttp, и ставит **sing-box-extended** — единственную сборку sing-box,
которая умеет xhttp. После этого достаточно вставить обычную vless:// ссылку в LuCI.

## Быстрая установка

```sh
sh <(curl -sSL https://raw.githubusercontent.com/flareon2008/podkop-xhttp/main/install.sh)
```

или без curl:

```sh
sh <(wget -qO- https://raw.githubusercontent.com/flareon2008/podkop-xhttp/main/install.sh)
```

### Параметры

| Флаг | Описание |
|---|---|
| `--no-ru` | не ставить русский язык интерфейса LuCI |
| `--version=0.8` | конкретная версия xHTTP Mod (по умолчанию последний релиз 0.8) |

## Что делает скрипт

1. Проверяет root, OpenWrt 24.10+, свободное место и DNS.
2. Ставит зависимости: `wget-ssl`, `curl`, `jq`, `kmod-nft-tproxy`, `kmod-nft-queue`, `kmod-tun`, `ca-bundle`, `coreutils-base64`, `bind-dig`, `firewall4`.
3. Ставит **sing-box-extended** (последний стабильный релиз, подбирает архитектуру под роутер, например `aarch64_cortex-a53`; качает из Release этого репозитория, при отсутствии — из официального shtorm-7).
4. Ставит **xHTTP Mod 0.8** (podkop + luci-app + русский язык интерфейса) — уже запатченные пакеты из папки `bin/`.
5. Применяет патч xhttp к `/usr/lib/podkop/sing_box_config_manager.sh` и `sing_box_config_facade.sh` (на случай установки поверх старого Podkop).
6. Запускает Podkop и показывает итоговую проверку.

Скрипт идемпотентен: повторный запуск безопасен (проверяет уже установленные пакеты и патч).

## Структура репозитория

```
install.sh                 — установщик (одна команда на роутере)
bin/                       — готовые пакеты (ipk):
  ├─ podkop-v0.8-r1-all.ipk
  ├─ luci-app-podkop-v0.8-r1-all.ipk
  ├─ luci-i18n-podkop-ru-0.8-r1.ipk
  └─ sing-box-extended_1.13.14-extended-2.5.3_openwrt_aarch64_cortex-a53.ipk
  └─ sing-box-extended_1.13.14-extended-2.5.3_openwrt_aarch64_cortex-a53_compressed.ipk  (UPX, ~15 МБ — для роутеров с малым местом)
src/podkop/                — исходники podkop 0.8 с патчем xhttp
src/luci-app-podkop/       — исходники интерфейса (бренд xHTTP Mod, ru-перевод)
patch/patch-xhttp.sh       — автономный патч для уже установленного Podkop
```

## Настройка после установки

1. Откройте LuCI: `http://192.168.1.1/cgi-bin/luci/admin/services/podkop`
2. Вкладка **Секции (Sections)** → **Добавить секцию**:
   - Тип соединения: **Прокси**
   - Конфигурация: **Ссылка на подключение (Connection URL)**
   - Вставьте vless:// ссылку (например с `type=xhttp&mode=packet-up&x_padding_bytes=100-1000`)
3. Сохраните и нажмите **Apply**.

Если списки доменов не качаются (ошибка вида `Download twitter list failed`):

- В **Настройки (Settings)** включите **«Скачивать списки через прокси» (Download lists via proxy)**
  и выберите секцию с вашим ключом. Это нужно, когда GitHub/raw.githubusercontent.com
  заблокирован — списки тогда качаются через туннель.

## Как это устроено

### Патч

- `patch/patch-xhttp.sh` — автономный патч для уже установленного Podkop.
  Применяется вручную на роутере: `sh patch-xhttp.sh`
  (или из репозитория: `sh <(curl -sSL .../patch/patch-xhttp.sh)`).

Патч добавляет две вещи:

1. В `sing_box_config_manager.sh` — функцию `sing_box_cm_set_xhttp_transport_for_outbound`,
   которая генерирует блок `transport: {type: "xhttp", mode, host, path, x_padding_bytes}`.
2. В `sing_box_config_facade.sh` — ветку `xhttp` в `_add_outbound_transport`,
   чтобы vless:// URL с `type=xhttp` конвертировался автоматически.

Пример сгенерированного outbound (наш тестовый ключ):

```json
{
  "type": "vless",
  "tag": "proxy-out",
  "server": "45.12.70.93",
  "server_port": 443,
  "uuid": "c9a235de-c495-4a8c-b05a-27402a44aa44",
  "tls": {
    "enabled": true,
    "server_name": "ai.android",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "oC09idYkH9J1GmtH7X_PxuHC2Cvf0MHO7vELRtkHPCI",
      "short_id": "8c33e42ff2"
    }
  },
  "transport": {
    "type": "xhttp",
    "mode": "packet-up",
    "path": "/uploads",
    "x_padding_bytes": "100-1000"
  }
}
```

Конфиг прошёл валидацию `sing-box check -c` на бинарнике той же версии, что ставится на роутер.

### Почему sing-box-extended

Обычный sing-box (в репозитории OpenWrt) не имеет транспорта xhttp.
Нужна сборка [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended)
(в OpenWrt ставится пакетом `sing-box-extended`, который `Provides: sing-box`).

### Важное про TLS

Podkop 0.7+/0.8 уже генерирует `tls.utls` (а не устаревший `tls.fingerprint`),
поэтому с extended-сборкой TLS/Reality работает корректно без дополнительных патчей.

## Сборка пакетов из исходников (для разработчика)

Готовые ipk лежат в `bin/`. Пересобрать их можно командой:

```sh
# podkop
cd src/podkop && make PODKOP_VERSION=0.8  # в окружении OpenWrt SDK
```

Формат ipk: `debian-binary` + `control.tar.gz` + `data.tar.gz` (архив GNU ar).
Русский язык: `luci-app-podkop/po/ru/podkop.po` компилируется в `.lmo`
утилитой `po2lmo` из OpenWrt LuCI.

## Требования

- OpenWrt 24.10 или новее
- **Минимум 80 МБ свободного места на `/overlay`** для обычной сборки sing-box-extended
  (распакованный бинарник ~67 МБ + Podkop/LuCI ~0.4 МБ + запас).
  Если места меньше, установщик **автоматически выберет сжатую (UPX) сборку** (~15 МБ)
  — достаточно **минимум 20 МБ**.
- root-доступ по SSH

> Проверить свободное место на роутере: `df -h /overlay`
