#!/usr/bin/env bash
# Funzioni condivise dagli script di build/deploy dei singoli giochi.
# Va "source"-ato, non eseguito direttamente.

log() {
    printf '%s\n' "$*" >&2
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERRORE: comando richiesto non trovato: $cmd"
        exit 1
    fi
}

# Emscripten SDK: ci si aspetta che deploy/setup.sh l'abbia gia' installato
# e "sourced" (emsdk_env.sh) prima di chiamare i build.sh dei singoli giochi.
require_emsdk() {
    require_cmd emcc
    require_cmd emmake
    : "${EMSDK_QUAKE:=$(command -v emcc)}"
    export EMSDK_QUAKE
}

require_node() {
    require_cmd node
    require_cmd npm
}
