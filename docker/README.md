# phis4 Docker Stack

Compose configuration for the phis4 media/files node. The root
[docker-compose.yaml](docker-compose.yaml) assembles per-group compose files
under `services/` via `include:` (requires Docker Compose **v2.20+**).

```
docker/
  docker-compose.yaml          # root — wires groups + their env files
  .env                         # non-sensitive config (committed)
  .sops.yaml                   # SOPS encryption rules
  services/<group>/compose.yaml        # media, ingest, photos, files, books, monitoring
  services/<group>/secrets.enc.env     # SOPS-encrypted secrets (committed)
  services/<group>/.secrets.env        # decrypted at deploy time (gitignored)
  bootstrap/setup.sh           # one-time directory provisioning
  bootstrap/sync-qbit-port.sh  # cron: gluetun forwarded port → qBittorrent
```

## Deploy

```bash
git clone <repo> /opt/homelab && cd /opt/homelab/docker

# 1. Review .env (paths, ports, GIDs are host-specific)

# 2. Provision data/config directories
sudo bash bootstrap/setup.sh

# 3. Decrypt secrets (see Secrets below for key setup)
sops -d services/ingest/secrets.enc.env > services/ingest/.secrets.env
sops -d services/photos/secrets.enc.env > services/photos/.secrets.env

# 4. Start everything
docker compose up -d

# 5. Install the port-sync cron
# */5 * * * * /opt/homelab/docker/bootstrap/sync-qbit-port.sh >> /var/log/qbit-port-sync.log 2>&1
```

## Secrets (SOPS + age)

One-time key setup:

```bash
age-keygen -o ~/.config/sops/age/keys.txt     # public key (age1...) goes in .sops.yaml
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

- **Edit an encrypted file:** `sops services/<group>/secrets.enc.env`
  (opens decrypted in `$EDITOR`, re-encrypts on save)
- **Create a new one:** write plaintext, then `sops -e -i secrets.enc.env`, then commit
- **Deploy:** `sops -d secrets.enc.env > .secrets.env` (gitignored — never commit)

## Storage layout

`/mnt/phis4/hot` is the **mergerfs pool** — always use it, never a member
disk (e.g. `/mnt/phis4/ssd1`).

- `CONFIG_DIR=/mnt/phis4/hot/data` — per-service config/state
- `DATA_DIR=/mnt/phis4/hot/media` — all media, mounted as `/data` in every
  ingest container so hardlinks work (TRaSH-guide single-root approach):

```
${DATA_DIR}/
├── movies/ shows/ music/        # libraries (Jellyfin sees these as /media/*)
├── books/ podcasts/             # Audiobookshelf
├── photos/                      # Immich
├── docs/                        # Nextcloud data
├── torrents/{movies,shows,music,audiobooks}      # qBittorrent
└── usenet/{incomplete,complete/{movies,shows,music,audiobooks}}  # SABnzbd
```

## Services and ports

| Group | Service | Port | Notes |
|---|---|---|---|
| media | Jellyfin | 8096 (+8920 tls, 7359/1900 udp discovery) | |
| ingest | qBittorrent | `${QBIT_WEBUI_PORT}` = 8085 | via gluetun; 8080 is taken by AIO |
| ingest | gluetun control server | 127.0.0.1:8000 | used by sync-qbit-port.sh |
| ingest | Prowlarr | 9696 | |
| ingest | FlareSolverr | 8191 | |
| ingest | Radarr / Sonarr / Lidarr | 7878 / 8989 / 8686 | |
| ingest | Bookshelf | 8787 | |
| ingest | Jellyseerr | 5055 | |
| photos | Immich | 2283 | |
| files | Nextcloud AIO admin | 8080 (apache on 11000) | |
| books | Audiobookshelf | 13378 | |
| monitoring | VictoriaMetrics | 8428 | scrape config: `${CONFIG_DIR}/metrics/scrape.yml` |
| monitoring | cAdvisor | 8081 | |
| monitoring | node_exporter | host network (9100) | |

## VPN / port forwarding

All torrent traffic routes through gluetun (ProtonVPN WireGuard);
qBittorrent and seedboxapi share its network namespace. Generate the
WireGuard key at <https://account.proton.me/u/0/vpn/WireGuard> →
`PROTON_WIREGUARD_PRIVATE_KEY` in `services/ingest/secrets.enc.env`.

ProtonVPN assigns a random forwarded port; `bootstrap/sync-qbit-port.sh`
(cron, every 5 min) reads it from gluetun's control server and updates
qBittorrent's listen port.

## First-run configuration order (ingest)

1. **gluetun** — verify VPN connected (`docker logs gluetun`)
2. **qBittorrent** — default save path `/data/torrents`; categories
   `movies, shows, music, audiobooks`
3. **Prowlarr** — add indexers; connect Radarr/Sonarr/Lidarr/Bookshelf as apps
4. **Radarr / Sonarr / Lidarr** — root folders `/data/movies`, `/data/shows`,
   `/data/music`; download client qBittorrent at `gluetun:8080`
5. **Bookshelf** — root folder `/data/books`; prefer M4B over MP3
6. **Jellyseerr** — connect Jellyfin, then Radarr + Sonarr

## Image pinning / updates

Every image is pinned to an exact version (or digest where upstream has no
version tags). Update intentionally, one service at a time:

```bash
# check the app's changelog first, then:
#   edit the tag in services/<group>/compose.yaml, commit, and run
docker compose pull <service> && docker compose up -d <service>
```

Exceptions:
- **gluetun** is digest-pinned to a master build (its `latest` tracks master,
  ahead of release v3.41.1). Move to a release tag at next maintenance;
  v3.40+ requires an auth config for control-server routes, which affects
  `sync-qbit-port.sh`.
- **Nextcloud AIO** stays on `latest` deliberately — it only publishes
  `latest`/`beta` and manages its own updates (and its `nextcloud-aio-*`
  child containers) through the AIO admin UI.

## Optional services (commented out in compose files)

- **jellysignal** (media) — fill in `services/media/secrets.enc.env`, add
  `services/media/.secrets.env` to the media `env_file` list in
  docker-compose.yaml, decrypt, and uncomment.
- **SABnzbd** (ingest) — when subscribed to NewsDemon + NZBGeek. Server
  `news.newsdemon.com:563`, SSL, 50 connections. Add as priority-1 download
  client in the *arr apps, demote qBittorrent to priority-2, and add the
  NZBGeek indexer in Prowlarr.
- **Readarr** (ingest) — retired upstream. Uses the rreading-glasses
  community metadata mirror: in Settings → Metadata, replace the default
  metadata server URL with the mirror endpoint.
- **LazyLibrarian** (ingest) — Readarr alternative; the ffmpeg docker mod
  enables mp3-chapters → m4b conversion.
