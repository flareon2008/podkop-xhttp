#!/bin/sh
# =============================================================================
# podkop-xhttp — установка xHTTP Mod (модифицированный Podkop) + sing-box-extended
#
# Запуск на роутере (OpenWrt 24.10+):
#   sh <(curl -sSL https://raw.githubusercontent.com/flareon2008/podkop-xhttp/main/install.sh)
#   или
#   sh <(wget -qO- https://raw.githubusercontent.com/flareon2008/podkop-xhttp/main/install.sh)
#
# Что делает:
#   1. Проверяет систему (root, OpenWrt, версия, место)
#   2. Обновляет списки пакетов
#   3. Ставит зависимости: wget-ssl, kmod-nft-queue, kmod-nft-tproxy и др.
#   4. Устанавливает sing-box-extended с поддержкой xhttp
#      (подбирает архитектуру, качает из своего Release или официального)
#   5. Устанавливает xHTTP Mod 0.8 (podkop + luci-app + русский язык)
#   6. Применяет патч xhttp (vless:// ссылки с type=xhttp работают напрямую)
#   7. Запускает Podkop и показывает проверку
#
# Параметры:
#   --no-ru      не ставить русский язык интерфейса
#   --version X  конкретная версия xHTTP Mod (по умолчанию последний релиз 0.8)
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Константы
# -----------------------------------------------------------------------------
GITHUB_USER="flareon2008"
PODKOP_REPO="$GITHUB_USER/podkop-xhttp"
RAW_BASE="https://raw.githubusercontent.com/$PODKOP_REPO/main"
SBX_REPO="shtorm-7/sing-box-extended"
PODKOP_DEFAULT_VERSION="0.8"
INSTALL_RU="1"
PODKOP_VERSION="$PODKOP_DEFAULT_VERSION"

# Цвета
R="\033[1;31m"; G="\033[1;32m"; Y="\033[1;33m"; C="\033[1;36m"; N="\033[0m"

# -----------------------------------------------------------------------------
# Утилиты вывода
# -----------------------------------------------------------------------------
msg()  { printf "${G}[+] %s${N}\n" "$1"; }
info() { printf "${C}[*] %s${N}\n" "$1"; }
warn() { printf "${Y}[!] %s${N}\n" "$1"; }
die()  { printf "${R}[x] %s${N}\n" "$1" >&2; exit 1; }

# Определяем загрузчик (curl или wget)
if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --connect-timeout 15"
    FETCH_FILE="curl -fsSL --connect-timeout 15 -o"
    HAS_CURL="1"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO- --timeout=15"
    FETCH_FILE="wget -q --timeout=15 -O"
    HAS_CURL="0"
else
    die "Не найден curl или wget"
fi

# -----------------------------------------------------------------------------
# Парсинг аргументов
# -----------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --no-ru) INSTALL_RU="0" ;;
        --version=*) PODKOP_VERSION="${arg#--version=}" ;;
        --version) die "Укажите версию через =, например --version=0.8" ;;
    esac
done

# -----------------------------------------------------------------------------
# Проверка системы
# -----------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "Нужны права root (зайдите как root или выполните через su)"

[ -f /etc/openwrt_release ] || die "Это не OpenWrt. Скрипт работает только на OpenWrt 24.10+"

. /etc/openwrt_release

openwrt_major="$(echo "$DISTRIB_RELEASE" | cut -d'.' -f1)"
[ "${openwrt_major:-0}" -ge "24" ] || die "Требуется OpenWrt 24.10 или новее (у вас $DISTRIB_RELEASE)"

info "Маршрутизатор: $(cat /tmp/sysinfo/model 2>/dev/null || echo 'неизвестно')"
info "OpenWrt: $DISTRIB_RELEASE ($DISTRIB_REVISION)"
info "Архитектура: ${DISTRIB_ARCH:-не определена}"

# Место на диске
#   обычный sing-box-extended распакованный ~67 МБ -> нужно >= 80 МБ
#   сжатый (UPX) sing-box-extended ~15 МБ           -> нужно >= 20 МБ
AVAILABLE_SPACE=$(df /overlay | awk 'NR==2 {print $4}')
SBX_USE_COMPRESSED="0"
if [ "$AVAILABLE_SPACE" -ge 81920 ]; then
    info "Места на /overlay достаточно: $((AVAILABLE_SPACE/1024)) МБ (ставлю обычную сборку sing-box)"
