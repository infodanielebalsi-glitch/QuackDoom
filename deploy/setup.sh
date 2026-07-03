#!/usr/bin/env bash
# Setup end-to-end su Debian 12 minimal per LAN Game Hub (Doom + Quake3).
# Idempotente: rieseguibile in sicurezza per aggiornare/ri-buildare.
#
# Uso: sudo ./deploy/setup.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/common.sh"

INSTALL_DIR="${INSTALL_DIR:-/opt/lan-game-hub}"
WEB_DIR="$INSTALL_DIR/web"
BUILD_DIR="$INSTALL_DIR/build"
GAME_USER="${GAME_USER:-gamehub}"
EMSDK_VERSION="${EMSDK_VERSION:-latest}"
# Elenco (comma-separated) di game id per cui NON eseguire games/<id>/build.sh,
# utile se hai copiato a mano dei WASM/asset custom in web/games/<id>/ (es.
# via WinSCP) e non vuoi che vengano sovrascritti dalla build automatica.
# Esempio: SKIP_BUILD=doom,quake3 sudo -E ./deploy/setup.sh
SKIP_BUILD="${SKIP_BUILD:-}"

if [ "$(id -u)" -ne 0 ]; then
    log "Questo script va eseguito come root (sudo ./deploy/setup.sh)."
    exit 1
fi

log "== 1/7: pacchetti di sistema =="
apt-get update
apt-get install -y --no-install-recommends \
    git curl unzip rsync build-essential python3 python3-venv python3-pip \
    nginx nodejs npm ca-certificates \
    automake autoconf libtool pkg-config

log "== 2/7: utente di servizio non privilegiato =="
if ! id "$GAME_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "$GAME_USER"
fi

mkdir -p "$INSTALL_DIR" "$WEB_DIR" "$BUILD_DIR" /etc/lan-game-hub
chown -R "$GAME_USER":"$GAME_USER" "$INSTALL_DIR"

log "== 3/7: Emscripten SDK (condiviso da tutti i giochi che ne hanno bisogno) =="
EMSDK_DIR="$BUILD_DIR/emsdk"
if [ ! -d "$EMSDK_DIR" ]; then
    sudo -u "$GAME_USER" git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
fi
sudo -u "$GAME_USER" bash -c "
    cd '$EMSDK_DIR' &&
    ./emsdk install $EMSDK_VERSION &&
    ./emsdk activate $EMSDK_VERSION
"
# shellcheck disable=SC1091
source "$EMSDK_DIR/emsdk_env.sh"

log "== 4/7: copio il codice della repo in $INSTALL_DIR =="
rsync -a --delete \
    --exclude '.git' --exclude 'build' --exclude 'web' \
    "$REPO_DIR"/ "$INSTALL_DIR"/repo/
chown -R "$GAME_USER":"$GAME_USER" "$INSTALL_DIR/repo"

