# Monitor de luz por Telegram (Termux)

Bot de Telegram que avisa cuando se va la electricidad en casa y cuando vuelve. Corre completo dentro de un teléfono Android viejo (sin root) que queda enchufado 24/7 al cargador. La batería del teléfono hace de respaldo y los datos móviles mantienen la conexión aunque el router se apague.

## Cómo funciona

- Cada 5 s lee `termux-battery-status`. Si el campo `plugged` es `UNPLUGGED`, no hay luz; cualquier otro valor (`PLUGGED_AC`, `PLUGGED_USB`, `PLUGGED_WIRELESS`) cuenta como luz.
- Antirrebote: al detectar un cambio espera 10 s y vuelve a comprobar, para filtrar microcortes. Aplica tanto al corte como al regreso.
- Avisa con hora y porcentaje de batería. Al volver la luz informa la duración del corte.
- Reintenta el envío hasta 12 veces (cada 10 s) y verifica `"ok":true` en la respuesta de Telegram.
- Si el teléfono o el script se reinician durante un corte, lo avisa y conserva el inicio real del corte.
- Alerta de batería baja (15 % por defecto), una sola vez por corte.
- Varios usuarios: el chat configurado en `luz-setup.sh` es el **administrador**; puede autorizar a más personas (ver "Varios usuarios").
- Historial de cortes (`/historial`) con fecha, duración y tiempo total acumulado.
- Comandos del bot: `/estado`, `/historial` y `/ayuda`. Solo responde a chats autorizados.
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

## Varios usuarios

Requiere `COMANDOS=1` (por defecto). Cualquier persona puede usar el bot, pero solo si el administrador la aprueba:

1. La persona abre tu bot en Telegram y pulsa **Iniciar** (`/start`). Recibe su ID y el aviso de que su solicitud fue enviada.
2. Al administrador le llega "🔔 Solicitud de acceso" con nombre e ID.
3. El administrador responde `/agregar ID`. La persona recibe confirmación y el estado actual.

Comandos solo del administrador:

| Comando | Qué hace |
|---|---|
| `/pausa [duración]` | Pausa los avisos de cortes nuevos (ver "Pausa") |
| `/reanudar` | Quita la pausa antes de tiempo |
| `/usuarios` | Lista autorizados y solicitudes pendientes |
| `/agregar ID` (o `/aprobar ID`) | Autoriza un chat. También sirve para grupos (ID negativo): agrega el bot al grupo, pulsa `/start` allí y aprueba |
| `/quitar ID` | Revoca el acceso |

Qué recibe cada quien:

- **Todos los autorizados:** corte, regreso de la luz, batería baja, reinicio durante un corte, y los comandos `/estado`, `/historial`, `/ayuda`.
- **Solo el administrador:** aviso de arranque, pérdida de internet y fallos de lectura de batería (avisos técnicos del teléfono).

Los chats se guardan en `~/.luz.chats` y las solicitudes en `~/.luz.pend`. Si alguien bloqueó el bot, el envío a ese chat se descarta al instante sin retrasar a los demás. Los avisos se envían en paralelo.

## Pausa

Para desenchufar el teléfono a propósito (mover cosas, cambiar de cargador, mantenimiento) sin que avise a todos de un corte falso. Solo el administrador.

- `/pausa 30` (minutos), `/pausa 2h`, `/pausa 1d`. Sin duración: 60 min. Máximo 24 h.
- `/reanudar` la quita antes de tiempo.
- Durante la pausa **no se inician cortes nuevos** ni se registran en el historial.
- Al vencer te llega "▶️ La pausa terminó". Si el cargador sigue desconectado en ese momento, se avisa el corte como siempre.
- Si ya había un corte en curso al pausar, sigue vigilándose y avisa cuando vuelva la luz.
- `/estado` indica "⏸️ Monitor en pausa hasta …" mientras dure.
- La pausa se guarda en `~/.luz.pausa` y sobrevive a reinicios del script. Los demás avisos (internet, heartbeat) no se pausan.
- Una pausa no tapa un corte real: si se va la luz de verdad durante la pausa, no avisará hasta que termine. Usa pausas cortas y `/reanudar` al terminar.

## Protector de la casa

Si un protector de voltaje corta toda la casa unos minutos tras una fluctuación, el bot avisa el corte igual (la casa sí está sin luz). Al volver, un corte de hasta `PROTECTOR_MAX` segundos (420 = 7 min) se etiqueta "🛡️ probable reinicio del protector por una fluctuación", tanto en el aviso de regreso como en `/historial`, que además cuenta cuántos fueron así. Ajusta `PROTECTOR_MAX` según lo que tarde tu protector; `0` desactiva la etiqueta.

## Historial

Cada corte terminado se guarda en `~/.luz.hist` (inicio y fin). `/historial` muestra los últimos 10 y el tiempo total sin luz registrado. Se conservan los últimos 200 cortes.

## Configuración

Las variables están al inicio de `luz-monitor.sh`:

| Variable | Defecto | Descripción |
|---|---|---|
| `INTERVALO` | 5 | Segundos entre lecturas |
| `ANTIREBOTE` | 10 | Segundos de confirmación antes de avisar |
| `BATERIA_BAJA` | 15 | % para la alerta de batería baja (0 = desactivada) |
| `REINTENTOS` / `ESPERA_REINTENTO` | 12 / 10 | Reintentos de envío y espera entre ellos |
| `COMANDOS` | 1 | 1 = el bot responde comandos y solicitudes de acceso |
| `HIST_MAX` / `HIST_MOSTRAR` | 200 / 10 | Cortes guardados / cortes que muestra `/historial` |
| `PROTECTOR_MAX` | 420 | Segundos: un corte hasta esta duración se etiqueta "probable protector" (0 = desactivado) |
| `PAUSA_DEFECTO` / `PAUSA_MAX` | 60 / 1440 | Minutos de `/pausa` sin duración / máximo permitido |
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
