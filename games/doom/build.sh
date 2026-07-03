#!/usr/bin/env bash
# Builda il client web di Doom (cloudflare/doom-wasm) e scarica Freedoom
# come IWAD di default. Pensato per essere invocato da deploy/setup.sh,
# ma puo' anche girare da solo per rebuild/aggiornamenti.
#
# Nota sul build system upstream: doom-wasm usa autotools + Emscripten
# (./scripts/build.sh nel loro repo, non un Makefile diretto), e si
# aspetta l'IWAD gia' presente in ./src con nome fisso "doom1.wad" PRIMA
# della build: viene incorporato nel bundle WASM come file precaricato
# (Module.FS.createPreloadedFile), non servito come asset separato a
# runtime. Per questo scarichiamo/rinominiamo Freedoom in doom1.wad prima
# di lanciare la build, invece di copiarlo dopo.
#
# Uso: games/doom/build.sh <build_dir> <web_root>/games/doom
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../scripts/common.sh"

BUILD_DIR="${1:?uso: build.sh <build_dir> <dest_web_dir>}"
DEST_DIR="${2:?uso: build.sh <build_dir> <dest_web_dir>}"

DOOM_WASM_REPO="${DOOM_WASM_REPO:-https://github.com/cloudflare/doom-wasm.git}"
DOOM_WASM_REF="${DOOM_WASM_REF:-main}"
FREEDOOM_VERSION="${FREEDOOM_VERSION:-0.13.0}"
FREEDOOM_URL="${FREEDOOM_URL:-https://github.com/freedoom/freedoom/releases/download/v${FREEDOOM_VERSION}/freedoom-${FREEDOOM_VERSION}.zip}"

log "== [doom] build client web =="

require_cmd automake
require_cmd autoconf
require_cmd libtoolize
require_emsdk

SRC_DIR="$BUILD_DIR/doom-wasm"
if [ ! -d "$SRC_DIR" ]; then
    log "[doom] clono doom-wasm ($DOOM_WASM_REF)"
    git clone --depth 1 --branch "$DOOM_WASM_REF" "$DOOM_WASM_REPO" "$SRC_DIR"
else
    log "[doom] doom-wasm gia' presente, skip clone (rimuovi $SRC_DIR per rifare da zero)"
fi

IWAD_TARGET="$SRC_DIR/src/doom1.wad"
if [ ! -f "$IWAD_TARGET" ]; then
    log "[doom] scarico Freedoom $FREEDOOM_VERSION (IWAD libero, nessun copyright issue)"
    curl -fsSL "$FREEDOOM_URL" -o "$BUILD_DIR/freedoom.zip"
    unzip -j -o "$BUILD_DIR/freedoom.zip" "freedoom-${FREEDOOM_VERSION}/freedoom2.wad" -d "$BUILD_DIR"
    # Nome fisso richiesto dal build system upstream (vedi nota sopra).
    mv "$BUILD_DIR/freedoom2.wad" "$IWAD_TARGET"
else
    log "[doom] IWAD gia' presente in $IWAD_TARGET, skip download"
    log "[doom] (per usare un IWAD proprietario, es. doom2.wad, sostituisci questo file"
    log "[doom]  manualmente rinominandolo in doom1.wad e ri-lancia questo script)"
fi

# configure.ac (e tests/Makefile) usano il flag Emscripten
# EXTRA_EXPORTED_RUNTIME_METHODS, rinominato in EXPORTED_RUNTIME_METHODS
# nelle versioni recenti di Emscripten (quello vecchio non e' piu'
# riconosciuto e fa fallire sia "configure" che la compilazione vera e
# propria). Patchiamo il sorgente dopo il clone.
log "[doom] patch: EXTRA_EXPORTED_RUNTIME_METHODS -> EXPORTED_RUNTIME_METHODS (rinominato in Emscripten recenti)"
sed -i 's/EXTRA_EXPORTED_RUNTIME_METHODS/EXPORTED_RUNTIME_METHODS/g' "$SRC_DIR/configure.ac"

log "[doom] build (scripts/clean.sh + scripts/build.sh upstream, via emmake/autotools)"
(
    cd "$SRC_DIR"
    # Il configure.ac di questo progetto e' vecchio stile (autoconf
    # classico) e il codice C di Chocolate Doom fa uso di dichiarazioni
    # implicite di funzione (stile C89). I Clang recenti usati da
    # Emscripten moderni trattano questo come ERRORE, non warning, il
    # che rompe sia il check "undeclared builtins" di configure sia
    # potenzialmente la compilazione vera e propria piu' avanti. Si
    # forza il comportamento storico (solo warning) per compatibilita'.
    export CFLAGS="${CFLAGS:-} -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration"
    export CPPFLAGS="${CPPFLAGS:-} -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration"
    # "make clean" fallisce al primo build (nessun Makefile ancora
    # generato): atteso, non fatale, lo script upstream non usa set -e.
    bash scripts/clean.sh || true
    bash scripts/build.sh
)

mkdir -p "$DEST_DIR"
log "[doom] copio gli artefatti statici in $DEST_DIR"
cp "$SRC_DIR"/src/*.html "$SRC_DIR"/src/*.js "$SRC_DIR"/src/*.wasm "$DEST_DIR"/ 2>/dev/null || true
cp "$SRC_DIR"/src/*.data "$DEST_DIR"/ 2>/dev/null || true
cp "$SRC_DIR"/src/favicon.ico "$DEST_DIR"/ 2>/dev/null || true

log "[doom] build completata."