log "== 5/7: build di ogni gioco (games/*/build.sh) + venv del relay Doom =="
GAMES_JSON="$WEB_DIR/games.json"
echo "[" > "$GAMES_JSON.tmp"
first=true
for game_dir in "$INSTALL_DIR"/repo/games/*/; do
    game_id="$(basename "$game_dir")"
    game_json="$game_dir/game.json"
    [ -f "$game_json" ] || continue

    log "--- gioco: $game_id ---"
    dest_web="$WEB_DIR/games/$game_id"
    if echo ",$SKIP_BUILD," | grep -q ",$game_id,"; then
        log "[$game_id] SKIP_BUILD attivo: non eseguo build.sh, uso quanto gia' presente in $dest_web"
        mkdir -p "$dest_web"
        chown -R "$GAME_USER":"$GAME_USER" "$dest_web"
    elif [ -f "$game_dir/build.sh" ]; then
        if [ ! -x "$game_dir/build.sh" ]; then
            log "[$game_id] ATTENZIONE: build.sh non ha il bit eseguibile, lo eseguo comunque con bash"
        fi
        # sudo -u sanitizza il PATH per default (secure_path): senza
        # passarlo esplicitamente qui, emcc/emmake (aggiunti al PATH da
        # emsdk_env.sh sourcato sopra, nella shell di root) sparirebbero
        # per il processo lanciato come $GAME_USER.
        sudo -u "$GAME_USER" env PATH="$PATH" EMSDK_QUAKE="$(command -v emcc)" \
            bash "$game_dir/build.sh" "$BUILD_DIR" "$dest_web"
    else
        log "[$game_id] ATTENZIONE: nessun build.sh trovato, skip"
    fi

    if $first; then first=false; else echo "," >> "$GAMES_JSON.tmp"; fi
    cat "$game_json" | python3 -c "
import json, sys
g = json.load(sys.stdin)
print(json.dumps({
    'name': g['name'],
    'description': g['description'],
    'max_players': g['max_players'],
    'web_path': g['web_path'],
}))
" >> "$GAMES_JSON.tmp"
done
echo "]" >> "$GAMES_JSON.tmp"
python3 -m json.tool "$GAMES_JSON.tmp" > "$GAMES_JSON"
rm -f "$GAMES_JSON.tmp"

log "== 6/7: relay Doom (venv Python) =="
DOOM_RELAY_DIR="$INSTALL_DIR/games/doom/relay"
mkdir -p "$DOOM_RELAY_DIR"
rsync -a --delete "$INSTALL_DIR/repo/games/doom/relay/" "$DOOM_RELAY_DIR/"
sudo -u "$GAME_USER" python3 -m venv "$DOOM_RELAY_DIR/venv"
sudo -u "$GAME_USER" "$DOOM_RELAY_DIR/venv/bin/pip" install --quiet -r "$DOOM_RELAY_DIR/requirements.txt"

QUAKE3_SERVER_SRC="$INSTALL_DIR/repo/games/quake3/server"
mkdir -p "$INSTALL_DIR/games/quake3/server"
rsync -a --delete "$QUAKE3_SERVER_SRC/" "$INSTALL_DIR/games/quake3/server/"
chmod +x "$INSTALL_DIR/games/quake3/server/start.sh"
chown -R "$GAME_USER":"$GAME_USER" "$INSTALL_DIR/games"

cp "$INSTALL_DIR/repo/hub/index.html" "$WEB_DIR/index.html"
chown -R "$GAME_USER":"$GAME_USER" "$WEB_DIR"

log "== 7/7: systemd + nginx =="
cp "$REPO_DIR"/deploy/systemd/*.service "$REPO_DIR"/deploy/systemd/*.target /etc/systemd/system/
[ -f /etc/lan-game-hub/doom-relay.env ] || cat > /etc/lan-game-hub/doom-relay.env <<'EOF'
# Codice lobby condiviso, vuoto = nessuna protezione (LAN gia' isolata).
DOOM_LOBBY_CODE=
DOOM_MAX_PLAYERS=4
DOOM_RELAY_PORT=8771
EOF
[ -f /etc/lan-game-hub/quake3-server.env ] || cat > /etc/lan-game-hub/quake3-server.env <<'EOF'
QUAKE3_WS_PORT=27960
QUAKE3_MAX_PLAYERS=16
QUAKE3_HOSTNAME=Doom/Quake LAN Office
QUAKE3_MAP=oa_dm1
EOF

mkdir -p /etc/nginx/lan-game-hub.d
cp "$REPO_DIR/deploy/nginx/doom.locations.conf" /etc/nginx/lan-game-hub.d/doom.conf
cp "$REPO_DIR/deploy/nginx/quake3.locations.conf" /etc/nginx/lan-game-hub.d/quake3.conf
cp "$REPO_DIR/deploy/nginx/nginx.conf" /etc/nginx/sites-available/lan-game-hub
ln -sf /etc/nginx/sites-available/lan-game-hub /etc/nginx/sites-enabled/lan-game-hub
rm -f /etc/nginx/sites-enabled/default
nginx -t

systemctl daemon-reload
systemctl enable doom-relay.service quake3-server.service
systemctl restart doom-relay.service quake3-server.service
# "enable --now" e' un no-op se nginx era gia' attivo (es. avviato dal
# pacchetto all'installazione, prima ancora che questa config esistesse):
# serve un reload esplicito per far leggere la nuova config in ogni caso.
systemctl enable nginx
systemctl reload-or-restart nginx

log ""
log "Setup completato."
log "IP della VM: $(hostname -I | awk '{print $1}')"
log "Apri http://<IP-VM>/ dal browser di un collega sulla stessa LAN."
