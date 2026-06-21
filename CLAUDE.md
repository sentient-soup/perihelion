# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Configuration monorepo for the `perihelion.live` homelab, with two independent deployment surfaces:

- **`k8s/`** — GitOps for the k3s cluster. All cluster state is declared here and applied via ArgoCD. No build steps — changes take effect when pushed to `main` and ArgoCD syncs.
- **`docker/`** — Docker Compose stack for the standalone media/files node (`phis4`). **Not GitOps**: changes here do nothing until pulled on the host and applied with `docker compose up -d`. See `docker/README.md` for the full deploy/secrets workflow.

Most of this file documents the k8s side; see the Docker node section at the end for the phis4 conventions.

## Cluster interaction

**This dev machine cannot reach the cluster.** It is *not* the k3s node — work here is editing manifests; ArgoCD reconciles them from `main`. `kubectl` exists only inside WSL and has **no kubeconfig pointed at the cluster**, so the commands below cannot be run from here. Do not assume cluster access: produce manifests and ask the user to run any live `kubectl`/verification commands on a configured machine. (Secret sealing is the deliberate exception — it works offline; see Secrets pattern.)

```bash
kubectl get applications -n argocd               # see all ArgoCD apps and sync status
kubectl get svc -A                               # see all services and their LB IPs
kubectl logs -n <namespace> <pod> --tail=50      # diagnose a failing pod
kubectl describe certificate <name> -n <ns>      # cert-manager cert status and ACME progress
```

Secrets are managed with Sealed Secrets — see the **Secrets pattern** section for the `k8s/scripts/generate-secret.sh` workflow.

## Repository structure

```
k8s/
  bootstrap/        # Root ArgoCD "app of apps" that watches k8s/apps/ recursively
  apps/             # ArgoCD Applications, grouped into infra/ platform/ services/
  manifests/        # Raw Kubernetes manifests referenced by path-based apps
  scripts/          # generate-secret.sh (sealed-secrets workflow)
  pub-cert.pem      # sealed-secrets controller public cert (offline sealing)
  .env.example      # template for the git-ignored k8s/.env used by the script
docker/             # phis4 compose stack (see docker/README.md)
```

**App of Apps pattern:** `bootstrap/root-app.yaml` points ArgoCD at `k8s/apps/` recursively. Every file there is an ArgoCD `Application` that references either a Helm chart or a path in `k8s/manifests/`. There is no `apps-staging/` — everything under `k8s/apps/` is live.

**Chart + config split via sync-waves:** when config depends on a chart's CRDs, it lives in a separate `*-config` app ordered by the `argocd.argoproj.io/sync-wave` annotation. Current ordering: cert-manager chart (wave `-1`) → `cert-manager-config` ClusterIssuer (`0`) → traefik chart (`1`) → `traefik-config` Certificate (`2`).

## Namespaces and their purpose

| Namespace | Purpose |
|---|---|
| `argocd` | ArgoCD itself |
| `infra` | Sealed Secrets controller |
| `metallb-system` | MetalLB load balancer |
| `cert-manager` | cert-manager |
| `platform` | Headlamp UI |
| `networking` | Pihole |
| `apps` | Homeassist, Apseline |
| `external` | Routes to off-cluster phis4 services (ExternalName + IngressRoute) |
| `traefik` | Traefik ingress controller |

## MetalLB IP allocations

Pool range: `192.168.1.220–250`

| IP | Service |
|---|---|
| 192.168.1.220 | Pihole |
| 192.168.1.221 | ArgoCD |
| 192.168.1.226 | Traefik |
| 192.168.1.228 | Headlamp |

