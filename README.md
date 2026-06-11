# Perihelion (Homelab)

Configuration monorepo for the `perihelion.live` homelab. It houses two
deployment surfaces, kept in separate top-level directories:

| Directory | Host(s) | What | How it deploys |
|---|---|---|---|
| [k8s/](k8s/README.md) | k3s cluster | Cluster services: ArgoCD, Traefik, MetalLB, cert-manager, Pihole, Headlamp, Homeassist, Apseline | GitOps — push to `main`, ArgoCD reconciles |
| [docker/](docker/README.md) | phis4 | Media/files node: Jellyfin, the *arr ingest stack, Immich, Nextcloud AIO, Audiobookshelf, monitoring | Docker Compose — pull on the host, `docker compose up -d` |

Each directory has its own README with the full deploy and operations docs.

## Repo layout

```
k8s/      # k3s cluster state (ArgoCD app-of-apps) — see k8s/README.md
docker/   # phis4 compose stack — see docker/README.md
```

Everything specific to one surface lives inside its directory, including each
side's secrets tooling.

## Status

The phis4 docker migration is **in progress**: the host still runs its
original monolithic compose file; the decomposed stack in `docker/` has not
been cut over yet. On the k8s side, the nginx → Traefik routing migration is
also still underway.

## Secrets

Two mechanisms, one per surface — in both cases only encrypted artifacts are
committed and plaintext files are git-ignored:

| Surface | Mechanism | Committed artifact | Plaintext (ignored) |
|---|---|---|---|
| k8s | Sealed Secrets (kubeseal, sealed offline against `k8s/pub-cert.pem`) | `**/sealed-secret.yaml` | `k8s/.env` |
| docker | SOPS + age | `services/*/secrets.enc.env` | `docker/services/*/.secrets.env` |

## Conventions

- `.gitattributes` forces LF on `*.sh` and `*.env` — they execute/parse on
  Linux hosts; CRLF corrupts them.
- DNS is split-horizon: Pihole resolves `*.perihelion.live` to Traefik's
  MetalLB IP; nothing is exposed publicly (no tunnel).
- Docker images are pinned to exact versions and updated intentionally; see
  [docker/README.md](docker/README.md#image-pinning--updates).
