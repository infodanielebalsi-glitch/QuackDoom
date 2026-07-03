#!/usr/bin/env bash
# Builda client (WASM, via Emscripten) e server dedicato (Node.js, ioq3
# patchato con supporto WebSocket) di QuakeJS (inolen/quakejs, submodule
# ioq3). Usa gli asset liberi di OpenArena come contenuto di default,
# perche' Quake III Arena originale (pak0.pk3) e' materiale coperto da
# copyright e NON viene scaricato ne' incluso da questo script.
#
# Uso: games/quake3/build.sh <build_dir> <web_root>/games/quake3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../scripts/common.sh"

BUILD_DIR="${1:?uso: build.sh <build_dir> <dest_web_dir>}"
DEST_DIR="${2:?uso: build.sh <build_dir> <dest_web_dir>}"

QUAKEJS_REPO="${QUAKEJS_REPO:-https://github.com/inolen/quakejs.git}"
QUAKEJS_REF="${QUAKEJS_REF:-master}"
OPENARENA_VERSION="${OPENARENA_VERSION:-0.8.8}"
OPENARENA_URL="${OPENARENA_URL:-https://sourceforge.net/projects/openarena/files/openarena-${OPENARENA_VERSION}/openarena-${OPENARENA_VERSION}.zip/download}"

log "== [quake3] build client + server =="

SRC_DIR="$BUILD_DIR/quakejs"
if [ ! -d "$SRC_DIR" ]; then
    log "[quake3] clono quakejs ($QUAKEJS_REF) con submodule ioq3"
    git clone --branch "$QUAKEJS_REF" "$QUAKEJS_REPO" "$SRC_DIR"
    (cd "$SRC_DIR" && git submodule update --init --recursive)
else
    log "[quake3] quakejs gia' presente, skip clone (rimuovi $SRC_DIR per rifare da zero)"
fi

require_emsdk
require_node

log "[quake3] build client WASM (ioq3, PLATFORM=js)"
(
    cd "$SRC_DIR/ioq3"
    make PLATFORM=js EMSCRIPTEN="$EMSDK_QUAKE" -j"$(nproc)"
)

log "[quake3] installo dipendenze Node.js per client web e server dedicato"
(cd "$SRC_DIR" && npm install --no-audit --no-fund)

mkdir -p "$DEST_DIR"
log "[quake3] copio gli artefatti statici del client in $DEST_DIR"
cp -r "$SRC_DIR"/ioq3/build/release-js-js/* "$DEST_DIR"/ 2>/dev/null || true
cp -r "$SRC_DIR"/html/* "$DEST_DIR"/ 2>/dev/null || true

ASSETS_DIR="$SRC_DIR/baseoa"
if [ ! -d "$ASSETS_DIR" ] || [ -z "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]; then
    log "[quake3] scarico asset liberi OpenArena $OPENARENA_VERSION"
    curl -fsSL "$OPENARENA_URL" -o "$BUILD_DIR/openarena.zip"
    mkdir -p "$BUILD_DIR/openarena-extract"
    unzip -o -q "$BUILD_DIR/openarena.zip" -d "$BUILD_DIR/openarena-extract"
    mkdir -p "$ASSETS_DIR"
    find "$BUILD_DIR/openarena-extract" -name '*.pk3' -exec cp {} "$ASSETS_DIR"/ \;
else
    log "[quake3] asset gia' presenti in $ASSETS_DIR, skip download"
fi

log "[quake3] ripacchetto asset per il client web (bin/repak.js + bin/content.js)"
(
    cd "$SRC_DIR"
    node bin/repak.js --src "$ASSETS_DIR" --dest content/baseoa || true
    node bin/content.js || true
)

log "[quake3] build completata."
log "[quake3] per usare Quake III Arena originale al posto di OpenArena,"
log "[quake3] copia manualmente pak0.pk3 (e gli altri pak ufficiali) in $ASSETS_DIR/"
log "[quake3] (non va incluso nella repo: e' materiale coperto da copyright) e ri-esegui questo script."
