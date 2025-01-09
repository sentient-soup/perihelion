# Perihelion (Homelab)

Accumulation of manifests, scripts, and config files used to establish the aphelion homelab.

## Features

| Feature                              | (Proposed) Technology                | Completed |
|--------------------------------------|--------------------------------------|-----------|
| Replicable setup                     | Bash (Maybe Helm)                    | ❌       |
| Load balancing                       | Kubernetes                           | ✔️       |
| Container management                 | Portainer                            | ✔️       |
| Load balancing & routing             | Traefik & MetalLB                    | ✔️       |
| DNS management                       | Pihole                               | ✔️       |
| Network tunneling                    | CloudFlared Tunnel                   | 🔜       |
| CI/CD capabilities                   | ArgoCD/Github CI                     | ❌       |
| Certificate management               | Let's Encrypt/Certbot                | ❌       |
| Game Servers               | Custom scripts              | ❌       |
| Media Serving                        | Plex                                 | ❌       |
| File Serving                         | Nextcloud                            | ❌       |
| Network topology mapper              | NetAlertX                            | ❌       |


## Future Goals

Eventually I would like to integrate some sort of hypervisor that can dynamically scale. Such as using proxmox with something like terraform and ansible to manage vm deployments across hosts. For now, simply sticking to kubernetes on baremetal is sufficient for my purposes. Especially given the hardware and power limitations I'm currently working with.
