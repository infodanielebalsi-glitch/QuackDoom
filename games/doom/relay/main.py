"""
Relay WebSocket per Doom multiplayer (protocollo cloudflare/doom-wasm).

Architettura e scelte:

- Il netcode di Chocolate Doom (compilato in WASM da doom-wasm) e' un
  lockstep classico "peer-to-peer via server": ogni peer manda i suoi input
  a TUTTI gli altri peer, indirizzando ogni pacchetto a un singolo
  destinatario per volta tramite un piccolo header applicativo. Questo
  relay si limita a fare da router UDP-over-WebSocket tra le sessioni di
  una stessa lobby, senza mai interpretare il payload di gioco.

- Framing:
    client -> router (8 byte header + payload doom):
        uint32 LE  to    (instanceUID destinatario, 0 = broadcast "hello")
        uint32 LE  from  (instanceUID mittente)
        bytes      payload
    router -> client (4 byte header + payload doom):
        uint32 LE  from  (instanceUID del mittente originale)
        bytes      payload

- L'host della partita usa sempre instanceUID = 1 (convenzione doom-wasm).
  I client si connettono con `-connect 1` e generano un UID random (>1) sul
  lato JS prima di aprire la websocket.

- Routing: unicast puro in base al campo `to`, verso la sessione
  registrata in memoria con quell'UID, all'interno della stessa lobby
  (`lobby_id` preso dal path). Nessun instradamento cross-lobby.

- Messaggio speciale from==1 && to==0: e' l'"hello" che l'host manda
  all'avvio/riavvio di una partita. Convenzionalmente significa "nuova
  partita in corso", quindi il relay ne approfitta per ripulire lo stato
  della lobby (disconnette tutte le sessioni tranne l'host mittente),
  cosi' eventuali client rimasti agganciati a una partita precedente non
  restano zombie.

- Limite 8 giocatori: e' un limite di configurazione del relay (default
  DOOM_MAX_PLAYERS=8), scelto per l'uso in ufficio. Le connessioni oltre
  l'ottava in una stessa lobby vengono rifiutate con close code 1013
  ("try again later" / overload).

- Stato in memoria di processo: non c'e' alcun database ne' storage
  esterno. Tutte le lobby e le sessioni vivono in un dict Python dentro il
  processo uvicorn. Per questo motivo il servizio DEVE girare con
  `--workers 1`: se uvicorn/gunicorn creassero piu' worker process, host e
  client potrebbero finire su worker diversi che non condividono memoria e
  quindi non si vedrebbero mai. Non e' un limite tecnico grave: il relay
  fa pochissimo lavoro (routing di pacchetti piccoli e poco frequenti,
  ~35 tick/s per player), un solo processo regge tranquillamente 8 giocatori
  su una LAN d'ufficio.

- Autenticazione: nessuna dipendenza da sistemi esterni (niente OAuth,
  niente DB utenti). Protezione opzionale e leggera via "codice lobby"
  condiviso, passato come query string (`?code=...`) e confrontato con la
  variabile d'ambiente DOOM_LOBBY_CODE. Se la variabile e' vuota (default),
  non viene richiesto alcun codice: e' pensato per una LAN gia' isolata
  dove l'obiettivo e' solo evitare che qualcuno si unisca alla lobby
  sbagliata per errore, non per sicurezza vera e propria.
"""

import asyncio
import logging
import os
import struct
from dataclasses import dataclass, field

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from starlette.websockets import WebSocketState

