#!/usr/bin/env bash
# Avvia il server dedicato ioq3 (via Node.js) con supporto WebSocket,
# usato dal servizio systemd quake3-server.service. Legge la
# configurazione da variabili d'ambiente (nessun default hardcoded
# sensibile, solo valori sensati per uso LAN interna).
set -euo pipefail

QUAKEJS_DIR="${QUAKEJS_DIR:?QUAKEJS_DIR non impostata (path della build quakejs)}"
QUAKE3_WS_PORT="${QUAKE3_WS_PORT:-27960}"
QUAKE3_MAX_PLAYERS="${QUAKE3_MAX_PLAYERS:-16}"
QUAKE3_HOSTNAME="${QUAKE3_HOSTNAME:-Doom/Quake LAN Office}"
QUAKE3_MAP="${QUAKE3_MAP:-oa_dm1}"

cd "$QUAKEJS_DIR"

exec node build/ioq3ded.js \
    +set fs_game baseoa \
    +set dedicated 1 \
    +set net_port "$QUAKE3_WS_PORT" \
    +set sv_maxclients "$QUAKE3_MAX_PLAYERS" \
    +set sv_hostname "$QUAKE3_HOSTNAME" \
    +map "$QUAKE3_MAP"
