# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps repository for a k3s homelab cluster (`perihelion.live`). All cluster state is declared here and applied via ArgoCD. There are no build steps — changes take effect when pushed to `main` and ArgoCD syncs.

## Cluster interaction

**This dev machine cannot reach the cluster.** It is *not* the k3s node — work here is editing manifests; ArgoCD reconciles them from `main`. `kubectl` exists only inside WSL and has **no kubeconfig pointed at the cluster**, so the commands below cannot be run from here. Do not assume cluster access: produce manifests and ask the user to run any live `kubectl`/verification commands on a configured machine. (Secret sealing is the deliberate exception — it works offline; see Secrets pattern.)

```bash
kubectl get applications -n argocd               # see all ArgoCD apps and sync status
kubectl get svc -A                               # see all services and their LB IPs
kubectl logs -n <namespace> <pod> --tail=50      # diagnose a failing pod
kubectl describe certificate <name> -n <ns>      # cert-manager cert status and ACME progress
```

Secrets are managed with Sealed Secrets — see the **Secrets pattern** section for the `scripts/generate-secret.sh` workflow.

## Repository structure

```
k8s/
  bootstrap/        # Root ArgoCD "app of apps" that watches k8s/apps/ recursively
  apps/             # ArgoCD Applications, grouped into infra/ platform/ services/
  manifests/        # Raw Kubernetes manifests referenced by path-based apps
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
| `networking` | Pihole, nginx |
| `apps` | Homeassist, Apseline |
| `traefik` | Traefik ingress controller |

## MetalLB IP allocations

Pool range: `192.168.1.220–250`

| IP | Service |
|---|---|
| 192.168.1.220 | Pihole |
| 192.168.1.221 | ArgoCD |
| 192.168.1.226 | Traefik |
| 192.168.1.227 | nginx |
| 192.168.1.228 | Headlamp |

To pin a specific IP, use the annotation (not the deprecated `spec.loadBalancerIP`):
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 192.168.1.XXX
```

## Helm chart versions

For apps in `k8s/apps/` that use Helm sources, `targetRevision` is the chart semver. For apps using a `path:` source (Git), `targetRevision` is a git ref (`HEAD`, branch, tag). Check latest chart versions at the chart's GitHub releases page — Artifact Hub can lag.

## Active migration: nginx → Traefik

nginx (`k8s/manifests/services/nginx/`) is a raw nginx deployment (not the nginx-ingress controller) being phased out. Traefik (`k8s/apps/platform/traefik.yaml`) is the target ingress controller. New routing should be built as Traefik `IngressRoute` CRDs, not nginx config. cloudflared has been removed — there is no public tunnel; access is LAN-only via MetalLB + split-horizon DNS.

**Routing pattern (copy these for new services):**
- A default `TLSStore` (`k8s/manifests/platform/traefik/tlsstore.yaml`) points at the `wildcard-perihelion-tls` secret, so any `IngressRoute` with `tls: {}` gets the wildcard cert — no per-service cert secrets needed.
- Put each `IngressRoute` **in the same namespace as the Service it targets** (Traefik resolves services within the route's namespace; cross-namespace service refs are disabled). Wire that manifests dir into a `*-config` ArgoCD app (see `headlamp-config.yaml`).
- Use `entryPoints: [websecure]` (443).
- Two reference examples: `headlamp/ingressroute.yaml` (plain app that brings its own auth) and `traefik/dashboard.yaml` (internal `api@internal` service protected by the `dashboard-auth` `basicAuth` Middleware).
- Each new hostname needs a Pihole local-DNS record → `192.168.1.226` (Traefik's LB IP).

## Secrets pattern

All secrets in `k8s/manifests/` are `SealedSecret` resources (encrypted, safe to commit). They decrypt to regular `Secret` objects via the Sealed Secrets controller running in the `infra` namespace. Never commit plain `Secret` resources.

**Generating/rotating:** use `scripts/generate-secret.sh <cloudflare|pihole|traefik-dashboard|all>`. It reads plaintext values from a git-ignored `.env` (template: `.env.example`) and seals **offline** against the committed `pub-cert.pem` — no cluster or kubeconfig required. `kubectl` must be on `PATH` but only renders the secret locally (`--dry-run=client`); the controller's public cert (`pub-cert.pem`) is safe to commit and is what enables offline sealing. Refresh it only if the controller's keypair rotates: `kubeseal --controller-namespace infra --fetch-cert > pub-cert.pem`. To add a new secret, copy a `gen_*` function in the script.

**Strict-scope gotcha:** a SealedSecret's ciphertext is cryptographically bound to the exact `namespace` + `name` it was sealed under. You cannot move or rename one by editing the YAML — the controller will refuse to decrypt; you must re-seal. In particular, a `ClusterIssuer` reads its credential from the `cert-manager` namespace, so the Cloudflare token must be sealed for `cert-manager` (secret `cloudflare-api-token`, key `api-token`), not `default`.

## Domain and TLS

Domain: `perihelion.live`. cert-manager handles certificate lifecycle (replaces bare-metal certbot). Pihole provides local split-horizon DNS — internal devices resolve `*.perihelion.live` to the Traefik LB IP.

- **Issuer:** a single `ClusterIssuer` named `letsencrypt` (Let's Encrypt prod, no staging) at `k8s/manifests/infra/cert-manager/cluster-issuer.yaml`. Solver is **DNS-01 via Cloudflare** (`apiTokenSecretRef`), scoped to the `perihelion.live` zone. DNS-01 is what allows wildcard certs and needs no public ingress.
- **Wildcard cert:** `k8s/manifests/platform/traefik/certificate.yaml` requests `*.perihelion.live` (+ apex) into secret `wildcard-perihelion-tls` in the `traefik` namespace, for Traefik to serve TLS for all subdomains.
- **Cloudflare token:** scoped API token (Zone→DNS→Edit, Zone→Read), stored as the `cloudflare-api-token` SealedSecret — see Secrets pattern.
