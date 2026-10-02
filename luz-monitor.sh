#!/data/data/com.termux/files/usr/bin/bash
# luz-monitor.sh - Avisa por Telegram cuando se va y cuando vuelve la luz.
# Detecta el corte mirando si el cargador sigue conectado (termux-battery-status).

# ======================= CONFIGURACIÓN (editable) =======================
INTERVALO="${INTERVALO:-5}"                  # segundos entre lecturas
ANTIREBOTE="${ANTIREBOTE:-10}"               # segundos de confirmación antes de avisar
BATERIA_BAJA="${BATERIA_BAJA:-15}"           # % para la alerta de batería baja (0 = desactivada)
REINTENTOS="${REINTENTOS:-12}"               # intentos de envío a Telegram
ESPERA_REINTENTO="${ESPERA_REINTENTO:-10}"   # segundos entre intentos
TIMEOUT_BATERIA="${TIMEOUT_BATERIA:-10}"     # segundos máx. para termux-battery-status
FALLOS_ALERTA="${FALLOS_ALERTA:-60}"         # lecturas fallidas seguidas para avisar (60 x 5 s = 5 min)
LOG_MAX="${LOG_MAX:-262144}"                 # bytes (256 KB) antes de rotar el log
COMANDOS="${COMANDOS:-1}"                    # 1 = el bot responde /estado y /ayuda (0 = desactivado)
POLL_TIMEOUT="${POLL_TIMEOUT:-50}"           # segundos de long-polling de getUpdates (más alto = menos datos)
CHEQUEO_INTERNET="${CHEQUEO_INTERNET:-60}"   # segundos entre chequeos de internet (0 = desactivado)
INTERNET_FALLOS="${INTERNET_FALLOS:-3}"      # fallos seguidos para considerar internet caído
HC_CADA="${HC_CADA:-300}"                    # segundos entre pings a Healthchecks (solo si hay HC_URL)
# export TZ="America/Caracas"                # descomenta si la hora sale mal

CONF="$HOME/.luz.conf"
LOG="$HOME/luz.log"
LOCKDIR="$HOME/.luz.lock"
ESTADO="$HOME/.luz.estado"                   # corte en curso (sobrevive reinicios)
NETFILE="$HOME/.luz.net"                     # internet caído en curso (sobrevive reinicios)
API="https://api.telegram.org"
# ========================================================================

NL=$'\n'
PLUGGED=""; PCT=""; FALLOS=0; EN_CORTE=0; INICIO=""; BAJA_ENVIADA=0
HC_URL=""; LISTENER=""; ULT_HC=0; ULT_NET=0; NET_FALLOS=0; NET_T0=0; NET_DESDE=""

# ---------- utilidades ----------
log() {
    local tam
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
    tam=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    # Rotación simple: guarda solo 1 log anterior (luz.log.1)
    if [ "$tam" -gt "$LOG_MAX" ]; then mv -f "$LOG" "$LOG.1"; fi
    return 0
}

hora_de()  { date -d "@$1" '+%d/%m/%Y %H:%M:%S'; }   # epoch -> fecha legible
ahora()    { date '+%d/%m/%Y %H:%M:%S'; }
duracion() {                                          # segundos -> "X min Y s"
    local s=$1
    [ "$s" -lt 0 ] && s=0
    printf '%d min %d s' $((s / 60)) $((s % 60))
}
# sleep interrumpible: permite que kill/trap actúe al instante
dormir() { sleep "$1" & wait $!; }

# ---------- instancia única (lock con PID + verificación de proceso vivo) ----------
adquirir_lock() {
    local viejo
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"; return 0
    fi
    viejo=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$viejo" ] && [ "$viejo" != "$$" ] && kill -0 "$viejo" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$viejo/cmdline" 2>/dev/null | grep -q 'luz-monitor'; then
        return 1                                      # hay otra copia viva
    fi
    rm -rf "$LOCKDIR"                                 # lock huérfano (reinicio/crash)
    mkdir "$LOCKDIR" 2>/dev/null || return 1
    echo $$ > "$LOCKDIR/pid"
}

