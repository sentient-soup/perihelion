# phis4 Docker Stack

Compose configuration for the phis4 media/files node. The root
[docker-compose.yaml](docker-compose.yaml) assembles per-group compose files
under `services/` via `include:` (requires Docker Compose **v2.20+**).

```
docker/
  docker-compose.yaml          # root — wires groups + their env files
  .env                         # non-sensitive config (committed)
  services/<group>/compose.yaml        # media, ingest, photos, files, books, monitoring
  services/<group>/.secrets.env.example # secret template (committed)
  services/<group>/.secrets.env        # real secret values (gitignored, host-only)
  bootstrap/setup.sh           # one-time directory provisioning
  bootstrap/sync-qbit-port.sh  # cron: gluetun forwarded port → qBittorrent
  bootstrap/restart-vpn-stack.sh # restart gluetun + everything in its netns
  bootstrap/backup-vaultwarden.sh # cron: consistent copy of the vault db
  bootstrap/backup-tier.sh     # cron: guarded hot/cold tier mirror
  bootstrap/wifi-probe.sh      # cron: wifi radio quality + latency -> VictoriaMetrics
```

## Deploy

```bash
git clone <repo> /opt/homelab && cd /opt/homelab/docker

# 1. Review .env (paths, ports, GIDs are host-specific)

# 2. Provision data/config directories
sudo bash bootstrap/setup.sh

# 3. Create secret files from templates and fill in real values (see Secrets below)
cp services/ingest/.secrets.env.example services/ingest/.secrets.env
cp services/photos/.secrets.env.example services/photos/.secrets.env
cp services/odysseus/.secrets.env.example services/odysseus/.secrets.env
cp services/vaultwarden/.secrets.env.example services/vaultwarden/.secrets.env
${EDITOR:-nano} services/ingest/.secrets.env services/photos/.secrets.env services/odysseus/.secrets.env services/vaultwarden/.secrets.env

# 4. Start everything
docker compose up -d

# 5. Install the crons
# */5 * * * * /opt/homelab/docker/bootstrap/sync-qbit-port.sh >> /var/log/qbit-port-sync.log 2>&1
# 30 3 * * *  /opt/homelab/docker/bootstrap/backup-vaultwarden.sh >> /var/log/vaultwarden-backup.log 2>&1
# * * * * *   /opt/homelab/docker/bootstrap/wifi-probe.sh  # temporary, see Wifi link monitoring
```

## Secrets

Real values live only on the host in `services/<group>/.secrets.env`, which is
gitignored. The committed `.secrets.env.example` files document which keys each
group needs. Compose reads `.secrets.env` via the `env_file` lists in
[docker-compose.yaml](docker-compose.yaml).

- **Set up / rotate:** `cp .secrets.env.example .secrets.env`, then edit in real
  values. Back them up to a password manager — they are not in git.
- **Add a new key:** add it to both the `.example` template (committed) and the
  host's `.secrets.env`.

## Storage layout

`/mnt/phis4/hot` is **ssd1, mounted directly**, with the media drive nested
at `/mnt/phis4/hot/media`. Every drive gets exactly one mountpoint: no binds,
no pools. mergerfs was retired on 2026-09-05 after ssd2 dropped off the USB
bus and took the whole pool down with it: mergerfs has no redundancy, so every
read through the pool hit the dead branch and returned EIO, which is what
broke Jellyfin.

Two things that will confuse you later:

- **`hot` means the live tier, not the SSD.** Config sits on ssd1; the media
  drive nested inside it is a 7.3T spinning disk. The name predates the split
  and is kept because renaming it would repoint every container.
- **Stop copyparty before unmounting the hot tier.** It holds `/mnt/phis4/hot`
  open and is the usual culprit behind `target is busy`. `docker compose stop`
  does not cover it, since it is not (yet) in the compose stack.