elif [ "$AVAILABLE_SPACE" -ge 20480 ]; then
    SBX_USE_COMPRESSED="1"
    info "Места на /overlay: $((AVAILABLE_SPACE/1024)) МБ — ставлю СЖАТУЮ (UPX) сборку sing-box (~15 МБ)"
else
    die "Слишком мало места на /overlay: $((AVAILABLE_SPACE/1024)) МБ (нужно минимум 20 МБ)"
fi

# Проверка DNS
if ! nslookup github.com >/dev/null 2>&1; then
    die "DNS не работает. Проверьте доступ к интернету."
fi

# Конфликтующие пакеты
if opkg list-installed 2>/dev/null | grep -q "https-dns-proxy"; then
    warn "Обнаружен https-dns-proxy (конфликт). Удаляю..."
    opkg remove --force-depends https-dns-proxy luci-app-https-dns-proxy 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Определение пакетного менеджера
# -----------------------------------------------------------------------------
PKG_MANAGER="opkg"
PKG_EXT="ipk"
if command -v apk >/dev/null 2>&1 && [ "$(command -v apk)" != "/opt/bin/apk" ]; then
    PKG_MANAGER="apk"
    PKG_EXT="apk"
fi
info "Пакетный менеджер: $PKG_MANAGER"

pkg_install() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add "$1" >/dev/null 2>&1
    else
        opkg install "$1" >/dev/null 2>&1
    fi
}

pkg_remove() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk del "$1" >/dev/null 2>&1 || true
    else
        opkg remove --force-depends "$1" >/dev/null 2>&1 || true
    fi
}

download() {
    # download <url> <файл>
    if [ "$HAS_CURL" = "1" ]; then
        curl -fsSL --connect-timeout 15 -o "$2" "$1"
    else
        wget -q --timeout=15 -O "$2" "$1"
    fi
}

# -----------------------------------------------------------------------------
# Утилиты для GitHub API
# -----------------------------------------------------------------------------
api_get() {
    $FETCH "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Шаг 1. Обновление списков пакетов
# -----------------------------------------------------------------------------
info "Обновляю списки пакетов..."
if [ "$PKG_MANAGER" = "apk" ]; then
    apk update >/dev/null 2>&1 || warn "apk update вернул ошибку (продолжаю)"
else
    opkg update >/dev/null 2>&1 || warn "opkg update вернул ошибку (продолжаю)"
fi

# -----------------------------------------------------------------------------
# Шаг 2. Установка зависимостей (нужны и Podkop, и sing-box-extended)
# -----------------------------------------------------------------------------
info "Устанавливаю зависимости (kmod-nft-queue, kmod-nft-tproxy, wget-ssl и др.)..."
for pkg in wget-ssl curl jq kmod-nft-tproxy kmod-nft-queue kmod-tun kmod-inet-diag ca-bundle coreutils-base64 bind-dig firewall4; do
    if opkg list-installed 2>/dev/null | grep -q "^${pkg}"; then
        continue
    fi
    info "  ставлю $pkg..."
    pkg_install "$pkg" || warn "  не удалось поставить $pkg (может отсутствовать в репозитории)"
done

# -----------------------------------------------------------------------------
# Шаг 3. Установка sing-box-extended (с xhttp)
# -----------------------------------------------------------------------------
need_sbx_install="0"
if command -v sing-box >/dev/null 2>&1; then
    SB_VERSION="$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
    case "$SB_VERSION" in
        *extended*) msg "sing-box-extended уже установлен: $SB_VERSION" ;;
        *)
            warn "sing-box $SB_VERSION — без поддержки xhttp. Заменяю на extended..."
            need_sbx_install="1"
            ;;
    esac
else
    info "sing-box не установлен — ставлю sing-box-extended"
    need_sbx_install="1"
fi