logging.basicConfig(
    level=os.environ.get("DOOM_RELAY_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("doom-relay")

# --- Configurazione via variabili d'ambiente (nessun segreto hardcoded) ---

LOBBY_CODE = os.environ.get("DOOM_LOBBY_CODE", "")
MAX_PLAYERS_PER_LOBBY = int(os.environ.get("DOOM_MAX_PLAYERS", "8"))

HOST_UID = 1
HELLO_TO = 0

CLIENT_HEADER = struct.Struct("<II")  # to, from
SERVER_HEADER = struct.Struct("<I")  # from

# Close code 1013 = "Try Again Later" (RFC 6455), usato per lobby piena.
CLOSE_LOBBY_FULL = 1013
CLOSE_BAD_CODE = 4401  # codice custom (range privato) per lobby-code errato


@dataclass
class Lobby:
    sessions: dict[int, WebSocket] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


app = FastAPI(title="doom-relay")

# lobby_id -> Lobby
_lobbies: dict[str, Lobby] = {}
_lobbies_guard = asyncio.Lock()


async def _get_lobby(lobby_id: str) -> Lobby:
    async with _lobbies_guard:
        lobby = _lobbies.get(lobby_id)
        if lobby is None:
            lobby = Lobby()
            _lobbies[lobby_id] = lobby
        return lobby


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "lobbies": {
            lobby_id: list(lobby.sessions.keys())
            for lobby_id, lobby in _lobbies.items()
        },
    }


@app.websocket("/ws/doom/lobby/{lobby_id}")
async def doom_ws(websocket: WebSocket, lobby_id: str, code: str = Query(default="")):
    if LOBBY_CODE and code != LOBBY_CODE:
        await websocket.close(code=CLOSE_BAD_CODE, reason="invalid lobby code")
        return

    lobby = await _get_lobby(lobby_id)

    await websocket.accept()

    uid: int | None = None
    try:
        async with lobby.lock:
            if len(lobby.sessions) >= MAX_PLAYERS_PER_LOBBY:
                await websocket.close(
                    code=CLOSE_LOBBY_FULL, reason="lobby full (max players reached)"
                )
                return

            # Prima decodifichiamo un pacchetto per scoprire l'UID del
            # mittente, cosi' registriamo la sessione con la chiave giusta.
            # doom-wasm manda subito l'hello/primo pacchetto di input dopo
            # la connect, quindi aspettiamo qui prima di registrare.

        first_message = await websocket.receive_bytes()
        if len(first_message) < CLIENT_HEADER.size:
            await websocket.close(code=1002, reason="malformed packet")
            return

        to_uid, from_uid = CLIENT_HEADER.unpack_from(first_message, 0)
        uid = from_uid

        async with lobby.lock:
            if uid in lobby.sessions:
                await websocket.close(code=1008, reason="duplicate instance uid")
                return
            if len(lobby.sessions) >= MAX_PLAYERS_PER_LOBBY:
                await websocket.close(
                    code=CLOSE_LOBBY_FULL, reason="lobby full (max players reached)"
                )
                return
            lobby.sessions[uid] = websocket
            log.info("lobby=%s uid=%s joined (%d/%d players)",
                      lobby_id, uid, len(lobby.sessions), MAX_PLAYERS_PER_LOBBY)

        await _route_packet(lobby, lobby_id, to_uid, from_uid, first_message)

        while True:
            message = await websocket.receive_bytes()
            if len(message) < CLIENT_HEADER.size:
                continue
            to_uid, from_uid = CLIENT_HEADER.unpack_from(message, 0)
            await _route_packet(lobby, lobby_id, to_uid, from_uid, message)

    except WebSocketDisconnect:
        pass
    finally:
        if uid is not None:
            async with lobby.lock:
                if lobby.sessions.get(uid) is websocket:
                    del lobby.sessions[uid]
            log.info("lobby=%s uid=%s left", lobby_id, uid)
        async with _lobbies_guard:
            if lobby_id in _lobbies and not _lobbies[lobby_id].sessions:
                del _lobbies[lobby_id]


async def _route_packet(
    lobby: Lobby, lobby_id: str, to_uid: int, from_uid: int, message: bytes
) -> None:
    payload = message[CLIENT_HEADER.size:]

    if from_uid == HOST_UID and to_uid == HELLO_TO:
        # Hello dell'host = (ri)avvio partita: azzera la lobby tranne
        # il mittente, cosi' eventuali client di una partita precedente
        # non restano agganciati.
        async with lobby.lock:
            stale = [u for u in lobby.sessions if u != from_uid]
            stale_sockets = [lobby.sessions.pop(u) for u in stale]
        for u, ws in zip(stale, stale_sockets):
            log.info("lobby=%s uid=%s reset by host hello", lobby_id, u)
            await _safe_close(ws, code=1000, reason="game restarted by host")
        return

    async with lobby.lock:
        dest = lobby.sessions.get(to_uid)

    if dest is None:
        return  # destinatario non (ancora) connesso: pacchetto perso, ok per lockstep UDP-like

    out = SERVER_HEADER.pack(from_uid) + payload
    try:
        await dest.send_bytes(out)
    except Exception:
        log.warning("lobby=%s failed to deliver to uid=%s", lobby_id, to_uid)


async def _safe_close(ws: WebSocket, code: int, reason: str) -> None:
    try:
        if ws.client_state == WebSocketState.CONNECTED:
            await ws.close(code=code, reason=reason)
    except Exception:
        pass
