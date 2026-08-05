#!/bin/sh
# =============================================================================
# patch-xhttp.sh — добавляет поддержку транспорта xhttp в Podkop.
#
# Что делает:
#   1. Добавляет функцию sing_box_cm_set_xhttp_transport_for_outbound
#      в /usr/lib/podkop/sing_box_config_manager.sh
#   2. Добавляет ветку "xhttp" в _add_outbound_transport
#      в /usr/lib/podkop/sing_box_config_facade.sh
#
# Патч идемпотентен: повторный запуск ничего не ломает.
# После патча vless:// ссылки с type=xhttp работают как обычные.
# =============================================================================

# Путь к библиотеке Podkop (переопределяется только для тестов)
PODKOP_LIB="${PODKOP_LIB:-/usr/lib/podkop}"
FACADE="$PODKOP_LIB/sing_box_config_facade.sh"
MANAGER="$PODKOP_LIB/sing_box_config_manager.sh"

XHTTP_MARKER="sing_box_cm_set_xhttp_transport_for_outbound"

log() {
    printf "\033[1;36m[*]\033[0m %s\n" "$1"
}

warn() {
    printf "\033[1;33m[!]\033[0m %s\n" "$1"
}

die() {
    printf "\033[1;31m[x]\033[0m %s\n" "$1" >&2
    exit 1
}

[ -f "$FACADE" ] || die "Файл не найден: $FACADE"
[ -f "$MANAGER" ] || die "Файл не найден: $MANAGER"

# -----------------------------------------------------------------------------
# 1. Менеджер: функция xhttp-транспорта
# -----------------------------------------------------------------------------
if grep -q "$XHTTP_MARKER" "$MANAGER"; then
    log "xhttp уже есть в sing_box_config_manager.sh — пропускаю"
else
    log "Добавляю xhttp-функцию в sing_box_config_manager.sh..."
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
# Example:
#   CONFIG=$(
#       sing_box_cm_set_xhttp_transport_for_outbound \
#           "$CONFIG" "vless-xhttp-out" "/uploads" "" "packet-up" "100-1000"
#   )
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
    log "Готово: функция добавлена в sing_box_config_manager.sh"
fi

# -----------------------------------------------------------------------------
# 2. Фасад: ветка "xhttp" в _add_outbound_transport
# -----------------------------------------------------------------------------
if grep -q "$XHTTP_MARKER" "$FACADE"; then
    log "xhttp уже есть в sing_box_config_facade.sh — пропускаю"
else
    log "Добавляю ветку xhttp в sing_box_config_facade.sh..."

    # Ищем строку с "Unknown transport" в _add_outbound_transport
    # и вставляем блок перед строкой "    *)" , которая идёт перед ней
    marker_line="$(grep -n 'log "Unknown transport' "$FACADE" | head -n 1 | cut -d: -f1)"
    if [ -z "$marker_line" ]; then
        warn "Не нашёл 'Unknown transport' в фасаде — проверьте файл вручную"
    else
        insert_at=$((marker_line - 1)) # строка с "    *)"
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
        log "Готово: ветка xhttp добавлена в sing_box_config_facade.sh"
    fi
fi

# -----------------------------------------------------------------------------
# 3. Проверка синтаксиса
# -----------------------------------------------------------------------------
if command -v sh >/dev/null 2>&1; then
    sh -n "$FACADE" || warn "Фасад не прошёл проверку синтаксиса!"
    sh -n "$MANAGER" || warn "Менеджер не прошёл проверку синтаксиса!"
fi

log "Патч применён. Перезапустите Podkop: /etc/init.d/podkop restart"