if [ "$need_sbx_install" = "1" ]; then
    tmp_dir="/tmp/podkop-xhttp"
    rm -rf "$tmp_dir" && mkdir -p "$tmp_dir"
    sbx_file="$tmp_dir/sing-box-extended.${PKG_EXT}"
    sbx_url=""

    # Паттерн имени файла зависит от режима (обычный / сжатый UPX)
    if [ "$SBX_USE_COMPRESSED" = "1" ]; then
        SBX_PREF_PATTERN="sing-box-extended_.*_openwrt_${DISTRIB_ARCH}_compressed\.${PKG_EXT}"
        SBX_ALT_PATTERN="sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.${PKG_EXT}"
    else
        SBX_PREF_PATTERN="sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.${PKG_EXT}"
        SBX_ALT_PATTERN="sing-box-extended_.*_openwrt_${DISTRIB_ARCH}_compressed\.${PKG_EXT}"
    fi

    # Поиск по списку URL: сначала предпочитаемый вариант, потом запасной
    pick_sbx_url() {
        # $1 — список URL, $2..$n — паттерны в порядке приоритета
        local _list="$1"; shift
        local _pat _url
        for _pat in "$@"; do
            for _url in $(printf '%s' "$_list" | tr ',' '\n' | grep 'browser_download_url' | grep -E "$_pat" | awk -F'"' '{print $4}' | head -n 1); do
                if [ -n "$_url" ]; then
                    sbx_url="$_url"
                    return 0
                fi
            done
        done
        return 1
    }

    # 1. Сначала пробуем из своего Release (все пакеты в одном месте)
    info "Ищу sing-box-extended в своём Release..."
    api_own="$(api_get "https://api.github.com/repos/$PODKOP_REPO/releases?per_page=30")" || true
    pick_sbx_url "$api_own" "$SBX_PREF_PATTERN" "$SBX_ALT_PATTERN"

    # 2. Если нет — пробуем из папки bin/ репозитория
    if [ -z "$sbx_url" ]; then
        info "В своём Release нет ipk. Ищу в bin/ репозитория..."
        api_bin="$(api_get "https://api.github.com/repos/$PODKOP_REPO/contents/bin")" || true
        pick_sbx_url "$api_bin" "$SBX_PREF_PATTERN" "$SBX_ALT_PATTERN"
    fi

    # 3. Если и там нет — фолбэк на официальный репозиторий shtorm-7
    if [ -z "$sbx_url" ]; then
        info "В bin/ нет ipk для ${DISTRIB_ARCH}. Качаю из $SBX_REPO..."
        api_response="$(api_get "https://api.github.com/repos/$SBX_REPO/releases?per_page=30")" || true
        pick_sbx_url "$api_response" "$SBX_ALT_PATTERN"
        if [ -z "$sbx_url" ]; then
            warn "Не нашёл ipk для ${DISTRIB_ARCH} в последних релизах. Ищу в более старых..."
            for _url in $(printf '%s' "$api_response" | tr ',' '\n' | grep 'browser_download_url' | grep "sing-box-extended_.*_openwrt_.*\.${PKG_EXT}" | awk -F'"' '{print $4}' | head -n 10); do
                if echo "$_url" | grep -q "${DISTRIB_ARCH}"; then
                    sbx_url="$_url"
                    break
                fi
            done
        fi
    fi

    [ -z "$sbx_url" ] && die "Не удалось найти sing-box-extended для архитектуры ${DISTRIB_ARCH}. Проверьте https://github.com/$SBX_REPO/releases"

    info "Скачиваю: $sbx_url"
    download "$sbx_url" "$sbx_file" || die "Не удалось скачать sing-box-extended"

    [ -s "$sbx_file" ] || die "Скачанный файл пустой"

    # Останавливаем podkop/sing-box на время замены
    /etc/init.d/podkop stop 2>/dev/null || true
    /etc/init.d/sing-box stop 2>/dev/null || true

    if [ "$PKG_MANAGER" = "apk" ]; then
        apk del sing-box sing-box-extended >/dev/null 2>&1 || true
        apk add --allow-untrusted "$sbx_file" || die "Не удалось установить sing-box-extended"
    else
        opkg remove --force-depends sing-box 2>/dev/null || true
        opkg install --force-reinstall --force-overwrite "$sbx_file" || die "Не удалось установить sing-box-extended (зависимости: kmod-nft-queue и др.)"
    fi

    if [ ! -f /usr/bin/sing-box ]; then
        for path in /usr/bin/sing-box-extended /usr/sbin/sing-box-extended /usr/sbin/sing-box; do
            if [ -f "$path" ]; then
                ln -sf "$path" /usr/bin/sing-box
                break
            fi
        done
    fi

    msg "sing-box-extended установлен: $(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
