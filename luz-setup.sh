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

# Instala los extras de uso diario: comando `luz`, atajo para Termux:Widget y vigilante cron.
# Es idempotente: se puede repetir sin duplicar nada.
instalar_extras() {
    echo "Instalando extras (comando luz, atajo de widget, vigilante cron)..."

    # Comando corto: `luz` enciende el monitor y muestra el estado; `luz log`, `luz detener`, etc.
    cat > "$PREFIX/bin/luz" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# luz            -> enciende el monitor (si ya corre, no hace nada) y muestra estado
# luz detener|reiniciar|log|estado
if [ -n "$1" ]; then exec bash "$HOME/luz-ctl.sh" "$@"; fi
bash "$HOME/luz-ctl.sh" iniciar
bash "$HOME/luz-ctl.sh" estado
EOF
    chmod +x "$PREFIX/bin/luz"

    # Atajo para Termux:Widget (la app se instala aparte desde F-Droid)
    mkdir -p "$HOME/.shortcuts"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nluz\n' > "$HOME/.shortcuts/luz-encender.sh"
    chmod +x "$HOME/.shortcuts/luz-encender.sh"

    # Versión en segundo plano (sin ventana): funciona con Termux cerrado y sin permiso de superposición.
    # Muestra un aviso en pantalla con el resultado.
    mkdir -p "$HOME/.shortcuts/tasks"
    cat > "$HOME/.shortcuts/tasks/luz-encender-fondo.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
msg=$(bash "$HOME/luz-ctl.sh" iniciar 2>&1 | head -n 1)
command -v termux-toast >/dev/null && termux-toast -g middle "Monitor de luz: $msg"
EOF
    chmod +x "$HOME/.shortcuts/tasks/luz-encender-fondo.sh"

    # Vigilante: cada 5 min intenta iniciar el monitor; si ya corre, no hace nada
    if ! command -v crond >/dev/null; then pkg install -y cronie || { echo "No se pudo instalar cronie."; return 1; }; fi
    ( crontab -l 2>/dev/null | grep -v 'luz-ctl.sh iniciar'
      echo '*/5 * * * * bash $HOME/luz-ctl.sh iniciar >/dev/null 2>&1' ) | crontab -
    pgrep -x crond >/dev/null || crond
    echo "Listo: usa 'luz' para encender el monitor; cron lo vigila cada 5 min."
}

# Modo "extras": instala solo comando luz, atajo y vigilante
if [ "$1" = "extras" ]; then
    instalar_extras
    exit $?
fi

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

# 7) Extras de uso diario
instalar_extras
