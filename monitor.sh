#!/bin/bash

# ============================================================
# monitor.sh — Lab 5: Monitor profesional con Telegram
# ============================================================

# ----- Configuración -----
UMBRAL_DISCO=90
UMBRAL_RAM=80
UMBRAL_CPU=80

INTERVALO=5
LOG_BASE="${LOG_BASE:-/var/log/monitor_recursos}"
MAX_LOGS=7
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

export LC_ALL=C

# ----- Estado (máquina de estados para no spamear) -----
ESTADO_DISCO="OK"
ESTADO_RAM="OK"
ESTADO_CPU="OK"

# ============================================================
# FUNCIÓN: cargar_env
# ============================================================
cargar_env() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "? No se encontró .env en: $ENV_FILE"
        return 1
    fi
    while IFS='=' read -r clave valor || [ -n "$clave" ]; do
        [[ "$clave" =~ ^[[:space:]]*# || -z "$clave" ]] && continue
        valor="${valor%\"}"; valor="${valor#\"}"
        valor="${valor%\'}"; valor="${valor#\'}"
        export "$clave=$valor"
    done < "$ENV_FILE"
    return 0
}

# ============================================================
# FUNCIÓN: log
# ============================================================
log() {
    local FECHA_HORA
    FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')
    local LOG_HOY="${LOG_BASE}_$(date '+%Y-%m-%d').log"
    echo "[${FECHA_HORA}] $1" | tee -a "$LOG_HOY"
}

# ============================================================
# FUNCIÓN: rotar_logs
# ============================================================
rotar_logs() {
    find "$(dirname "$LOG_BASE")" -name "$(basename "$LOG_BASE")_*.log" \
         -mtime +${MAX_LOGS} -delete
    log "Rotación de logs: eliminados registros con más de ${MAX_LOGS} días."
}

# ============================================================
# FUNCIÓN: enviar_telegram
# ============================================================
enviar_telegram() {
    local mensaje="$1"

    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        log "? Sin credenciales de Telegram. Alerta solo en log."
        return 0
    fi

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    if ! curl -s --max-time 10 -X POST "$url" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        --data-urlencode "text=${mensaje}" > /dev/null; then
        log "? Fallo enviando alerta a Telegram."
        return 1
    fi
}

# ============================================================
# FUNCIÓN: limpiar_tmp
# ============================================================
limpiar_tmp() {
    find /tmp -type f -atime +2 -delete 2>/dev/null
    log "?? Limpieza de /tmp completada."
}

# ============================================================
# FUNCIÓN: limpiar_logs
# ============================================================
limpiar_logs() {
    find /var/log -type f -name "*.log" -mtime +30 -delete 2>/dev/null
    log "?? Limpieza de logs del sistema completada."
}

# ============================================================
# FUNCIÓN: revisar_disco
# ============================================================
revisar_disco() {
    local USO USO_FINAL mensaje
    USO=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')
    log "?? Disco: uso ${USO}%"
    USO_FINAL=$USO

    if [ "$USO" -gt "$UMBRAL_DISCO" ]; then
        log "??  Disco supera el ${UMBRAL_DISCO}%. Iniciando limpieza..."
        limpiar_tmp
        limpiar_logs
        USO_FINAL=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')
        log "? Limpieza completada. Uso de disco: ${USO_FINAL}%"
    fi

    if [ "$USO_FINAL" -gt "$UMBRAL_DISCO" ] && [ "$ESTADO_DISCO" = "OK" ]; then
        mensaje=$(cat <<EOF
*?? ALERTA DISCO en $(hostname)*
Uso: *${USO_FINAL}%* (umbral ${UMBRAL_DISCO}%)
La limpieza automática no fue suficiente.
EOF
)
        enviar_telegram "$mensaje"
        ESTADO_DISCO="ALERTA"

    elif [ "$USO_FINAL" -le "$UMBRAL_DISCO" ] && [ "$ESTADO_DISCO" = "ALERTA" ]; then
        enviar_telegram "? *Disco recuperado en $(hostname)*: ${USO_FINAL}%"
        ESTADO_DISCO="OK"
    fi
}

# ============================================================
# FUNCIÓN: revisar_ram
# ============================================================
revisar_ram() {
    local USO procesos mensaje
    USO=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')
    log "?? RAM: uso ${USO}%"

    if [ "$USO" -gt "$UMBRAL_RAM" ]; then
        procesos=$(ps -eo pid,comm,%mem --sort=-%mem | head -n 6)
        log "??  RAM supera el ${UMBRAL_RAM}%. Top procesos por memoria:"
        echo "$procesos" | tail -n 5 | while read -r linea; do log "    $linea"; done

        if [ "$ESTADO_RAM" = "OK" ]; then
            mensaje=$(cat <<EOF
*?? ALERTA RAM en $(hostname)*
Uso: *${USO}%* (umbral ${UMBRAL_RAM}%)

\`\`\`
${procesos}
\`\`\`
EOF
)
            enviar_telegram "$mensaje"
            ESTADO_RAM="ALERTA"
        fi

    else
        if [ "$ESTADO_RAM" = "ALERTA" ]; then
            enviar_telegram "? *RAM recuperada en $(hostname)*: ${USO}%"
            ESTADO_RAM="OK"
        fi
    fi
}

# ============================================================
# FUNCIÓN: revisar_cpu
# ============================================================
revisar_cpu() {
    local USO procesos mensaje
    USO=$(top -bn1 | awk '/Cpu\(s\)/ {print 100 - $8}' | cut -d. -f1)
    log "??  CPU: uso ${USO}%"

    if [ "$USO" -gt "$UMBRAL_CPU" ]; then
        procesos=$(ps -eo pid,comm,%cpu --sort=-%cpu | head -n 6)
        log "??  CPU supera el ${UMBRAL_CPU}%. Top procesos por CPU:"
        echo "$procesos" | tail -n 5 | while read -r linea; do log "    $linea"; done

        if [ "$ESTADO_CPU" = "OK" ]; then
            mensaje=$(cat <<EOF
*?? ALERTA CPU en $(hostname)*
Uso: *${USO}%* (umbral ${UMBRAL_CPU}%)

\`\`\`
${procesos}
\`\`\`
EOF
)
            enviar_telegram "$mensaje"
            ESTADO_CPU="ALERTA"
        fi

    else
        if [ "$ESTADO_CPU" = "ALERTA" ]; then
            enviar_telegram "? *CPU recuperada en $(hostname)*: ${USO}%"
            ESTADO_CPU="OK"
        fi
    fi
}

# ============================================================
# SEÑALES
# ============================================================
trap 'log "?? Monitor detenido (señal recibida). PID: $$"; exit 0' SIGINT SIGTERM

# ============================================================
# ARRANQUE
# ============================================================
cargar_env
log "?? Monitor iniciado. PID: $$"
enviar_telegram "?? *Monitor iniciado en $(hostname)*
Umbrales ? Disco: ${UMBRAL_DISCO}% | RAM: ${UMBRAL_RAM}% | CPU: ${UMBRAL_CPU}%"

# ============================================================
# MODO ONCE vs LOOP
# ============================================================
if [ "${MODO:-loop}" = "once" ]; then
    log "Modo: ejecución única (MODO=once)"
    revisar_disco
    revisar_ram
    revisar_cpu
    log "? Chequeo único completado. Saliendo."
    exit 0
fi

# ============================================================
# LOOP PRINCIPAL
# ============================================================
ULTIMO_DIA=$(date '+%Y-%m-%d')

while true; do
    DIA_ACTUAL=$(date '+%Y-%m-%d')
    if [ "$DIA_ACTUAL" != "$ULTIMO_DIA" ]; then
        log "?? Nuevo día detectado. Ejecutando rotación de logs..."
        rotar_logs
        ULTIMO_DIA="$DIA_ACTUAL"
    fi

    revisar_disco
    revisar_ram
    revisar_cpu

    log "? Próxima revisión en ${INTERVALO} segundos."
    log "--------------------------------------------"
    sleep "$INTERVALO"
done
