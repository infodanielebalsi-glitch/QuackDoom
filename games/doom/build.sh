#!/usr/bin/env bash
# Builda il client web di Doom (cloudflare/doom-wasm) e scarica Freedoom
# come IWAD di default. Pensato per essere invocato da deploy/setup.sh,
# ma puo' anche girare da solo per rebuild/aggiornamenti.
#
# Uso: games/doom/build.sh <build_dir> <web_root>/games/doom
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../scripts/common.sh"

BUILD_DIR="${1:?uso: build.sh <build_dir> <dest_web_dir>}"
DEST_DIR="${2:?uso: build.sh <build_dir> <dest_web_dir>}"

DOOM_WASM_REPO="${DOOM_WASM_REPO:-https://github.com/cloudflare/doom-wasm.git}"
DOOM_WASM_REF="${DOOM_WASM_REF:-master}"
FREEDOOM_VERSION="${FREEDOOM_VERSION:-0.13.0}"
FREEDOOM_URL="${FREEDOOM_URL:-https://github.com/freedoom/freedoom/releases/download/v${FREEDOOM_VERSION}/freedoom-${FREEDOOM_VERSION}.zip}"

log "== [doom] build client web =="

SRC_DIR="$BUILD_DIR/doom-wasm"
if [ ! -d "$SRC_DIR" ]; then
    log "[doom] clono doom-wasm ($DOOM_WASM_REF)"
    git clone --depth 1 --branch "$DOOM_WASM_REF" "$DOOM_WASM_REPO" "$SRC_DIR"
else
    log "[doom] doom-wasm gia' presente, skip clone (rimuovi $SRC_DIR per rifare da zero)"
fi

require_emsdk

log "[doom] build con emmake/emcc"
(
    cd "$SRC_DIR"
    # Il Makefile del progetto produce i file statici sotto websockets-doom/.
    emmake make -j"$(nproc)"
)

mkdir -p "$DEST_DIR"
log "[doom] copio gli artefatti statici in $DEST_DIR"
cp -r "$SRC_DIR"/websockets-doom/*.html \
      "$SRC_DIR"/websockets-doom/*.js \
      "$SRC_DIR"/websockets-doom/*.wasm \
      "$DEST_DIR"/ 2>/dev/null || true

IWAD_DIR="$DEST_DIR"
if [ ! -f "$IWAD_DIR/freedoom1.wad" ] && [ ! -f "$IWAD_DIR/freedoom2.wad" ]; then
    log "[doom] scarico Freedoom $FREEDOOM_VERSION (IWAD libero, nessun copyright issue)"
    curl -fsSL "$FREEDOOM_URL" -o "$BUILD_DIR/freedoom.zip"
    unzip -j -o "$BUILD_DIR/freedoom.zip" "freedoom-${FREEDOOM_VERSION}/freedoom2.wad" -d "$IWAD_DIR"
else
    log "[doom] IWAD gia' presente in $IWAD_DIR, skip download"
fi

log "[doom] build completata. Per usare un IWAD proprietario (es. doom2.wad),"
log "[doom] copialo manualmente in $IWAD_DIR/ (vedi README.md, non va incluso nella repo)."
