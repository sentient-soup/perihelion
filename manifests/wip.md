# A WIP Outline of the setup process

This applies to using k3s and a headless raspberry pi as nodes. It should translate to any hardware generically.

## Prepare Pi

```sh
# /boot/firmware/commandline.txt
console=serial0,115200 console=tty1 root=PARTUUID=28373ef5-02 rootfstype=ext4 fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

## Install K3s

- https://drunkcoding.net/posts/ks-01-install-k3s-on-pi-cluster/
- (Alt) https://everythingdevops.dev/step-by-step-guide-creating-a-kubernetes-cluster-on-raspberry-pi-5-with-k3s/

## Deploy MetalLB

- https://fernandosilva.me/3-node-k3s-cluster-with-etcd-and-metallb-4ddc7dcfb303


## Deploy Cloudflared Tunnel

- https://developers.cloudflare.com/cloudflare-one/tutorials/many-cfd-one-tunnel/




## Nextcloud

After deploying the image, it seems setting the permission via `fsGroup` or `runAsGroup` doesn't fix the issue where nextcloud requires the data folder to be `0770`. 

Alternatively you can find the pvc on the host by searching `/var/lib/rancher/k3s/storage` for the config claim. Then edit the `config.php` to include the following line. In order to disable this requirement.
```php
  'check_data_directory_permissions' => false,
```