# ---------- envío a Telegram con reintentos ----------
enviar() {
    local texto="$1" i resp
    for ((i = 1; i <= REINTENTOS; i++)); do
        resp=$(curl -s -m 15 \
            --data-urlencode "chat_id=$CHAT_ID" \
            --data-urlencode "text=$texto" \
            "$API/bot${TOKEN}/sendMessage" 2>/dev/null)
        if printf '%s' "$resp" | grep -q '"ok":true'; then
            log "Mensaje enviado (intento $i): $(printf '%s' "$texto" | head -n1)"
            return 0
        fi
        log "Fallo de envío ($i/$REINTENTOS)"
        [ "$i" -lt "$REINTENTOS" ] && dormir "$ESPERA_REINTENTO"
    done
    log "MENSAJE PERDIDO tras $REINTENTOS intentos: $(printf '%s' "$texto" | head -n1)"
    return 1
}

# ---------- lectura de batería (tolera vacío, cuelgue y basura) ----------
leer_bateria() {
    local json p b
    json=$(timeout -k 2 "$TIMEOUT_BATERIA" termux-battery-status 2>/dev/null) || return 1
    [ -n "$json" ] || return 1
    p=$(printf '%s\n' "$json" | sed -n 's/.*"plugged": *"\([^"]*\)".*/\1/p' | head -n1)
    b=$(printf '%s\n' "$json" | sed -n 's/.*"percentage": *\([0-9][0-9]*\).*/\1/p' | head -n1)
    [ -n "$p" ] && [ -n "$b" ] || return 1
    PLUGGED="$p"; PCT="$b"                            # solo se actualizan si la lectura es válida
    return 0
}

leer_seguro() {
    if leer_bateria; then
        [ "$FALLOS" -gt 0 ] && log "Lectura de batería recuperada tras $FALLOS fallos"
        FALLOS=0
        return 0
    fi
    FALLOS=$((FALLOS + 1))
    [ "$FALLOS" -eq 1 ] && log "termux-battery-status vacío, colgado o con error"
    if [ "$FALLOS" -eq "$FALLOS_ALERTA" ]; then
        enviar "⚠️ Monitor de luz: llevo $FALLOS lecturas de batería fallidas seguidas. Revisa Termux:API."
    fi
    return 1
}

guardar_estado() { printf 'INICIO=%s\nBAJA=%s\n' "$INICIO" "$BAJA_ENVIADA" > "$ESTADO"; }

# ---------- bot: comandos de Telegram (/estado, /ayuda) ----------
# Corre en segundo plano (proceso aparte) para no bloquear la detección de cortes.
# Lee su propia batería y el archivo $ESTADO, así no necesita compartir variables.
responder_estado() {
    local luz inicio msg
    if leer_bateria; then
        if [ "$PLUGGED" = "UNPLUGGED" ]; then
            inicio=$(sed -n 's/^INICIO=\([0-9][0-9]*\)$/\1/p' "$ESTADO" 2>/dev/null | head -n1)
            if [ -n "$inicio" ]; then
                luz="⚡ SIN luz desde $(hora_de "$inicio") (lleva $(duracion $(( $(date +%s) - inicio ))))"
            else
                luz="⚡ Sin corriente (corte aún sin confirmar)"
            fi
        else
            luz="💡 Hay luz (cargador: $PLUGGED)"
        fi
        msg="📊 Estado${NL}${luz}${NL}🔋 Batería: ${PCT}%${NL}🕒 $(ahora)"
    else
        msg="📊 Estado${NL}⚠️ No pude leer la batería (Termux:API no responde).${NL}🕒 $(ahora)"
    fi
    enviar "$msg"
}

responder_ayuda() {
    enviar "🤖 Monitor de luz${NL}/estado - luz, batería y duración del corte${NL}/ayuda - esta ayuda"
}

