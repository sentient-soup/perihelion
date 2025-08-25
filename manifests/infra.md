> [!CAUTION]
> This is a WIP and likely to change over time. At the time of writing, this is used more as a living document and not considered to be a guide in any way shape or form. Use at your own risk.

# Setting Core Infra

This applies to using k3s and a headless raspberry pi as nodes. It should mostly translate to any hardware.

The desired objectives of this document is to establish a k3s cluster

# Prepare Pi

```sh
# /boot/firmware/cmdline.txt
console=serial0,115200 console=tty1 root=PARTUUID=28373ef5-02 rootfstype=ext4 fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

Setup static IPs for each node.

```
sudo nmtui
```

# Install K3s

### Server

```
curl -sfL https://get.k3s.io | K3S_TOKEN=`cat .k3s_secret` INSTALL_K3S_EXEC="server --disable=servicelb --disable=traefik --flannel-backend=host-gw --write-kubeconfig-mode=644 --tls-san=192.168.1.212 --bind-address=192.168.1.212 --advertise-address=192.168.1.212 --node-ip=192.168.1.212 --cluster-init" sh -s -
```

### Agents

```sh
 curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.212:6443 K3S_TOKEN="K107d423aa1b3833294e67e077a6a765120d63adc1ce0134f55080a57fd8ba72c34::server:43a2b08467224270b93f" sh -
```

### Resources

- https://drunkcoding.net/posts/ks-01-install-k3s-on-pi-cluster/
- (Alt) https://everythingdevops.dev/step-by-step-guide-creating-a-kubernetes-cluster-on-raspberry-pi-5-with-k3s/
- (Alt) https://fernandosilva.me/3-node-k3s-cluster-with-etcd-and-metallb-4ddc7dcfb303

# Deploy MetalLB

Deploying the LB first requires setting up the namespace. Then we can deploy the metal lb instance and finally the ip pool that metallb can draw from.

```sh
ktl create -f manifests/namepsaces.yaml
ktl create -f manifests/metallb.ya0ml
ktl create -f manifests/network.yaml

```

### Resources

- https://fernandosilva.me/3-node-k3s-cluster-with-etcd-and-metallb-4ddc7dcfb303

# Setup NFS Storage

Assuming the desired storage for NFS is mounted start by installing the NFS driver, kernel server and nfs core utilities.

```sh
curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.10.0/deploy/install-driver.sh | bash -s v4.10.0 --

sudo apt update
sudo apt install nfs-kernel-server

# Also needed on all nodes
sudo apt install nfs-common
```

Next we need to add permissions for nfs to export the desired storage. Update `/etc/exports` with the desired fs. The anonuid and anongid flags can be used to force other nodes to use the user & group that owns the fs to avoid problems. However there are many ways to configure this, read through https://linux.die.net/man/5/exports for more info.

```
/media/storage  phis2.local(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)
```

Finally reload the exports file and restart the kernel server to apply the configuration.

```sh
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

The nfs should now be operable. We can test by attempting to mount in on another node.

```sh
sudo mount -t nfs phis1.local:/media/storage /media/storage
```

Then create a file from one node and verify you can see said file from another. Note that manually mounting the nfs to each node is unecessary as accessing files over the nfs will be handled by the nfs provisioner we will install in the next step. Manually mounting is purely to validate that everything is working.

NFS can be fairly finicky! [This guide](https://nfs.sourceforge.net/nfs-howto/ar01s07.html) is a handy troubleshooting guide that should help you with any issues you may run into.

### CSI Driver NFS

Using helm simply follow the steps outlined at the [CSI driver for nfs github](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/charts).

For now to keep the base deployment simple we'll avoid setting up a storage class (I've encountered a lot of problems doing as such due to my poor understanding of dynamic provisioning). In order to add a static PV/PVC for a specific use case you can follow the steps outlined in the [repo examples](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/deploy/example/README.md). But the static templates look like the following:

```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: nfs.csi.k8s.io
  name: <volume name>
spec:
  capacity:
    storage: <Desired size, IE 10Gi, 500Mi>
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-csi
  mountOptions:
    - nfsvers=4.1
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: <server>#<subdir>#<share>
    volumeAttributes:
      server: <server host>
      share: <mnt path>

---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: <volume claim name>
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  volumeName: <volume name>
  storageClassName: nfs-csi
```

### Resources

- https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/install-csi-driver-v4.10.0.md

# Deploy Cloudflared Tunnel

First create a cloudflared tunnel with a domain in the cloudflare online portal.

Next create a cloudflare api token with the `Edit DNS` permission capable of accessing the relevant domain resource. Then use the api token generated to create a kubernetes secret required for the cloudflared tunnel deployment to work successfully.

```sh
kubectl create secret generic tokens --from-literal=dns_cloudflare_api_token='<GENERATED_TOKEN>' -n network
```

> [!WARNING]
> I have not tested the following client side configuration of the ingress points. This needs work and as of writing is being done via the cloudflared web UI.

Finally before creating the cloudflared deployment, create a config a config file with the tunnel id and the desired ingress points. The config file should be placed inside the configs

```yaml
tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef

ingress:
  - hostname: gitlab.widgetcorp.tech
    service: http://localhost:80
  - hostname: gitlab-ssh.widgetcorp.tech
    service: ssh://localhost:22
  - service: http_status:404
```

### Resources

- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/#config
- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/deploy-tunnels/deployment-guides/kubernetes/#routing-with-cloudflare-tunnel
- https://developers.cloudflare.com/cloudflare-one/tutorials/many-cfd-one-tunnel/

# Generate Certificates

Acquire a cloudflare api key with access to dns zone editing for the hostname being configured. Then have certbot use said api key to verify the domain and generate keys.

First install certbot. For additional info [here.](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)

```sh
sudo apt install ...
```

Add the api key to a file with `dns_cloudflare_api_token = <token>` and then run the following command to generate the cert.

```sh
sudo certbot certonly   --dns-cloudflare   --dns-cloudflare-credentials ~/cf-api.ini -d *.<hostname>
```

sudo apt install python3-certbot-dns-cloudflare

https://www.digitalocean.com/community/tutorials/how-to-create-let-s-encrypt-wildcard-certificates-with-certbot
