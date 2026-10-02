#!/data/data/com.termux/files/usr/bin/bash
# ~/.termux/boot/luz-boot.sh - Se ejecuta solo al encender el teléfono (Termux:Boot)

termux-wake-lock                 # evita que Android duerma la CPU y mate el proceso
sleep 20                         # margen para que arranquen la red y Termux:API
nohup bash "$HOME/luz-monitor.sh" >> "$HOME/luz.out" 2>&1 &
