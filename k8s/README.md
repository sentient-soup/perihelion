# perihelion k8s

GitOps configuration for the k3s cluster, reconciled by ArgoCD. There are no
build steps — changes take effect when pushed to `main` and ArgoCD syncs.

## Layout

```
k8s/
  bootstrap/root-app.yaml   # ArgoCD "app of apps" — watches k8s/apps/ recursively
  apps/                     # one ArgoCD Application per file
    infra/                  #   metallb, sealed-secrets, cert-manager (+ config)
    platform/               #   argocd, traefik, headlamp
    services/               #   pihole, nginx, homeassist, apseline
  manifests/                # raw manifests referenced by path-based apps
    infra/ platform/ services/
  scripts/generate-secret.sh  # sealed-secrets generation (offline)
  pub-cert.pem              # sealed-secrets controller public cert
  .env.example              # template for the git-ignored k8s/.env
```

Every file under `apps/` is an ArgoCD `Application` pointing at either a Helm
chart (`targetRevision` = chart semver) or a path in `manifests/`
(`targetRevision` = git ref). Everything under `apps/` is live — there is no
staging tree.

**Sync-wave ordering:** when config depends on a chart's CRDs it lives in a
separate `*-config` app ordered by the `argocd.argoproj.io/sync-wave`
annotation. Current order: cert-manager chart (`-1`) → `cert-manager-config`
ClusterIssuer (`0`) → traefik chart (`1`) → `traefik-config` Certificate (`2`).

## Namespaces

| Namespace | Purpose |
|---|---|
| `argocd` | ArgoCD |
| `infra` | Sealed Secrets controller |
| `metallb-system` | MetalLB |
| `cert-manager` | cert-manager |
| `platform` | Headlamp UI |
| `networking` | Pihole, nginx |
| `apps` | Homeassist, Apseline |
| `traefik` | Traefik ingress controller |

## MetalLB

Pool: `192.168.1.220–250`

| IP | Service |
|---|---|
| 192.168.1.220 | Pihole |
| 192.168.1.221 | ArgoCD |
| 192.168.1.226 | Traefik |
| 192.168.1.227 | nginx |
| 192.168.1.228 | Headlamp |

Pin an IP with the annotation (not the deprecated `spec.loadBalancerIP`):

```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 192.168.1.XXX
```

## Routing (Traefik)

Access is LAN-only: MetalLB + split-horizon DNS (Pihole resolves
`*.perihelion.live` to Traefik's LB IP). nginx is being phased out in favor
of Traefik `IngressRoute` CRDs.

For a new service:

1. Create an `IngressRoute` **in the same namespace as the Service it
   targets** (cross-namespace service refs are disabled), with
   `entryPoints: [websecure]` and `tls: {}` — the default `TLSStore`
   (`manifests/platform/traefik/tlsstore.yaml`) serves the wildcard cert, so
   no per-service cert secrets are needed.
2. Wire its manifests dir into a `*-config` ArgoCD app (see
   `apps/platform/headlamp-config.yaml`).
3. Add a Pihole local-DNS record for the hostname → `192.168.1.226`.

Reference examples: `manifests/platform/headlamp/ingressroute.yaml` (plain
app) and `manifests/platform/traefik/dashboard.yaml` (`api@internal` behind a
`basicAuth` middleware).

## TLS

Domain: `perihelion.live`. A single `ClusterIssuer` named `letsencrypt`
(`manifests/infra/cert-manager/cluster-issuer.yaml`) uses **DNS-01 via
Cloudflare**, which permits wildcard certs with no public ingress.
`manifests/platform/traefik/certificate.yaml` requests `*.perihelion.live`
(+ apex) into the `wildcard-perihelion-tls` secret in the `traefik`
namespace.

## Secrets (Sealed Secrets)

All committed secrets are `SealedSecret` resources, decrypted in-cluster by
the controller in the `infra` namespace. **Never commit a plain `Secret`.**

Generate/rotate with the script — it reads plaintext values from a
git-ignored `k8s/.env` (template: `.env.example`) and seals **offline**
against the committed `pub-cert.pem`, so no cluster access is needed:

```bash
./k8s/scripts/generate-secret.sh <cloudflare|pihole|traefik-dashboard|all>
```

To add a new secret, copy a `gen_*` function in the script. Refresh the
public cert only if the controller's keypair rotates:

```bash
kubeseal --controller-namespace infra --fetch-cert > k8s/pub-cert.pem
```

**Strict-scope gotcha:** ciphertext is bound to the exact `namespace` +
`name` it was sealed under — you cannot move or rename a SealedSecret by
editing YAML; re-seal it. The Cloudflare token in particular must be sealed
for `cert-manager/cloudflare-api-token` (key `api-token`).

## Day-2 commands

From a machine with a configured kubeconfig:

```bash
kubectl get applications -n argocd               # app sync status
kubectl get svc -A                               # services + LB IPs
kubectl logs -n <ns> <pod> --tail=50
kubectl describe certificate <name> -n <ns>      # ACME progress
```