escuchar_comandos() {
    local padre=$$ offset=0 resp linea id chat ultimo tmp="$LOCKDIR/poll.out" cpid=""
    trap '[ -n "$cpid" ] && kill "$cpid" 2>/dev/null; rm -f "$tmp"; exit 0' TERM INT HUP

    # Saltar mensajes viejos: solo atendemos lo que llegue desde ahora
    until resp=$(curl -s -m 15 "$API/bot${TOKEN}/getUpdates?offset=-1") \
          && printf '%s' "$resp" | grep -q '"ok":true'; do
        kill -0 "$padre" 2>/dev/null || exit 0
        dormir 5
    done
    ultimo=$(printf '%s' "$resp" | grep -o '"update_id":[0-9]*' | tail -n1 | cut -d: -f2)
    [ -n "$ultimo" ] && offset=$((ultimo + 1))
    log "Bot de comandos activo (offset $offset)"

    while kill -0 "$padre" 2>/dev/null; do
        # curl en segundo plano + wait: así el trap puede matarlo al detener el monitor
        curl -s -m $((POLL_TIMEOUT + 15)) \
            "$API/bot${TOKEN}/getUpdates?offset=${offset}&timeout=${POLL_TIMEOUT}&allowed_updates=%5B%22message%22%5D" \
            > "$tmp" 2>/dev/null &
        cpid=$!
        wait "$cpid"; cpid=""
        resp=$(cat "$tmp" 2>/dev/null)
        if ! printf '%s' "$resp" | grep -q '"ok":true'; then
            dormir 5; continue                      # sin red o error: reintentar sin saturar
        fi
        # Una línea por mensaje recibido
        # Se lee por el descriptor 3: así termux-battery-status/curl no consumen la entrada
        while IFS= read -r linea <&3; do
            id=$(printf '%s' "$linea" | grep -o '"update_id":[0-9]*' | head -n1 | cut -d: -f2)
            [ -n "$id" ] || continue
            offset=$((id + 1))                      # confirma el mensaje (no se repite)
            chat=$(printf '%s' "$linea" | grep -o '"chat":{"id":-\?[0-9]\+' | head -n1 | grep -o -- '-\?[0-9]\+$')
            if [ "$chat" != "$CHAT_ID" ]; then
                log "Mensaje ignorado de chat no autorizado: $chat"
                continue                            # SEGURIDAD: solo tu CHAT_ID
            fi
            if printf '%s' "$linea" | grep -Eq '"text":"/estado(@[A-Za-z0-9_]+)?"'; then
                log "Comando /estado recibido"; responder_estado
            elif printf '%s' "$linea" | grep -Eq '"text":"/(ayuda|start|help)(@[A-Za-z0-9_]+)?"'; then
                log "Comando /ayuda recibido"; responder_ayuda
            fi
        done 3< <(printf '%s\n' "$resp" | sed 's/{"update_id"/\n&/g')
    done
}

# ---------- heartbeat externo (Healthchecks.io) ----------
ping_hc() {
    # En segundo plano para no retrasar el bucle; -f falla en HTTP >= 400
    ( curl -fsS -m 10 -o /dev/null "$HC_URL" 2>/dev/null \
        || log "Ping a Healthchecks falló" ) &
}