fi

# -----------------------------------------------------------------------------
# Шаг 4. Установка xHTTP Mod (podkop + luci-app + русский язык)
# -----------------------------------------------------------------------------
DOWNLOAD_DIR="/tmp/podkop-xhttp"
rm -rf "$DOWNLOAD_DIR" && mkdir -p "$DOWNLOAD_DIR"

# Проверяем, установлен ли уже podkop подходящей версии
podkop_installed="0"
if command -v /usr/bin/podkop >/dev/null 2>&1; then
    current_ver="$(/usr/bin/podkop show_version 2>/dev/null | sed 's/^v//')"
    if [ -n "$current_ver" ]; then
        info "Podkop уже установлен: v$current_ver"
        # Сравнение версий: устанавливаем, только если текущая < запрошенной
        if [ "$(printf '%s\n%s\n' "$current_ver" "$PODKOP_VERSION" | sort -V | tail -n1)" = "$current_ver" ]; then
            podkop_installed="1"
        else
            warn "Podkop v$current_ver старее $PODKOP_VERSION — обновляю..."
        fi
    fi
fi

if [ "$podkop_installed" = "1" ]; then
    info "Podkop уже актуальный — пропускаю установку пакетов (патч применится далее)"
else
    info "Скачиваю xHTTP Mod $PODKOP_VERSION..."
    # Пакеты лежат в репозитории в папке bin/
    for pkg in "podkop-v${PODKOP_VERSION}-r1-all" "luci-app-podkop-v${PODKOP_VERSION}-r1-all"; do
        file="$DOWNLOAD_DIR/${pkg}.${PKG_EXT}"
        download "$RAW_BASE/bin/${pkg}.${PKG_EXT}" "$file" || die "Не удалось скачать $pkg"
    done

    # Русский язык
    if [ "$INSTALL_RU" = "1" ]; then
        ru_file="luci-i18n-podkop-ru-${PODKOP_VERSION}-r1.${PKG_EXT}"
        download "$RAW_BASE/bin/$ru_file" "$DOWNLOAD_DIR/$ru_file" || warn "Не удалось скачать русский язык"
    fi

    info "Устанавливаю Podkop..."
    for f in "$DOWNLOAD_DIR"/podkop-v*.${PKG_EXT}; do
        [ -f "$f" ] && pkg_install "$f" || warn "  (podkop: установлен или требует зависимости)"
    done

    info "Устанавливаю luci-app-podkop..."
    for f in "$DOWNLOAD_DIR"/luci-app-podkop-v*.${PKG_EXT}; do
        [ -f "$f" ] && pkg_install "$f" || warn "  (luci-app-podkop: установлен или требует зависимости)"
    done

    if [ "$INSTALL_RU" = "1" ] && ls "$DOWNLOAD_DIR"/luci-i18n-podkop-ru-*.${PKG_EXT} >/dev/null 2>&1; then
        info "Устанавливаю русский язык интерфейса..."
        for f in "$DOWNLOAD_DIR"/luci-i18n-podkop-ru-*.${PKG_EXT}; do
            [ -f "$f" ] && pkg_install "$f" || warn "  (русский язык: установлен или требует зависимости)"
        done
    fi
fi

# -----------------------------------------------------------------------------
# Шаг 5. Патч Podkop: поддержка xhttp
# -----------------------------------------------------------------------------
info "Применяю патч xhttp к Podkop..."

# --- 5.1. Менеджер: xhttp-функция ---
MANAGER="/usr/lib/podkop/sing_box_config_manager.sh"
if [ -f "$MANAGER" ] && ! grep -q "sing_box_cm_set_xhttp_transport_for_outbound" "$MANAGER"; then
    cat >> "$MANAGER" <<'XHTTP_FUNC'

