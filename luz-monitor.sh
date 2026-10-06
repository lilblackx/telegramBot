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
COMANDOS="${COMANDOS:-1}"                    # 1 = el bot responde comandos y solicitudes de acceso (0 = desactivado)
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
CHATS="$HOME/.luz.chats"                     # chats autorizados además del administrador
PEND="$HOME/.luz.pend"                       # chats que pidieron acceso y esperan aprobación
HIST="$HOME/.luz.hist"                       # historial de cortes: "inicio fin" (epoch) por línea
HIST_MAX="${HIST_MAX:-200}"                  # cortes que se conservan en el historial
HIST_MOSTRAR="${HIST_MOSTRAR:-10}"           # cortes que muestra /historial
PROTECTOR_MAX="${PROTECTOR_MAX:-420}"        # un corte de hasta estos segundos se etiqueta "probable protector" (0 = desactivado)
PAUSA="$HOME/.luz.pausa"                     # pausa activa: FIN=epoch (sobrevive reinicios)
PAUSA_DEFECTO="${PAUSA_DEFECTO:-60}"         # minutos de /pausa sin duración
PAUSA_MAX="${PAUSA_MAX:-1440}"               # minutos máximos de una pausa (24 h)
API="https://api.telegram.org"
# ========================================================================

NL=$'\n'
PLUGGED=""; PCT=""; FALLOS=0; EN_CORTE=0; INICIO=""; BAJA_ENVIADA=0
PAUSADO=0; HC_URL=""; LISTENER=""; ULT_HC=0; ULT_NET=0; NET_FALLOS=0; NET_T0=0; NET_DESDE=""

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
duracion() {                                          # segundos -> "H h M min S s" (sin horas si es < 1 h)
    local s=$1
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -ge 3600 ]; then
        printf '%d h %d min %d s' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    else
        printf '%d min %d s' $((s / 60)) $((s % 60))
    fi
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

# ---------- chats autorizados ----------
# CHAT_ID (del .luz.conf) es el administrador. Los demás viven en $CHATS, uno por línea.
lista_chats() {
    { printf '%s\n' "$CHAT_ID"; cat "$CHATS" 2>/dev/null; } | grep -E '^-?[0-9]+$' | awk '!v[$0]++'
}
es_autorizado() { lista_chats | grep -qxF -- "$1"; }
es_pendiente()  { grep -qxF -- "$1" "$PEND" 2>/dev/null; }

agregar_chat() {                                      # 1 = ya estaba autorizado
    es_autorizado "$1" && return 1
    printf '%s\n' "$1" >> "$CHATS"
    if [ -f "$PEND" ]; then
        grep -vxF -- "$1" "$PEND" > "$PEND.tmp"; mv -f "$PEND.tmp" "$PEND"
    fi
    return 0
}

quitar_chat() {                                       # 1 = no estaba, 2 = es el administrador
    [ "$1" = "$CHAT_ID" ] && return 2
    es_autorizado "$1" || return 1
    grep -vxF -- "$1" "$CHATS" > "$CHATS.tmp"; mv -f "$CHATS.tmp" "$CHATS"
    return 0
}

# ---------- envío a Telegram con reintentos ----------
# enviar_a CHAT TEXTO: un solo chat.
enviar_a() {
    local chat="$1" texto="$2" i resp
    for ((i = 1; i <= REINTENTOS; i++)); do
        resp=$(curl -s -m 15 \
            --data-urlencode "chat_id=$chat" \
            --data-urlencode "text=$texto" \
            "$API/bot${TOKEN}/sendMessage" 2>/dev/null)
        if printf '%s' "$resp" | grep -q '"ok":true'; then
            log "Mensaje enviado a $chat (intento $i): $(printf '%s' "$texto" | head -n1)"
            return 0
        fi
        # 400/403: el chat bloqueó el bot o nunca lo inició; reintentar no sirve
        if printf '%s' "$resp" | grep -Eq '"error_code":(400|403)'; then
            log "Envío rechazado por Telegram para $chat: $(printf '%s' "$resp" | head -c 150)"
            return 1
        fi
        log "Fallo de envío a $chat ($i/$REINTENTOS)"
        [ "$i" -lt "$REINTENTOS" ] && dormir "$ESPERA_REINTENTO"
    done
    log "MENSAJE PERDIDO para $chat tras $REINTENTOS intentos: $(printf '%s' "$texto" | head -n1)"
    return 1
}