# ---------- aviso de pérdida de internet ----------
chequear_internet() {
    local ahora_s dur
    ahora_s=$(date +%s)
    if curl -m 8 -s -o /dev/null "$API"; then
        if [ -n "$NET_DESDE" ]; then
            dur=$(( ahora_s - NET_DESDE ))
            log "Internet de vuelta tras $(duracion "$dur")"
            rm -f "$NETFILE"
            local desde="$NET_DESDE"; NET_DESDE=""
            enviar "🌐 Estuve sin internet $(duracion "$dur")${NL}📉 Desde: $(hora_de "$desde")${NL}📈 Volvió: $(ahora)"
        fi
        NET_FALLOS=0
    else
        [ "$NET_FALLOS" -eq 0 ] && NET_T0=$ahora_s
        NET_FALLOS=$((NET_FALLOS + 1))
        if [ "$NET_FALLOS" -ge "$INTERNET_FALLOS" ] && [ -z "$NET_DESDE" ]; then
            NET_DESDE="$NET_T0"
            printf 'DESDE=%s\n' "$NET_DESDE" > "$NETFILE"   # guardar el hecho
            log "INTERNET CAÍDO desde $(hora_de "$NET_DESDE") (con luz presente)"
        fi
    fi
}

# ---------- tareas periódicas del bucle principal ----------
tareas_periodicas() {
    local t
    t=$(date +%s)
    if [ -n "$HC_URL" ] && [ $((t - ULT_HC)) -ge "$HC_CADA" ]; then
        ULT_HC=$t; ping_hc
    fi
    # Solo con luz presente: durante un corte el router está apagado y no nos sirve de referencia
    if [ "$CHEQUEO_INTERNET" -gt 0 ] && [ "$EN_CORTE" -eq 0 ] \
       && [ $((t - ULT_NET)) -ge "$CHEQUEO_INTERNET" ]; then
        ULT_NET=$t; chequear_internet
    fi
}

# ======================= INICIO =======================
if [ ! -r "$CONF" ]; then
    echo "Falta $CONF. Ejecuta primero: bash ~/luz-setup.sh" >&2; exit 1
fi
# shellcheck disable=SC1090
. "$CONF"
if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "$CONF incompleto (TOKEN o CHAT_ID vacío)." >&2; exit 1
fi

adquirir_lock || { echo "Ya hay otra instancia corriendo." >&2; exit 1; }
trap '[ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$LOCKDIR"' EXIT
trap 'log "Monitor detenido por señal"; exit 0' INT TERM HUP

# Internet caído registrado antes de un reinicio: avisar al volver la red
if [ -f "$NETFILE" ]; then
    NET_DESDE=$(sed -n 's/^DESDE=\([0-9][0-9]*\)$/\1/p' "$NETFILE" | head -n1)
fi

# Esperar la primera lectura válida
until leer_seguro; do dormir "$INTERVALO"; done
log "Monitor iniciado (PID $$, plugged=$PLUGGED, batería=${PCT}%)"

# Estado previo (por si el teléfono/script se reinició durante un corte)
INICIO_PREVIO=""; BAJA_PREVIA=0
if [ -f "$ESTADO" ]; then
    INICIO_PREVIO=$(sed -n 's/^INICIO=\([0-9][0-9]*\)$/\1/p' "$ESTADO" | head -n1)
    BAJA_PREVIA=$(sed -n 's/^BAJA=\([01]\)$/\1/p' "$ESTADO" | head -n1)
    [ -n "$BAJA_PREVIA" ] || BAJA_PREVIA=0
fi

# 6) Aviso de arranque con estado actual
if [ "$PLUGGED" = "UNPLUGGED" ]; then
    EST_TXT="🔌 SIN corriente (funcionando con batería)"
else
    EST_TXT="💡 Hay luz (cargador: $PLUGGED)"
fi
AYUDA_TXT=""
[ "$COMANDOS" -eq 1 ] && AYUDA_TXT="${NL}💬 Escribe /estado para consultar"
enviar "🟢 Monitor de luz activo${NL}Estado: ${EST_TXT}${NL}🔋 Batería: ${PCT}%${NL}🕒 $(ahora)${AYUDA_TXT}"

# Bot de comandos en segundo plano
if [ "$COMANDOS" -eq 1 ]; then
    escuchar_comandos &
    LISTENER=$!
fi