#######################################
# Set XHTTP transport settings for an outbound in a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the outbound to modify
#   path: string, XHTTP path (optional)
#   host: string, Host header for XHTTP (optional)
#   mode: string, XHTTP mode: auto|packet-up|stream-up|stream-one (optional)
#   x_padding_bytes: string, padding range like "100-1000" (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
#######################################
sing_box_cm_set_xhttp_transport_for_outbound() {
    local config="$1"
    local tag="$2"
    local path="$3"
    local host="$4"
    local mode="$5"
    local x_padding_bytes="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg path "$path" \
        --arg host "$host" \
        --arg mode "$mode" \
        --arg x_padding_bytes "$x_padding_bytes" \
        '.outbounds |= map(
            if .tag == $tag then
                . + {
                    transport: (
                        { type: "xhttp" }
                        + (if $mode != "" then {mode: $mode} else {} end)
                        + (if $host != "" then {host: $host} else {} end)
                        + (if $path != "" then {path: $path} else {} end)
                        + (if $x_padding_bytes != "" then
                            {x_padding_bytes: $x_padding_bytes}
                        else
                            {x_padding_bytes: "100-1000"}
                        end)
                    )
                }
            else
                .
            end
        )'
}
XHTTP_FUNC
    msg "xhttp-функция добавлена в sing_box_config_manager.sh"
else
    info "xhttp-функция уже есть в sing_box_config_manager.sh"
fi

# --- 5.2. Фасад: ветка xhttp ---
FACADE="/usr/lib/podkop/sing_box_config_facade.sh"
if [ -f "$FACADE" ] && ! grep -q "sing_box_cm_set_xhttp_transport_for_outbound" "$FACADE"; then
    marker_line="$(grep -n 'log "Unknown transport' "$FACADE" | head -n1 | cut -d: -f1)"
    if [ -n "$marker_line" ]; then
        insert_at=$((marker_line - 1))
        tmpfile="$(mktemp)"
        head -n "$((insert_at - 1))" "$FACADE" > "$tmpfile"
        cat <<'XHTTP_BRANCH' >> "$tmpfile"
    xhttp)
        local xhttp_path xhttp_host xhttp_mode xhttp_x_padding_bytes
        xhttp_path=$(url_get_query_param "$url" "path")
        xhttp_host=$(url_get_query_param "$url" "host")
        xhttp_mode=$(url_get_query_param "$url" "mode")
        xhttp_x_padding_bytes=$(url_get_query_param "$url" "x_padding_bytes")

        config=$(
            sing_box_cm_set_xhttp_transport_for_outbound \
                "$config" "$outbound_tag" "$xhttp_path" "$xhttp_host" "$xhttp_mode" "$xhttp_x_padding_bytes"
        )
        ;;

XHTTP_BRANCH
        tail -n "+$insert_at" "$FACADE" >> "$tmpfile"
        mv "$tmpfile" "$FACADE"
        msg "xhttp-ветка добавлена в sing_box_config_facade.sh"
    else
        warn "Не нашёл точку вставки в фасаде — патч xhttp не применён"
    fi
else
    info "xhttp-ветка уже есть в sing_box_config_facade.sh"
fi

# Проверка синтаксиса
if command -v sh >/dev/null 2>&1; then
    sh -n "$FACADE" 2>/dev/null || warn "Фасад не прошёл проверку синтаксиса!"
    sh -n "$MANAGER" 2>/dev/null || warn "Менеджер не прошёл проверку синтаксиса!"
fi

# -----------------------------------------------------------------------------
# Шаг 6. Запуск и проверка
# -----------------------------------------------------------------------------
msg "Запускаю Podkop..."
/etc/init.d/podkop enable 2>/dev/null || true
/etc/init.d/podkop start 2>/dev/null || true
sleep 2

echo ""
info "Проверка установки:"
printf "  sing-box:      %s\n" "$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
printf "  xhttp support: %s\n" "$(sing-box version 2>/dev/null | head -n1 | grep -q extended && echo 'ДА' || echo 'НЕТ (обычный sing-box!)')"
if [ -f /usr/bin/podkop ]; then
    printf "  podkop:        %s\n" "$(/usr/bin/podkop show_version 2>/dev/null || echo 'установлен')"
else
    printf "  podkop:        НЕ НАЙДЕН\n"
fi

echo ""
msg "Готово!"
echo "Дальше в LuCI (http://192.168.1.1/cgi-bin/luci/admin/services/podkop):"
echo " 1. Откройте xHTTP Mod -> Секции (Sections) -> Добавить секцию"
echo " 2. Тип соединения: Прокси, Конфигурация: Ссылка на подключение (Connection URL)"
echo " 3. Вставьте vless:// ссылку с type=xhttp и сохраните"
echo " 4. Нажмите Apply — трафик пойдёт через туннель"