# enviar TEXTO: solo al administrador (avisos técnicos del teléfono).
enviar() { enviar_a "$CHAT_ID" "$1"; }

# difundir TEXTO: a todos los chats autorizados, en paralelo (uno caído no retrasa a los demás).
difundir() {
    local chat p pids=()
    while IFS= read -r chat; do
        enviar_a "$chat" "$1" &
        pids+=($!)
    done < <(lista_chats)
    for p in "${pids[@]}"; do wait "$p"; done
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

# Historial: una línea "inicio fin" por corte terminado. Conserva solo los últimos HIST_MAX.
registrar_corte() {
    local ini="$1" fin="$2"
    printf '%s %s\n' "$ini" "$fin" >> "$HIST"
    if [ "$(wc -l < "$HIST")" -gt "$HIST_MAX" ]; then
        tail -n "$HIST_MAX" "$HIST" > "$HIST.tmp" && mv -f "$HIST.tmp" "$HIST"
    fi
}

# ---------- pausa ----------
# Mientras hay pausa NO se inician cortes nuevos (sirve para desenchufar a propósito).
# Un corte ya en curso sigue vigilándose para avisar cuando vuelva la luz.
pausa_fin() {                                         # imprime el epoch de fin si la pausa sigue activa
    local fin
    fin=$(sed -n 's/^FIN=\([0-9][0-9]*\)$/\1/p' "$PAUSA" 2>/dev/null | head -n1)
    [ -n "$fin" ] && [ "$(date +%s)" -lt "$fin" ] && printf '%s' "$fin"
    return 0
}

# Lo llama el bucle principal: actualiza PAUSADO y avisa al administrador cuando la pausa vence.
revisar_pausa() {
    if [ -n "$(pausa_fin)" ]; then PAUSADO=1; return; fi
    if [ -f "$PAUSA" ]; then
        rm -f "$PAUSA"
        log "Pausa terminada"
        enviar "▶️ La pausa terminó. Monitor activo otra vez.${NL}🕒 $(ahora)"
    elif [ "$PAUSADO" -eq 1 ]; then
        log "Pausa cancelada"
    fi
    PAUSADO=0
}

cmd_pausa() {
    local admin="$1" arg="$2" num uni seg fin extra=""
    [ -n "$arg" ] || arg="${PAUSA_DEFECTO}m"
    if ! printf '%s' "$arg" | grep -Eq '^[0-9]{1,4}[mhd]?$'; then
        enviar_a "$admin" "Uso: /pausa [duración]${NL}Ejemplos: /pausa 30 (minutos), /pausa 2h, /pausa 1d${NL}Sin duración: ${PAUSA_DEFECTO} min. Máximo: $((PAUSA_MAX / 60)) h."
        return
    fi
    num=${arg%%[mhd]}; uni=${arg#"$num"}; [ -n "$uni" ] || uni=m
    num=$((10#$num))
    case "$uni" in
        m) seg=$((num * 60)) ;;
        h) seg=$((num * 3600)) ;;
        d) seg=$((num * 86400)) ;;
    esac
    if [ "$seg" -le 0 ]; then
        enviar_a "$admin" "La duración debe ser mayor a 0. Para quitar una pausa usa /reanudar."; return
    fi
    if [ "$seg" -gt $((PAUSA_MAX * 60)) ]; then
        seg=$((PAUSA_MAX * 60)); extra="${NL}ℹ️ Se limitó al máximo de $((PAUSA_MAX / 60)) h."
    fi
    fin=$(( $(date +%s) + seg ))
    printf 'FIN=%s\n' "$fin" > "$PAUSA"
    log "Pausa hasta $(hora_de "$fin") (pedida por $admin)"
    [ -f "$ESTADO" ] && extra="${extra}${NL}⚡ Hay un corte en curso: seguiré avisando cuando vuelva la luz."
    enviar_a "$admin" "⏸️ En pausa hasta $(hora_de "$fin")${NL}No avisaré cortes nuevos. Si el cargador sigue desconectado al terminar, avisaré el corte.${NL}/reanudar para volver antes.${extra}"
}

cmd_reanudar() {
    local admin="$1"
    if [ -z "$(pausa_fin)" ]; then
        rm -f "$PAUSA"
        enviar_a "$admin" "ℹ️ No hay ninguna pausa activa."; return
    fi
    rm -f "$PAUSA"
    log "Pausa cancelada por $admin"
    enviar_a "$admin" "▶️ Monitor reanudado. Si el cargador sigue desconectado, avisaré el corte en unos segundos."
}

# ---------- bot: comandos de Telegram (/estado, /ayuda) ----------
# Corre en segundo plano (proceso aparte) para no bloquear la detección de cortes.
# Lee su propia batería y el archivo $ESTADO, así no necesita compartir variables.
responder_estado() {
    local chat="$1" luz inicio msg fin
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
    fin=$(pausa_fin)
    [ -n "$fin" ] && msg="${msg}${NL}⏸️ Monitor en pausa hasta $(hora_de "$fin")"
    enviar_a "$chat" "$msg"
}

responder_ayuda() {
    local chat="$1" msg
    msg="🤖 Monitor de luz${NL}/estado - luz, batería y duración del corte${NL}/historial - últimos cortes${NL}/ayuda - esta ayuda"
    if [ "$chat" = "$CHAT_ID" ]; then
        msg="${msg}${NL}${NL}👑 Administrador${NL}/pausa [30|2h|1d] - no avisar cortes nuevos (sin duración: ${PAUSA_DEFECTO} min)${NL}/reanudar - quitar la pausa${NL}/usuarios - ver chats autorizados y solicitudes${NL}/agregar ID - autorizar un chat${NL}/quitar ID - revocar un chat"
    fi
    enviar_a "$chat" "$msg"
}

# ¿un corte de $1 segundos parece el reinicio del protector de la casa tras una fluctuación?
es_corte_corto() { [ "$PROTECTOR_MAX" -gt 0 ] && [ "$1" -le "$PROTECTOR_MAX" ]; }

responder_historial() {
    local chat="$1" lineas ini fin n=0 total msg cabecera
    if [ ! -s "$HIST" ]; then
        enviar_a "$chat" "📜 Historial${NL}Aún no hay cortes registrados."; return
    fi
    total=$(wc -l < "$HIST")
    lineas=$(tail -n "$HIST_MOSTRAR" "$HIST" | tac)       # más reciente primero
    cabecera="📜 Últimos cortes (${total} registrados)"
    msg=""; local suma=0 cortos=0 marca
    while read -r ini fin; do
        [ -n "$ini" ] && [ -n "$fin" ] || continue
        n=$((n + 1)); marca=""
        es_corte_corto $(( fin - ini )) && marca=" 🛡️"
        msg="${msg}${NL}${n}. $(hora_de "$ini") - $(duracion $(( fin - ini )))${marca}"
    done <<< "$lineas"
    # Totales de todo lo registrado
    while read -r ini fin; do
        [ -n "$ini" ] && [ -n "$fin" ] || continue
        suma=$(( suma + fin - ini ))
        es_corte_corto $(( fin - ini )) && cortos=$((cortos + 1))
    done < "$HIST"
    msg="${msg}${NL}${NL}⏱️ Tiempo total sin luz (registrado): $(duracion "$suma")"
    if [ "$PROTECTOR_MAX" -gt 0 ]; then
        msg="${msg}${NL}🛡️ = corte corto, probable reinicio del protector (${cortos} de ${total})"
    fi
    enviar_a "$chat" "${cabecera}${msg}"
}

# ---------- gestión de usuarios (solo administrador) ----------
solicitar_acceso() {
    local chat="$1" nombre="$2"
    if es_pendiente "$chat"; then
        enviar_a "$chat" "⏳ Tu solicitud ya está pendiente. El administrador te avisará cuando la apruebe."
        return
    fi
    printf '%s\n' "$chat" >> "$PEND"
    log "Solicitud de acceso de $chat ($nombre)"
    enviar_a "$chat" "📨 Solicitud enviada al administrador. Te avisaré cuando te aprueben.${NL}🆔 Tu ID: $chat"
    enviar "🔔 Solicitud de acceso${NL}👤 $nombre${NL}🆔 $chat${NL}Para aprobar: /agregar $chat"
}

responder_usuarios() {
    local chat="$1" msg="" c n=0
    while IFS= read -r c; do
        n=$((n + 1))
        if [ "$c" = "$CHAT_ID" ]; then msg="${msg}${NL}👑 $c (administrador)"; else msg="${msg}${NL}👤 $c"; fi
    done < <(lista_chats)
    msg="👥 Autorizados (${n})${msg}"
    if [ -s "$PEND" ]; then
        msg="${msg}${NL}${NL}⏳ Pendientes (aprobar con /agregar ID)"
        while IFS= read -r c; do msg="${msg}${NL}🆔 $c"; done < "$PEND"
    fi
    enviar_a "$chat" "$msg"
}

cmd_agregar() {
    local admin="$1" id="$2"
    if ! printf '%s' "$id" | grep -Eq '^-?[0-9]+$'; then
        enviar_a "$admin" "Uso: /agregar ID_DEL_CHAT${NL}(el ID llega en la solicitud de acceso)"; return
    fi
    if agregar_chat "$id"; then
        log "Chat autorizado: $id"
        if enviar_a "$id" "✅ El administrador te dio acceso. Recibirás los avisos de luz de la casa.${NL}Escribe /ayuda para ver los comandos."; then
            enviar_a "$admin" "✅ Autorizado: $id"
            responder_estado "$id"
        else
            enviar_a "$admin" "✅ Autorizado: $id${NL}⚠️ No pude escribirle. Esa persona debe abrir el bot y pulsar Iniciar."
        fi
    else
        enviar_a "$admin" "ℹ️ $id ya estaba autorizado."
    fi
}

cmd_quitar() {
    local admin="$1" id="$2"
    if ! printf '%s' "$id" | grep -Eq '^-?[0-9]+$'; then
        enviar_a "$admin" "Uso: /quitar ID_DEL_CHAT (ver IDs con /usuarios)"; return
    fi
    quitar_chat "$id"
    case $? in
        0) log "Chat revocado: $id"
           enviar_a "$admin" "🗑️ Revocado: $id"
           enviar_a "$id" "🚫 El administrador revocó tu acceso a los avisos de luz." ;;
        2) enviar_a "$admin" "No puedes quitar al administrador." ;;
        *) enviar_a "$admin" "ℹ️ $id no estaba autorizado." ;;
    esac
}