if [ "$PLUGGED" = "UNPLUGGED" ]; then
    # 7) Arranque sin corriente: confirmar (antirrebote) y avisar en vez de ignorarlo
    dormir "$ANTIREBOTE"
    leer_seguro
    if [ "$PLUGGED" = "UNPLUGGED" ]; then
        EN_CORTE=1
        if [ -n "$INICIO_PREVIO" ]; then
            INICIO="$INICIO_PREVIO"; BAJA_ENVIADA="$BAJA_PREVIA"
            enviar "⚠️ El monitor se reinició DURANTE un corte. Sigue sin luz.${NL}⚡ Corte registrado desde: $(hora_de "$INICIO")${NL}⏱️ Lleva al menos: $(duracion $(( $(date +%s) - INICIO )))${NL}🔋 Batería: ${PCT}%"
        else
            INICIO=$(date +%s); BAJA_ENVIADA=0
            enviar "⚠️ El monitor arrancó SIN corriente: se asume un corte en curso. El inicio real es anterior y se desconoce; la duración se contará desde ahora.${NL}🔋 Batería: ${PCT}%"
        fi
        guardar_estado
    fi
fi
if [ "$EN_CORTE" -eq 0 ] && [ -n "$INICIO_PREVIO" ]; then
    # Había un corte registrado y ya hay luz: volvió mientras el monitor estaba apagado
    FIN=$(date +%s)
    enviar "✅ Volvió la luz${NL}🕒 Detectado: $(ahora)${NL}⏱️ El monitor estuvo apagado durante parte del corte. Registrado desde $(hora_de "$INICIO_PREVIO"); duración máxima: $(duracion $(( FIN - INICIO_PREVIO )))${NL}🔋 Batería: ${PCT}%"
    rm -f "$ESTADO"
fi

# ======================= BUCLE PRINCIPAL =======================
while true; do
    dormir "$INTERVALO"
    tareas_periodicas                      # heartbeat y chequeo de internet
    leer_seguro || continue

    if [ "$EN_CORTE" -eq 0 ]; then
        if [ "$PLUGGED" = "UNPLUGGED" ]; then
            T_DETECCION=$(date +%s)
            log "Posible corte; confirmando en ${ANTIREBOTE}s"
            dormir "$ANTIREBOTE"
            leer_seguro || continue
            if [ "$PLUGGED" = "UNPLUGGED" ]; then
                EN_CORTE=1; INICIO="$T_DETECCION"; BAJA_ENVIADA=0; NET_FALLOS=0
                guardar_estado
                log "CORTE confirmado"
                enviar "⚡ Se fue la luz en casa${NL}🕒 Hora: $(hora_de "$INICIO")${NL}🔋 Batería: ${PCT}%"
            else
                log "Microcorte descartado"
            fi
        fi
    else
        if [ "$PLUGGED" != "UNPLUGGED" ]; then
            T_FIN=$(date +%s)
            log "Posible regreso de la luz; confirmando en ${ANTIREBOTE}s"
            dormir "$ANTIREBOTE"
            leer_seguro || continue
            if [ "$PLUGGED" != "UNPLUGGED" ]; then
                EN_CORTE=0; rm -f "$ESTADO"
                log "LUZ DE VUELTA (corte de $(duracion $(( T_FIN - INICIO ))))"
                enviar "✅ Volvió la luz${NL}🕒 Hora: $(hora_de "$T_FIN")${NL}⏱️ Duración del corte: $(duracion $(( T_FIN - INICIO )))${NL}🔋 Batería: ${PCT}%"
            else
                log "Falso regreso descartado (sigue el corte)"
            fi
        elif [ "$BAJA_ENVIADA" -eq 0 ] && [ "$BATERIA_BAJA" -gt 0 ] && [ "$PCT" -le "$BATERIA_BAJA" ]; then
            # 8) Batería baja: una sola vez por corte
            BAJA_ENVIADA=1; guardar_estado
            enviar "🪫 Batería baja: ${PCT}% y sigue sin luz. El teléfono podría apagarse pronto."
        fi
    fi
done
