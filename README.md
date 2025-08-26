# Perihelion (Homelab)

Accumulation of manifests, scripts, and config files used to establish the aphelion homelab.

## Features

| Feature                       | (Proposed) Technology               | Completed |
| ----------------------------- | ----------------------------------- | --------- |
| Replicable Setup              | Bash (Maybe Helm)                   | ❌        |
| Load Balancing                | Kubernetes                          | ✔️        |
| Container Management          | ~~Portainer~~ Rancher               | ✔️        |
| Load Balancing & Routing      | Traefik & MetalLB                   | ✔️        |
| DNS management                | Pihole                              | ✔️        |
| Smart Home/Device Integration | Homeassistant                       | ✔️        |
| File Serving                  | Nextcloud                           | ✔️        |
| Network Tunneling             | CloudFlared Tunnel                  | ✔️        |
| Certificate Management        | Let's Encrypt/Certbot (CertManager) | ✔️        |
| CI/CD Capabilities            | ArgoCD/Github CI                    | ✔️        |
| Media Serving                 | Jellyfin                            | ✔️¹       |
| Game Servers                  | Custom scripts                      | ❌        |
| Network Topology Mapper       | NetAlertX                           | ❌        |
| Version Watchdog              | Keel.sh                             | ❌        |
| Metrics Monitoring            | Portainer or Prometheus/Grafana     | ❌        |
| Camera/Stream Ingestion       | Shinobi (?)                         | ❌        |

## Future Goals

Eventually I would like to integrate some sort of hypervisor that can dynamically scale. Such as using proxmox with something like terraform and ansible to manage vm deployments across hosts. For now, simply sticking to kubernetes on baremetal is sufficient for my purposes. Especially given the hardware and power limitations I'm currently working with.

> [!NOTE]
> ¹ Jellyfin recomends against containerizing their software. For the time being it is installed and managed separately and only network/routing considerations related might be included here in.