# atender CHAT NOMBRE TEXTO: decide qué hacer con un mensaje recibido.
atender() {
    local chat="$1" nombre="$2" texto="$3" cmd arg=""
    cmd=${texto%% *}; cmd=${cmd%%@*}
    [ "$texto" != "${texto#* }" ] && arg=${texto#* }
    arg=${arg// /}

    if ! es_autorizado "$chat"; then
        case "$cmd" in
            /start|/solicitar) solicitar_acceso "$chat" "$nombre" ;;
            *) log "Mensaje ignorado de chat no autorizado: $chat" ;;
        esac
        return
    fi

    case "$cmd" in
        /estado)            log "Comando /estado de $chat";    responder_estado "$chat" ;;
        /historial)         log "Comando /historial de $chat"; responder_historial "$chat" ;;
        /ayuda|/start|/help) log "Comando /ayuda de $chat";    responder_ayuda "$chat" ;;
        /usuarios|/agregar|/aprobar|/quitar|/pausa|/reanudar)
            if [ "$chat" != "$CHAT_ID" ]; then
                enviar_a "$chat" "Solo el administrador puede usar ese comando."
            else
                case "$cmd" in
                    /pausa)              cmd_pausa "$chat" "$arg" ;;
                    /reanudar)           cmd_reanudar "$chat" ;;
                    /usuarios)           responder_usuarios "$chat" ;;
                    /agregar|/aprobar)   cmd_agregar "$chat" "$arg" ;;
                    /quitar)             cmd_quitar "$chat" "$arg" ;;
                esac
            fi ;;
    esac
}

