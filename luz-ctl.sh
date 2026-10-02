#!/data/data/com.termux/files/usr/bin/bash
# luz-ctl.sh - Control del monitor: estado | log | seguir | detener | iniciar | reiniciar

MONITOR="$HOME/luz-monitor.sh"
LOCKDIR="$HOME/.luz.lock"
LOG="$HOME/luz.log"

# Devuelve el PID solo si el monitor está realmente vivo
pid_activo() {
    local p
    p=$(cat "$LOCKDIR/pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null \
        && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'luz-monitor' \
        && echo "$p"
}

detener() {
    local p i
    p=$(pid_activo) || { echo "No está corriendo."; return 0; }
    kill "$p"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$p" 2>/dev/null || { echo "Detenido (PID $p)."; return 0; }
        sleep 1
    done
    kill -9 "$p" 2>/dev/null; rm -rf "$LOCKDIR"
    echo "Forzado a cerrar (PID $p)."
}

iniciar() {
    local p
    if p=$(pid_activo); then echo "Ya está corriendo (PID $p)."; return 0; fi
    command -v termux-wake-lock >/dev/null && termux-wake-lock
    nohup bash "$MONITOR" >> "$HOME/luz.out" 2>&1 &
    sleep 2
    if p=$(pid_activo); then echo "Iniciado (PID $p)."; else echo "No arrancó. Mira: tail ~/luz.out ~/luz.log"; fi
}

case "$1" in
    estado)
        if p=$(pid_activo); then echo "CORRIENDO (PID $p)"; else echo "DETENIDO"; fi
        [ -f "$HOME/.luz.estado" ] && echo "Hay un corte registrado en curso (~/.luz.estado)."
        echo "--- últimas líneas del log ---"; tail -n 5 "$LOG" 2>/dev/null ;;
    log)      tail -n "${2:-40}" "$LOG" ;;
    seguir)   tail -f "$LOG" ;;
    detener)  detener ;;
    iniciar)  iniciar ;;
    reiniciar) detener; iniciar ;;
    *) echo "Uso: bash ~/luz-ctl.sh {estado|log [N]|seguir|detener|iniciar|reiniciar}"; exit 1 ;;
esac