Always use `/mnt/phis4/hot`, never a member disk (e.g. `/mnt/phis4/ssd1`).
The paths below are unchanged from the mergerfs era on purpose - absolute
paths are denormalized into half a dozen application databases (*arr root
folders, Jellyfin libraries, Immich, and Nextcloud's immutable
`NEXTCLOUD_DATADIR`), so the hardware moved underneath them instead.

- `CONFIG_DIR=/mnt/phis4/hot/config` — per-service config/state
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
| ingest | Bazarr | 6767 | subtitles for Radarr/Sonarr |
| ingest | Bookshelf | 8787 | |
| ingest | Jellyseerr | 5055 | |
| ingest | Cleanuparr | `${CLEANUPARR_PORT}` = 11011 | queue janitor; all config in its own UI |
| photos | Immich | 2283 | |
| files | Nextcloud AIO admin | 8080 (apache on 11000) | |
| books | Audiobookshelf | 13378 | |
| cadence | Cadence | `${CADENCE_PORT}` = 3000 | fitness tracker; `:latest` + watchtower auto-update |
| vaultwarden | Vaultwarden | `${VAULTWARDEN_PORT}` = 8222 | password vault; HTTPS-only via Traefik |
| monitoring | VictoriaMetrics | 8428 | scrape config: `${CONFIG_DIR}/metrics/scrape.yml` |
| monitoring | cAdvisor | 8081 | |
| monitoring | node_exporter | host network (9100) | |
| odysseus | Odysseus AI workspace | `${ODYSSEUS_PORT}` = 7000 | image pinned via `${ODYSSEUS_VERSION}` |
| odysseus | ntfy | `${NTFY_PORT}` = 8091 | bundled notification server |
| odysseus | searxng / chromadb | internal only | reached by compose DNS, no host port |

## VPN / port forwarding

All torrent traffic routes through gluetun (ProtonVPN WireGuard);
qBittorrent and seedboxapi share its network namespace. Generate the
WireGuard key at <https://account.proton.me/u/0/vpn/WireGuard> →
`PROTON_WIREGUARD_PRIVATE_KEY` in `services/ingest/.secrets.env`.

ProtonVPN assigns a random forwarded port; `bootstrap/sync-qbit-port.sh`
(cron, every 5 min) reads it from gluetun's control server and updates
qBittorrent's listen port.

### Never redeploy gluetun on its own

Recreating gluetun builds a new network sandbox. Its dependents stay attached
to the old one and go **silently** unreachable: containers still show `Up`,
their logs stay clean, but the published port now points into the new sandbox
where nothing listens, so Traefik returns 502. The tell is `docker ps` showing
a dependent with a longer uptime than gluetun. This also happens unattended
when gluetun crashes and `restart: unless-stopped` brings it back.

Use the script, which recreates gluetun plus every service that declares
`network_mode: service:gluetun`:

```bash
bootstrap/restart-vpn-stack.sh
```

`docker compose up -d` on the whole stack is also safe (compose cascades the
recreate). What breaks things is `docker compose up -d gluetun` or
`docker restart gluetun`. Restarting a dependent *alone* is fine and needs no
script.

## First-run configuration order (ingest)

1. **gluetun** — verify VPN connected (`docker logs gluetun`)
2. **qBittorrent** — default save path `/data/torrents`; categories
   `movies, shows, music, audiobooks`
3. **Prowlarr** — add indexers; connect Radarr/Sonarr/Lidarr/Bookshelf as apps
4. **Radarr / Sonarr / Lidarr** — root folders `/data/movies`, `/data/shows`,
   `/data/music`; download client qBittorrent at `gluetun:8080`
5. **Bazarr** — connect Radarr/Sonarr (host IP, API keys from their Settings →
   General); add subtitle providers; languages profile on `/data` paths
