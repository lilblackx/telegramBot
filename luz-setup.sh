#!/data/data/com.termux/files/usr/bin/bash
# luz-setup.sh - Configuración inicial: guarda TOKEN y CHAT_ID en ~/.luz.conf (permisos 600)

CONF="$HOME/.luz.conf"
API="https://api.telegram.org"

# Pide la URL de ping de Healthchecks.io (opcional). Deja HC_URL vacío si se omite.
pedir_hc() {
    HC_URL=""
    echo
    echo "Heartbeat Healthchecks.io (opcional): avisa si el teléfono se apaga del todo."
    echo "Pega la URL de ping (https://hc-ping.com/...) o pulsa Enter para omitir:"
    read -r -s HC_URL
    echo
    HC_URL=$(printf '%s' "$HC_URL" | tr -d '[:space:]')
    [ -n "$HC_URL" ] || return 0
    case "$HC_URL" in
        https://*) ;;
        *) echo "La URL debe empezar con https://. Se omite."; HC_URL=""; return 0 ;;
    esac
    if curl -fsS -m 10 -o /dev/null "$HC_URL"; then
        echo "Ping de prueba a Healthchecks correcto."
    else
        echo "El ping de prueba falló. Se omite."; HC_URL=""
    fi
}

# Modo "hc": agrega o cambia solo HC_URL sin tocar el token
if [ "$1" = "hc" ]; then
    [ -r "$CONF" ] || { echo "Primero ejecuta: bash ~/luz-setup.sh"; exit 1; }
    pedir_hc
    [ -n "$HC_URL" ] || { echo "Sin cambios."; exit 1; }
    umask 077
    grep -v '^HC_URL=' "$CONF" > "$CONF.tmp"
    printf 'HC_URL="%s"\n' "$HC_URL" >> "$CONF.tmp"
    mv "$CONF.tmp" "$CONF"; chmod 600 "$CONF"
    echo "HC_URL guardado. Reinicia el monitor: bash ~/luz-ctl.sh reiniciar"
    exit 0
fi

# 1) Pedir el token sin mostrarlo en pantalla
echo "Pega el token de @BotFather (no se verá al escribir) y pulsa Enter:"
read -r -s TOKEN
echo
TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')
[ -n "$TOKEN" ] || { echo "Token vacío. Abortado."; exit 1; }

# 2) Validar el token con getMe
resp=$(curl -s -m 15 "$API/bot${TOKEN}/getMe")
if ! printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "Token inválido o sin internet. Abortado."
    exit 1
fi
echo "Bot reconocido: @$(printf '%s' "$resp" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')"

# 3) Obtener el chat ID con getUpdates (tú debes escribirle al bot antes)
CHAT_ID=""
for intento in 1 2 3; do
    echo
    echo "Abre Telegram, entra a tu bot, pulsa Iniciar y escríbele: hola"
    read -r -p "Cuando lo hayas enviado, pulsa Enter... " _
    resp=$(curl -s -m 15 "$API/bot${TOKEN}/getUpdates")
    # Toma el chat id del mensaje más reciente (puede ser negativo en grupos)
    CHAT_ID=$(printf '%s' "$resp" | grep -o '"chat":{"id":-\?[0-9]\+' | tail -n1 | grep -o -- '-\?[0-9]\+$')
    [ -n "$CHAT_ID" ] && break
    echo "No encontré ningún mensaje (intento $intento/3)."
done
[ -n "$CHAT_ID" ] || { echo "No se pudo obtener el chat ID. Abortado."; exit 1; }
echo "Chat ID detectado: $CHAT_ID"

# 4) Validar enviando un mensaje de prueba
resp=$(curl -s -m 15 \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=✅ Configuración correcta. Ya puedo avisarte de los cortes de luz." \
    "$API/bot${TOKEN}/sendMessage")
if ! printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "El mensaje de prueba falló. No se guardó nada."
    exit 1
fi

# 5) Healthchecks (opcional)
pedir_hc

# 6) Guardar con permisos 600 (el archivo nace ya restringido por el umask)
umask 077
printf 'TOKEN="%s"\nCHAT_ID="%s"\n' "$TOKEN" "$CHAT_ID" > "$CONF"
[ -n "$HC_URL" ] && printf 'HC_URL="%s"\n' "$HC_URL" >> "$CONF"
chmod 600 "$CONF"
unset TOKEN HC_URL
echo "Listo: guardado en $CONF ($(stat -c %a "$CONF"))."
