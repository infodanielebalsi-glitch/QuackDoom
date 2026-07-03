# LAN Game Hub — Doom & Quake III via browser

Piattaforma multiplayer per una LAN d'ufficio isolata: colleghi si collegano
dal browser (nessun client da installare) e giocano insieme su una singola
VM Debian 12 minimal. Architettura modulare: ogni gioco vive nella sua
cartella sotto `games/`, con il proprio server e la propria voce nella
pagina hub. Aggiungere un terzo gioco in futuro non richiede toccare quelli
esistenti.

> Progetto amatoriale/didattico, pensato per essere self-hosted su una
> propria LAN privata. Non è un servizio pubblico e non va esposto su
> Internet così com'è (vedi [Vincoli e note](#vincoli-e-note)). Non
> distribuisce alcun asset di gioco proprietario: usa di default IWAD/pak
> liberi (Freedoom, OpenArena); l'uso di materiale originale copyrighted
> (doom2.wad, pak0.pk3) è a discrezione e responsabilità di chi lo
> installa, e deve provenire da una copia posseduta legalmente.

## Giochi inclusi

| Gioco | Motore | Max giocatori | Note |
|---|---|---|---|
| Doom | Chocolate Doom (cloudflare/doom-wasm) | 4 | limite hardcoded del motore originale |
| Quake III Arena | ioquake3 (QuakeJS) | 16 | asset liberi OpenArena di default |

## Architettura

```
Browser colleghi
   |
   |  HTTP (file statici hub + client WASM)
   |  WS   /ws/doom/...    -> relay Doom (Python, stato in memoria)
   |  WS   /ws/quake3/...  -> server ioq3 dedicato (Node.js)
   v
+-------------------- VM Debian 12 -------------------------+
|  nginx :80                                                 |
|   ├─ /               -> hub/index.html (elenco giochi)     |
|   ├─ /games/doom/    -> client WASM Doom                   |
|   ├─ /games/quake3/  -> client WASM Quake3                 |
|   ├─ /ws/doom/       -> proxy WS -> 127.0.0.1:8771          |
|   └─ /ws/quake3/     -> proxy WS -> 127.0.0.1:27960         |
|                                                              |
|  doom-relay.service    (systemd, uvicorn --workers 1)       |
|  quake3-server.service (systemd, node ioq3ded.js)           |
+--------------------------------------------------------------+
```

- **Doom**: il client WASM parla il protocollo lockstep di doom-wasm
  (header 8/4 byte, vedi commenti in
  [games/doom/relay/main.py](games/doom/relay/main.py)). Il relay Python
  smista i pacchetti per `instanceUID`; l'host ha sempre UID 1. Girare
  sempre con un solo worker: lo stato delle lobby e' in memoria di
  processo, nessun database.
- **Quake III**: il client WASM (QuakeJS) parla WebSocket direttamente col
  server dedicato ioq3 patchato — non serve un relay custom, il networking
  client-server e' nativo del motore.

## Struttura repo

```
games/<id>/game.json     metadati del gioco (nome, max player, path web, porta server)
games/<id>/build.sh      build client (+ eventuale server) per quel gioco
games/doom/relay/        codice del relay WebSocket Doom (FastAPI)
games/quake3/server/     script di avvio del server dedicato Quake3
hub/                     landing page che elenca i giochi (letta da games.json generato al deploy)
deploy/systemd/          unit file (una per servizio di rete per-gioco)
deploy/nginx/            config nginx (file principale + locations per gioco)
deploy/setup.sh          orchestratore end-to-end per Debian 12 minimal
scripts/common.sh        funzioni condivise dai build.sh
```

## Installazione su VM Debian 12 minimal (VirtualBox, LAN ufficio)

### 1. Provisioning della VM