6. **Bookshelf** — root folder `/data/books`; prefer M4B over MP3
7. **Jellyseerr** — connect Jellyfin, then Radarr + Sonarr
8. **Cleanuparr** - download client qBittorrent at `http://gluetun:8080`
   (qBittorrent shares gluetun's netns, so that is its container DNS name);
   *arr apps at `http://radarr:7878`, `http://sonarr:8989`, `http://lidarr:8686`,
   `http://bookshelf:8787` with their API keys. Then enable jobs one at a time.
   Start with **Queue Cleaner only** (stalled / failed-import / malware). It
   works off the *arr queues, so anything already imported and seeding is
   invisible to it, so manual seed-time overrides in qBittorrent are safe.

   Leave **Download Cleaner off**. It is the one job that acts on completed,
   seeding torrents, and qBittorrent's own share limits already cover that,
   with per-torrent overrides that Cleanuparr does not read. Two systems with
   opinions about seed time is how a forever-seeder gets deleted.

   Belt and braces regardless: tag keepers `keep` in qBittorrent and add `keep`
   to **Ignored Downloads** on both jobs (it matches hash, tag, category, or
   tracker domain). Also leave `Delete private torrents` off: private torrents
   hitting max strikes then leave the *arr queue but keep seeding, which is what
   avoids an H&R on MAM.

## Image pinning / updates

Every image is pinned to an exact version (or digest where upstream has no
version tags). Update intentionally, one service at a time:

```bash
# check the app's changelog first, then:
#   edit the tag in services/<group>/compose.yaml, commit, and run
docker compose pull <service> && docker compose up -d <service>
```

The one auto-update path is **Watchtower** (`services/watchtower/`), which runs
in **label opt-in** mode (`WATCHTOWER_LABEL_ENABLE=true`): it touches *only*
containers that carry the enable label and ignores everything else, so the
pinned stack stays frozen. To put a self-developed app on auto-deploy:

1. Give it a **moving tag**, e.g. `image: ghcr.io/<you>/<app>:latest` (not a
   pinned version/digest — watchtower follows the digest behind the tag).
2. Add the label to its service:
   ```yaml
   labels:
     - com.centurylinklabs.watchtower.enable=true
   ```

Watchtower pulls + recreates the container in place every 5 min when the tag's
digest changes; it does **not** rewrite compose or git, so there's no deploy
audit trail (the trade-off vs ArgoCD on the k8s side). **Private GHCR
packages** need host auth: create `${CONFIG_DIR}/watchtower/config.json` (a
Docker `config.json` with a `read:packages` PAT under `auths`), then uncomment
the `config.json` volume in `services/watchtower/compose.yaml`. Public packages
need nothing.

Exceptions:
- **gluetun** is digest-pinned to a master build (its `latest` tracks master,
  ahead of release v3.41.1). Move to a release tag at next maintenance;
  v3.40+ requires an auth config for control-server routes, which affects
  `sync-qbit-port.sh`.
- **Nextcloud AIO** stays on `latest` deliberately — it only publishes
  `latest`/`beta` and manages its own updates (and its `nextcloud-aio-*`
  child containers) through the AIO admin UI.
- **Odysseus** publishes only dev tags (`1.0.0-dev.<sha>`), pinned via
  `ODYSSEUS_VERSION` in `.env`. Its bundled `chromadb` (`:latest`) and `ntfy`
  (untagged) follow upstream's compose; `searxng` is pinned in the compose
  (see the note there). The mounted searxng config is vendored at
  `services/odysseus/config/searxng/settings.yml`.

## Wifi link monitoring (temporary)

phis4 is on wifi until it moves to a wired drop, and the byte/packet counters
node_exporter already collects cannot see 802.11 contention: the radio retries
failed frames at the MAC layer, so TCP sees added latency rather than loss.
Jitter alongside a flat TCP retransmit ratio is that signature, and it is
invisible to every metric the stack collected before this.

`bootstrap/wifi-probe.sh` (cron, every minute) fills the gap. It pushes radio
quality and ping latency straight to VictoriaMetrics' import endpoint by IP, so
it needs no scrape job and does not depend on container-side DNS. On phis4:

```bash
# * * * * * /opt/homelab/docker/bootstrap/wifi-probe.sh
```

Series: `wifi_signal_dbm`, `wifi_tx_bitrate_mbps`, `wifi_rx_bitrate_mbps`,
`wifi_tx_retries_total`, `wifi_tx_failed_total`, `wifi_tx_packets_total`,
`probe_rtt_ms`, `probe_jitter_ms`, `probe_loss_pct`, all labelled by `host`.
Only what the local driver exposes is emitted.

Queries for the next high-latency event. Use the **hourly median**, not the raw
series: it separates sustained degradation from the constant per-sample
spikiness, and it is what made the 10/26 18:52 event visible at all.

```promql
# the symptom, on the wifi hop alone
quantile_over_time(0.5, probe_jitter_ms{target="192.168.1.1"}[1h])

# hard evidence: a lost ping to your own gateway means the radio gave up
probe_loss_pct

# the leg beyond the gateway (target labels differ, so match on host)
probe_rtt_ms{target="1.1.1.1"} - on(host) probe_rtt_ms{target="192.168.1.1"}

# phis4's own contribution, to check magnitude before blaming it
rate(node_network_transmit_bytes_total{node="phis4",device="wlp2s0"}[5m]) * 8 / 1e6
```

| What moved | Reading |
|---|---|
| jitter median rises | check phis4's TX magnitude before blaming the homelab |
| loss to 192.168.1.1 above zero | the radio exhausted its retries; genuine link failure |
| loss to 1.1.1.1 with none to the router | upstream, nothing local can fix it |

Measured baselines, 2026-10-26/27 over two days, with power save on:

| | phis4 |
|---|---|
| jitter to router, hourly median | 11.7 ms (peaks 34-37) |
| loss to router | zero across two days |
| TX bandwidth | median 0.41 Mbps, peak 28.57 |
| PHY rate at signal | 960/324 Mbps at -57 dBm |

Zero router loss over two days means the link itself is sound. phis4's 28.57
Mbps peak is ~5% airtime at 960 Mbps PHY, so when jitter rises in the evenings
the homelab is a passenger rather than the cause; the common factor is the
whole house being active, not Jellyfin.

**`wifi_tx_retries_total` is not a channel sensor.** Retry ratio runs
*anti*-correlated with traffic: 0.15-0.45 while phis4 is idle, collapsing to
~0.01 the moment it transmits. A busy link sends large A-MPDUs where BlockAck
repairs subframes cheaply, while an idle link sends a handful of small frames
where two retries out of five reads as 40%. Median TX is 0.41 Mbps, so phis4 is
idle almost always and the metric mostly measures noise in a tiny denominator.
Still collected, but do not read it as contention.

Channel utilization (`busy_time/active_time` from `iw survey dump`) would beat
all of the above on its own, but iwlwifi on phis4 doesn't report survey data; it would take a USB adapter on an `mt76` or `ath9k`
chipset. Not worth buying for a problem the wired move removes.

### Never disable wifi power save on phis4

Leave `power_save` on. Turning it off, either at runtime with `iw dev wlp2s0
set power_save off` or permanently with `options iwlmvm power_scheme=1`,
collapses the **downlink** to HE-MCS 0 / NSS 1 / 20 MHz / DCM on, which is 3.6
Mbit/s, while the uplink stays at 960 Mbit/s and the signal stays at -53 dBm.
Confirmed twice: once at runtime on 2026-10-27 22:30, once as a module
parameter across a reboot. Rebooting with power save left at its default
restores it immediately.

NSS and bandwidth are capability decisions rather than link-quality ones, so
this is the AP's stored picture of phis4's receive capability going wrong, not
a radio fault. Signal strength is irrelevant to it.

This is not merely a slow server. At 3.6 Mbit/s a 1500-byte frame occupies 3.3
ms of airtime instead of 12.5 us, roughly 270x, so phis4 in this state starves
every other device on the 5 GHz channel. It is the likeliest explanation for
the household-wide slowdowns that prompted this instrumentation.

The price of leaving power save on is about 10 ms of extra jitter on phis4
(11.7 ms hourly median). That is the better trade.

**Remove this section, the script and its cron once phis4 is wired.**

## Operational notes

- **Project identity is pinned** (`name: phis4` in docker-compose.yaml),
  independent of the directory — the stack folder can be moved or renamed
  freely without disturbing containers. All state is on bind mounts (absolute
  host paths); the only Docker-named volumes are `nextcloud_aio_mastercontainer`
  (fixed name) and `immich-model-cache` (regenerable ML cache).
- **Never `docker compose down -v`** — `-v` deletes named volumes, including the
  Nextcloud AIO master volume.
- **Named volumes live on the root LV**, not the pool — `jellyfin-cache` and
  `immich-model-cache` land in `/var/lib/docker` on `ubuntu-vg/ubuntu-lv`
  (nvme). That is deliberate: both are hot, high-churn caches that want the
  SSD, not the media tier. It is only safe because the LV was extended to fill its
  volume group (the Ubuntu installer carved out just 100 GiB of the 928 GiB
  nvme); watch `node_filesystem_avail_bytes{mountpoint="/"}` rather than
  relocating them. Jellyfin only reclaims transcode segments when a session
  ends *cleanly* — orphans from abrupt client disconnects wait for the daily
  **Clean Transcode Directory** scheduled task.
- **Nextcloud AIO:** only `nextcloud-aio-mastercontainer` is compose-managed. It
  spawns the other `nextcloud-aio-*` containers via the Docker socket, so they
  are not part of the compose project and keep running through a `compose down`
  (Nextcloud serves traffic across a stack restart). `NEXTCLOUD_DATADIR` is fixed
  at install time — changing it later is ignored.
- **Vaultwarden:** first run has `SIGNUPS_ALLOWED=true`. Create your account at
  <https://vault.perihelion.live>, then flip it to `false` in
  `services/vaultwarden/compose.yaml` and `docker compose up -d vaultwarden`.
  `${CONFIG_DIR}/vaultwarden` is the entire vault (SQLite + attachments + RSA
  keys), and the host's rsync mirror already carries all of it. The one file
  rsync can't copy safely is the WAL-mode SQLite db, so
  `bootstrap/backup-vaultwarden.sh` (cron, nightly, before the mirror) writes a
  locked, verified copy to `${CONFIG_DIR}/vaultwarden/backup/db.sqlite3` for
  the mirror to pick up. Restore: stop the container, copy that db up one level
  over `db.sqlite3` (dropping any `-wal`/`-shm`), start it. Mobile push is off (needs a Bitwarden install id/key); clients still
  sync when opened.
- **Immich DB password** (`IMMICH_DB_PASSWORD`) is baked into the Postgres data
  dir at first init. On a rebuild/restore it must match the original value or
  immich-server can't connect to its database.

## Optional services (commented out in compose files)

- **jellysignal** (media) — `cp services/media/.secrets.env.example
  services/media/.secrets.env` and fill in, add `services/media/.secrets.env`
  to the media `env_file` list in docker-compose.yaml, and uncomment.
- **SABnzbd** (ingest) — when subscribed to NewsDemon + NZBGeek. Server
  `news.newsdemon.com:563`, SSL, 50 connections. Add as priority-1 download
  client in the *arr apps, demote qBittorrent to priority-2, and add the
  NZBGeek indexer in Prowlarr.
- **Readarr** (ingest) — retired upstream. Uses the rreading-glasses
  community metadata mirror: in Settings → Metadata, replace the default
  metadata server URL with the mirror endpoint.
- **LazyLibrarian** (ingest) — Readarr alternative; the ffmpeg docker mod
  enables mp3-chapters → m4b conversion.