escuchar_comandos() {
    local padre=$$ offset=0 resp linea id chat texto nombre usuario ultimo tmp="$LOCKDIR/poll.out" cpid=""
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
            [ -n "$chat" ] || continue
            # SEGURIDAD: atender() solo ejecuta comandos de chats autorizados;
            # los demás solo pueden pedir acceso con /start
            texto=$(printf '%s' "$linea" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' )
            nombre=$(printf '%s' "$linea" | grep -o '"first_name":"[^"]*"' | head -n1 | cut -d'"' -f4)
            usuario=$(printf '%s' "$linea" | grep -o '"username":"[^"]*"' | head -n1 | cut -d'"' -f4)
            case "$nombre" in *'\u'*) nombre="" ;; esac      # nombres con emojis/fuentes raras llegan como \uXXXX
            if [ -n "$usuario" ]; then nombre="${nombre:+$nombre }(@${usuario})"; fi
            [ -n "$nombre" ] || nombre="(sin nombre)"
            atender "$chat" "$nombre" "$texto"
        # Telegram a veces devuelve el JSON con saltos de línea dentro de cada mensaje: se aplana primero
        done 3< <(printf '%s' "$resp" | tr -d '\n\r' | sed 's/{"update_id"/\n&/g'; echo)
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
    revisar_pausa
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
umask 077                                    # chats, historial y estado solo legibles por Termux

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
[ "$COMANDOS" -eq 1 ] && AYUDA_TXT="${NL}💬 Escribe /estado o /historial para consultar${NL}👥 Chats autorizados: $(lista_chats | wc -l)"
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
            difundir "⚠️ El monitor se reinició DURANTE un corte. Sigue sin luz.${NL}⚡ Corte registrado desde: $(hora_de "$INICIO")${NL}⏱️ Lleva al menos: $(duracion $(( $(date +%s) - INICIO )))${NL}🔋 Batería: ${PCT}%"
        else
            INICIO=$(date +%s); BAJA_ENVIADA=0
            difundir "⚠️ El monitor arrancó SIN corriente: se asume un corte en curso. El inicio real es anterior y se desconoce; la duración se contará desde ahora.${NL}🔋 Batería: ${PCT}%"
        fi
        guardar_estado
    fi
fi
if [ "$EN_CORTE" -eq 0 ] && [ -n "$INICIO_PREVIO" ]; then
    # Había un corte registrado y ya hay luz: volvió mientras el monitor estaba apagado
    FIN=$(date +%s)
    difundir "✅ Volvió la luz${NL}🕒 Detectado: $(ahora)${NL}⏱️ El monitor estuvo apagado durante parte del corte. Registrado desde $(hora_de "$INICIO_PREVIO"); duración máxima: $(duracion $(( FIN - INICIO_PREVIO )))${NL}🔋 Batería: ${PCT}%"
    registrar_corte "$INICIO_PREVIO" "$FIN"
    rm -f "$ESTADO"
fi

# ======================= BUCLE PRINCIPAL =======================
while true; do
    dormir "$INTERVALO"
    tareas_periodicas                      # heartbeat y chequeo de internet
    leer_seguro || continue

    if [ "$EN_CORTE" -eq 0 ]; then
        if [ "$PLUGGED" = "UNPLUGGED" ] && [ "$PAUSADO" -eq 0 ]; then
            T_DETECCION=$(date +%s)
            log "Posible corte; confirmando en ${ANTIREBOTE}s"
            dormir "$ANTIREBOTE"
            leer_seguro || continue
            if [ "$PLUGGED" = "UNPLUGGED" ]; then
                EN_CORTE=1; INICIO="$T_DETECCION"; BAJA_ENVIADA=0; NET_FALLOS=0
                guardar_estado
                log "CORTE confirmado"
                difundir "⚡ Se fue la luz en casa${NL}🕒 Hora: $(hora_de "$INICIO")${NL}🔋 Batería: ${PCT}%"
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
                registrar_corte "$INICIO" "$T_FIN"
                log "LUZ DE VUELTA (corte de $(duracion $(( T_FIN - INICIO ))))"
                NOTA_PROT=""
                es_corte_corto $(( T_FIN - INICIO )) && NOTA_PROT="${NL}🛡️ Corte corto: probable reinicio del protector por una fluctuación."
                difundir "✅ Volvió la luz${NL}🕒 Hora: $(hora_de "$T_FIN")${NL}⏱️ Duración del corte: $(duracion $(( T_FIN - INICIO )))${NL}🔋 Batería: ${PCT}%${NOTA_PROT}"
            else
                log "Falso regreso descartado (sigue el corte)"
            fi
        elif [ "$BAJA_ENVIADA" -eq 0 ] && [ "$BATERIA_BAJA" -gt 0 ] && [ "$PCT" -le "$BATERIA_BAJA" ]; then
            # 8) Batería baja: una sola vez por corte
            BAJA_ENVIADA=1; guardar_estado
            difundir "🪫 Batería baja: ${PCT}% y sigue sin luz. El teléfono podría apagarse pronto."
        fi
    fi
done