To pin a specific IP, use the annotation (not the deprecated `spec.loadBalancerIP`):
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 192.168.1.XXX
```

## Helm chart versions

For apps in `k8s/apps/` that use Helm sources, `targetRevision` is the chart semver. For apps using a `path:` source (Git), `targetRevision` is a git ref (`HEAD`, branch, tag). Check latest chart versions at the chart's GitHub releases page — Artifact Hub can lag.

## Routing (Traefik)

Traefik (`k8s/apps/platform/traefik.yaml`) is the sole ingress controller; all routing is Traefik `IngressRoute` CRDs. The previous raw nginx reverse proxy (an in-cluster Deployment on node `phis1`, served from `/srv/nginx`) has been removed. cloudflared has been removed (there is no public tunnel); access is LAN-only via MetalLB + split-horizon DNS.

**Routing pattern (copy these for new services):**
- A default `TLSStore` (`k8s/manifests/platform/traefik/tlsstore.yaml`) points at the `wildcard-perihelion-tls` secret, so any `IngressRoute` with `tls: {}` gets the wildcard cert — no per-service cert secrets needed.
- Put each `IngressRoute` **in the same namespace as the Service it targets** (Traefik resolves services within the route's namespace; cross-namespace service refs are disabled). Wire that manifests dir into a `*-config` ArgoCD app (see `headlamp-config.yaml`).
- Use `entryPoints: [websecure]` (443).
- Two reference examples: `headlamp/ingressroute.yaml` (plain app that brings its own auth) and `traefik/dashboard.yaml` (internal `api@internal` service protected by the `dashboard-auth` `basicAuth` Middleware).
- Each new hostname needs a Pihole local-DNS record → `192.168.1.226` (Traefik's LB IP).

**Routing to off-cluster backends (the `external` namespace):** services that run on the phis4 docker host (`192.168.1.215`), not in the cluster, are reverse-proxied by Traefik via the `external` namespace (`k8s/manifests/services/external/`, ArgoCD app `external.yaml`). This replaced the old nginx proxy that ran on phis1. Each host is an **`ExternalName` Service** pointed straight at the IP (`externalName: "192.168.1.215"`) plus a normal `IngressRoute`/middlewares — copy any file there (e.g. `jellyfin.yaml`) as the template. Two non-obvious requirements:
  - Traefik rejects ExternalName Services unless `providers.kubernetesCRD.allowExternalNameServices: true` is set in the chart values (`k8s/apps/platform/traefik.yaml`).
  - **Do not** use a selectorless Service + `Endpoints`/`EndpointSlice` for this (the textbook approach): ArgoCD's default `resource.exclusions` drops both kinds, so it silently never applies them and Traefik returns `503 no available server`. ExternalName sidesteps that. A literal IP is a valid `externalName`, so Traefik dials it directly — needed here because the cluster's CoreDNS resolves `*.perihelion.live` to public Cloudflare IPs, not Pihole's LAN records, so a hostname would not resolve to the host.

## Secrets pattern

All secrets in `k8s/manifests/` are `SealedSecret` resources (encrypted, safe to commit). They decrypt to regular `Secret` objects via the Sealed Secrets controller running in the `infra` namespace. Never commit plain `Secret` resources.

**Generating/rotating:** use `k8s/scripts/generate-secret.sh <cloudflare|pihole|traefik-dashboard|victoriametrics|all>`. It reads plaintext values from a git-ignored `k8s/.env` (template: `k8s/.env.example`) and seals **offline** against the committed `k8s/pub-cert.pem` — no cluster or kubeconfig required. `kubectl` must be on `PATH` but only renders the secret locally (`--dry-run=client`); the controller's public cert is safe to commit and is what enables offline sealing. Refresh it only if the controller's keypair rotates: `kubeseal --controller-namespace infra --fetch-cert > k8s/pub-cert.pem`. To add a new secret, copy a `gen_*` function in the script.

**Strict-scope gotcha:** a SealedSecret's ciphertext is cryptographically bound to the exact `namespace` + `name` it was sealed under. You cannot move or rename one by editing the YAML — the controller will refuse to decrypt; you must re-seal. In particular, a `ClusterIssuer` reads its credential from the `cert-manager` namespace, so the Cloudflare token must be sealed for `cert-manager` (secret `cloudflare-api-token`, key `api-token`), not `default`.

## Domain and TLS

Domain: `perihelion.live`. cert-manager handles certificate lifecycle (replaces bare-metal certbot). Pihole provides local split-horizon DNS — internal devices resolve `*.perihelion.live` to the Traefik LB IP.

- **Issuer:** a single `ClusterIssuer` named `letsencrypt` (Let's Encrypt prod, no staging) at `k8s/manifests/infra/cert-manager/cluster-issuer.yaml`. Solver is **DNS-01 via Cloudflare** (`apiTokenSecretRef`), scoped to the `perihelion.live` zone. DNS-01 is what allows wildcard certs and needs no public ingress.
- **Wildcard cert:** `k8s/manifests/platform/traefik/certificate.yaml` requests `*.perihelion.live` (+ apex) into secret `wildcard-perihelion-tls` in the `traefik` namespace, for Traefik to serve TLS for all subdomains.
- **Cloudflare token:** scoped API token (Zone→DNS→Edit, Zone→Read), stored as the `cloudflare-api-token` SealedSecret — see Secrets pattern.

## Docker node (phis4)

`docker/` holds the Compose stack for the standalone media/files host (Jellyfin, *arr ingest behind a gluetun VPN, Immich, Nextcloud AIO, Audiobookshelf, monitoring). Key differences from the k8s side:

- **This dev machine is NOT the Docker host.** Same split as the k8s side: this is an editing box, phis4 is a separate machine. There is no Docker daemon or `docker` CLI here, and this machine cannot reach phis4 — `docker`/`docker compose` commands (including `compose config` to validate) will fail. Don't try them; produce config changes and hand the user the commands to run on phis4. (A WSL Docker setup for local validation may come later; until then, assume none.)
- **Not GitOps.** Nothing reconciles automatically — the user pulls on phis4 and runs `docker compose` there.
- **Migration complete:** the decomposed `docker/` stack is live on phis4 (deployed from `~/hm/docker`); the old monolith is archived at `~/hm/archive`. Project name is pinned `name: phis4`, so the stack directory can move without affecting container/volume identity. Operational gotchas (Nextcloud AIO, redeploy caveats) live in `docker/README.md`.
- **Secrets are gitignored plaintext**, not Sealed Secrets and not encrypted in git: real values live only on the host in `services/*/.secrets.env` (gitignored). Committed `services/*/.secrets.env.example` files document the required keys. Compose reads `.secrets.env` via the `env_file` lists in `docker-compose.yaml`. Never commit a real `.secrets.env`.
- **All images are pinned** to exact versions or digests; updates are intentional, one service at a time. Don't bump tags casually — see `docker/README.md` for the update workflow and the gluetun/Nextcloud-AIO exceptions. The one auto-update path is **Watchtower** (`services/watchtower/`), in label opt-in mode: only containers carrying `com.centurylinklabs.watchtower.enable=true` (on a moving tag) get auto-deployed; the pinned stack is untouched. This is the Docker-side analog to ArgoCD image tracking, used for self-developed apps.
- `docker/.env` is non-sensitive and **is committed** (the root `.gitignore` only ignores `k8s/.env`).