1. Scarica l'immagine netinst di Debian 12: https://www.debian.org/distrib/
2. Crea una VM VirtualBox: 2 vCPU, 2 GB RAM, 20 GB disco (vedi
   [specifiche consigliate](#specifiche-vm-consigliate) sotto).
3. **Rete**: imposta la scheda di rete della VM in modalita' **Bridged**
   (non NAT), agganciata alla scheda fisica connessa alla LAN d'ufficio —
   cosi' la VM ottiene un IP nella stessa subnet dei PC dei colleghi ed e'
   raggiungibile direttamente da loro.
4. Installa Debian 12 in modalita' "minimal" (deseleziona "Desktop
   environment" e "print server" nel selettore task, tieni solo "SSH
   server" e "standard system utilities").

### 2. Primo accesso e clone della repo

```bash
ssh <utente>@<ip-vm>
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/infodanielebalsi-glitch/QuackDoom.git
cd QuackDoom
```

### 3. Setup end-to-end

```bash
sudo ./deploy/setup.sh
```

Lo script (idempotente, rieseguibile per aggiornare):
- installa i pacchetti di sistema necessari (nginx, build tools, Node.js, Python);
- crea l'utente di servizio non privilegiato `gamehub`;
- installa Emscripten SDK (condiviso da entrambi i giochi);
- builda ogni gioco eseguendo `games/*/build.sh` (clona i sorgenti, compila
  in WASM, scarica gli asset liberi — Freedoom per Doom, OpenArena per
  Quake3);
- genera `hub/games.json` a partire dai `game.json` di ogni gioco;
- installa e abilita i servizi systemd (`doom-relay`, `quake3-server`) e
  la configurazione nginx.

La build (soprattutto Emscripten + compilazione WASM) puo' richiedere
diversi minuti la prima volta.

### 4. Recuperare l'IP della VM da comunicare ai colleghi

```bash
hostname -I | awk '{print $1}'
```

(lo stesso comando viene stampato anche in fondo all'output di
`deploy/setup.sh`). I colleghi aprono `http://<IP-VM>/` dal browser,
scelgono il gioco dalla hub page.

## Codice lobby (Doom)

Protezione opzionale e leggera, pensata solo per evitare che qualcuno si
unisca alla lobby sbagliata per errore — non e' pensata come sicurezza
vera e propria (la LAN e' gia' isolata).

- **Configurare un codice**: modifica `/etc/lan-game-hub/doom-relay.env`
  sulla VM:
  ```
  DOOM_LOBBY_CODE=ufficio2026
  ```
  poi `sudo systemctl restart doom-relay.service`. I client dovranno
  aggiungere `?code=ufficio2026` all'URL del gioco.
- **Disattivare**: lascia `DOOM_LOBBY_CODE=` vuoto (default) e riavvia il
  servizio.

## Sostituire gli asset liberi con quelli originali (copyright)

Nessun materiale coperto da copyright viene scaricato o incluso in questa
repo. Se possiedi legalmente le copie originali puoi sostituirle:

- **Doom**: il WAD viene incorporato nel bundle WASM in fase di build (non
  è un file separato servito a runtime). Copia `doom2.wad` (o altro IWAD
  proprietario) in `/opt/lan-game-hub/build/doom-wasm/src/`, rinominalo in
  `doom1.wad` (nome fisso richiesto dal build system upstream), poi
  ri-esegui `games/doom/build.sh` (o l'intero `deploy/setup.sh`) per
  ricompilare.
- **Quake III Arena**: copia `pak0.pk3` e gli altri pak ufficiali in
  `/opt/lan-game-hub/build/quakejs/baseoa/` (vedi commento finale di
  [games/quake3/build.sh](games/quake3/build.sh)) e ri-esegui
  `games/quake3/build.sh` per ripacchettare gli asset per il client web.

## Installare WASM/asset compilati a mano (es. via WinSCP)

Se preferisci compilare i client altrove e copiare i file gia' pronti
sulla VM (invece di far girare `games/*/build.sh` in loco), i percorsi di
destinazione serviti da nginx sono:

```
/opt/lan-game-hub/web/games/doom/     -> .html, .js, .wasm, IWAD
/opt/lan-game-hub/web/games/quake3/   -> .html, .js, .wasm
```

Dopo aver copiato i file (es. con WinSCP), sistema owner/permessi:

```bash
sudo chown -R gamehub:gamehub /opt/lan-game-hub/web
```

Per evitare che una successiva esecuzione di `deploy/setup.sh` sovrascriva
questi file con una build automatica, escludi il/i gioco/i interessato/i
con `SKIP_BUILD` (elenco comma-separated di `id` presi da `games/<id>/`):

```bash
SKIP_BUILD=doom,quake3 sudo -E ./deploy/setup.sh
```

Lo script salta `build.sh` solo per i giochi elencati; tutto il resto
(systemd, nginx, venv del relay, ecc.) viene comunque configurato
normalmente.

## Specifiche VM consigliate

| Risorsa | Valore | Perche' |
|---|---|---|
| vCPU | 2 | il relay Doom e il server Quake3 fanno solo routing/simulazione leggera di pacchetti; il rendering e la logica di gioco pesante girano nel browser di ogni client |
| RAM | 2 GB | nginx + un processo Python (relay) + un processo Node (server Quake3) hanno un footprint minimo; il grosso della RAM serve solo durante la build (compilazione WASM) |
| Disco | 20 GB | sorgenti + toolchain Emscripten + asset di gioco; margine per aggiornamenti |

La VM non fa mai rendering 3D: e' un ruolo puramente di routing di rete e
file statici, quindi le specifiche restano modeste anche con 4+16 = 20
giocatori totali connessi.

## Gestione e debug

```bash
# stato dei servizi
sudo systemctl status doom-relay.service
sudo systemctl status quake3-server.service
sudo systemctl status nginx

# log in tempo reale
sudo journalctl -u doom-relay.service -f
sudo journalctl -u quake3-server.service -f

# restart
sudo systemctl restart doom-relay.service
sudo systemctl restart quake3-server.service
sudo systemctl reload nginx

# stato lobby Doom attive (endpoint di diagnostica del relay)
curl -s http://127.0.0.1:8771/health | python3 -m json.tool

# ricompilare/aggiornare un singolo gioco senza rifare tutto il setup
sudo -u gamehub games/doom/build.sh /opt/lan-game-hub/build /opt/lan-game-hub/web/games/doom
```

## Estendere con un nuovo gioco

1. Crea `games/<nuovo-id>/game.json` con `name`, `description`,
   `max_players`, `web_path`, ed eventualmente una sezione `server` se il
   gioco necessita di un processo server dedicato.
2. Crea `games/<nuovo-id>/build.sh` (usa `scripts/common.sh` per le
   funzioni condivise) che produce i file statici del client.
3. Se serve un servizio di rete: aggiungi una unit in `deploy/systemd/` e
   una `location` in `deploy/nginx/<nuovo-id>.locations.conf`.
4. Rilancia `sudo ./deploy/setup.sh` — la hub page si aggiorna da sola
   leggendo tutti i `games/*/game.json`.

## Vincoli e note

- Pensato per rete LAN interna isolata: nessun TLS/certificato pubblico.
- Nessuna dipendenza da database o sistemi di autenticazione esterni.
- Nessun segreto o credenziale hardcoded: tutto configurabile via
  variabili d'ambiente (`/etc/lan-game-hub/*.env`) con default sensati per
  uso LAN interna.
