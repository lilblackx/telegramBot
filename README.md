# Monitor de luz por Telegram (Termux)

Bot de Telegram que avisa cuando se va la electricidad en casa y cuando vuelve. Corre completo dentro de un teléfono Android viejo (sin root) que queda enchufado 24/7 al cargador. La batería del teléfono hace de respaldo y los datos móviles mantienen la conexión aunque el router se apague.

## Cómo funciona

- Cada 5 s lee `termux-battery-status`. Si el campo `plugged` es `UNPLUGGED`, no hay luz; cualquier otro valor (`PLUGGED_AC`, `PLUGGED_USB`, `PLUGGED_WIRELESS`) cuenta como luz.
- Antirrebote: al detectar un cambio espera 10 s y vuelve a comprobar, para filtrar microcortes. Aplica tanto al corte como al regreso.
- Avisa con hora y porcentaje de batería. Al volver la luz informa la duración del corte.
- Reintenta el envío hasta 12 veces (cada 10 s) y verifica `"ok":true` en la respuesta de Telegram.
- Si el teléfono o el script se reinician durante un corte, lo avisa y conserva el inicio real del corte.
- Alerta de batería baja (15 % por defecto), una sola vez por corte.
- Comandos del bot: `/estado` y `/ayuda`. Solo responde a tu chat.
- Aviso de pérdida de internet: "🌐 Estuve sin internet X min".
- Heartbeat opcional con [Healthchecks.io](https://healthchecks.io) para enterarte si el teléfono se apaga del todo.

## Requisitos

- Android con **Termux**, **Termux:API** y **Termux:Boot**, instalados desde [F-Droid](https://f-droid.org) (no Play Store).
- Paquetes: `termux-api` y `curl`. No se necesita nada más.
- Un bot creado con [@BotFather](https://t.me/BotFather).

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `luz-setup.sh` | Configuración inicial: pide el token, obtiene el chat ID, envía un mensaje de prueba y guarda todo en `~/.luz.conf` (permisos 600). |
| `luz-monitor.sh` | El monitor. |
| `luz-ctl.sh` | Control: `estado`, `log`, `seguir`, `detener`, `iniciar`, `reiniciar`. |
| `luz-boot.sh` | Arranque automático. Va en `~/.termux/boot/`. |

## Instalación

1. Instala Termux, Termux:API y Termux:Boot desde F-Droid. Abre Termux:Boot y Termux:API una vez.
2. En Termux:
   ```bash
   pkg update -y && pkg upgrade -y
   pkg install -y termux-api curl
   termux-battery-status        # debe mostrar un JSON con "plugged"
   ```
3. Copia los 4 scripts al teléfono (por ejemplo a Descargas) y, en Termux:
   ```bash
   termux-setup-storage
   cp ~/storage/downloads/luz-*.sh ~/
   chmod +x ~/luz-*.sh
   mkdir -p ~/.termux/boot
   mv ~/luz-boot.sh ~/.termux/boot/luz-boot.sh
   ```
4. Configura el bot (escríbele "hola" cuando lo pida):
   ```bash
   bash ~/luz-setup.sh
   ```
5. Haz los ajustes de Android (más abajo) e inicia el monitor:
   ```bash
   bash ~/luz-ctl.sh iniciar
   ```

El token nunca se guarda en los scripts. Vive solo en `~/.luz.conf`.

## Uso

```bash
bash ~/luz-ctl.sh estado      # ¿está corriendo?
bash ~/luz-ctl.sh log 50      # últimas 50 líneas del log
bash ~/luz-ctl.sh seguir      # log en vivo
bash ~/luz-ctl.sh detener
bash ~/luz-ctl.sh iniciar     # no duplica la instancia
bash ~/luz-ctl.sh reiniciar
```

Log en `~/luz.log` (rota a `luz.log.1` al pasar de 256 KB).

## Configuración

Las variables están al inicio de `luz-monitor.sh`:

| Variable | Defecto | Descripción |
|---|---|---|
| `INTERVALO` | 5 | Segundos entre lecturas |
| `ANTIREBOTE` | 10 | Segundos de confirmación antes de avisar |
| `BATERIA_BAJA` | 15 | % para la alerta de batería baja (0 = desactivada) |
| `REINTENTOS` / `ESPERA_REINTENTO` | 12 / 10 | Reintentos de envío y espera entre ellos |
| `COMANDOS` | 1 | 1 = el bot responde `/estado` y `/ayuda` |
| `POLL_TIMEOUT` | 50 | Segundos de long-polling de `getUpdates` |
| `CHEQUEO_INTERNET` | 60 | Segundos entre chequeos de internet (0 = desactivado) |
| `INTERNET_FALLOS` | 3 | Fallos seguidos para dar internet por caído |
| `HC_CADA` | 300 | Segundos entre pings a Healthchecks |

Healthchecks (opcional): crea un check con período de 5 min y gracia de 5 min, y guarda su URL con `bash ~/luz-setup.sh hc`.

El bot de comandos y el chequeo de internet consumen datos móviles. Si el saldo es limitado, sube `POLL_TIMEOUT` y `CHEQUEO_INTERNET`, o desactívalos con `COMANDOS=0` y `CHEQUEO_INTERNET=0`.

## Ajustes de Android

1. Optimización de batería en **Sin restricciones** para Termux, Termux:API y Termux:Boot.
2. Fijar Termux en recientes.
3. Dejar activa la notificación de Termux (sostiene el wake-lock).
4. Datos móviles activos, sin ahorro de datos y sin preferir WiFi sobre datos.
5. Limitar la carga al 80 % si el teléfono lo permite.
6. Sin bloqueo de pantalla con PIN: tras un reinicio, Termux:Boot no corre hasta desbloquear.
7. Android 12 o superior: desactivar las restricciones de procesos secundarios (opción de desarrollador, o `device_config` por ADB).

## Pruebas

1. Desenchufar el cargador: debe llegar "⚡ Se fue la luz" en menos de 15 s.
2. Enchufar: debe llegar "✅ Volvió la luz" con la duración.
3. Desenchufar y enchufar en menos de 5 s: no debe llegar nada (microcorte).
4. Apagar el WiFi y repetir con datos móviles.
5. Modo avión durante un corte: los avisos deben llegar al recuperar la red.
6. Reiniciar el teléfono con el cargador conectado: debe llegar "🟢 Monitor de luz activo".
7. Reiniciar durante un corte: debe llegar el aviso de reinicio durante el corte.
8. Escribir `/estado` al bot.

## Solución de problemas

- **El proceso muere tras horas:** revisar los ajustes de batería y el wake-lock. En Android 12 o superior puede ser el "phantom process killer".
- **`termux-battery-status` vacío o colgado:** abrir Termux:API una vez, quitarle restricciones de batería y comprobar que todo viene de F-Droid. El monitor ya usa `timeout` y avisa tras 5 min de fallos.
- **No llegan mensajes:** probar `. ~/.luz.conf && curl -s "https://api.telegram.org/bot$TOKEN/getMe"`. Revisar `~/luz.log`. Si el chat ID es incorrecto, repetir `luz-setup.sh`.
- **El aviso depende del WiFi del router:** dejar solo datos móviles en el teléfono.
- **Hora incorrecta:** descomentar `export TZ="America/Caracas"` en `luz-monitor.sh`.

## Limitaciones

- Si el teléfono se apaga o se queda sin batería, no puede avisar. Para ese caso sirve el heartbeat de Healthchecks.
- Si el envío falla las 12 veces, el mensaje se descarta y queda en el log como `MENSAJE PERDIDO`.
- Sin datos móviles ni WiFi, no hay avisos.
