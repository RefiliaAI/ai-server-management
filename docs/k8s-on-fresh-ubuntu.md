# Setting up Kubernetes (k3s) on a fresh Ubuntu Server

This is the lightweight k3s distribution of Kubernetes, not full upstream
`kubeadm` Kubernetes — same API, much less overhead, and the standard choice
for a single-node or small homelab cluster. Every command below was actually
run and verified against a real box (see [`phase1-proxmox-k3s.md`](./phase1-proxmox-k3s.md)
for the Proxmox-specific version of this same process).

## Prerequisites

- Fresh Ubuntu Server 22.04 or 24.04 LTS, with `sudo`/root access.
- A static IP (or a DHCP reservation) — the cluster's API endpoint is tied to
  whatever IP the node has when k3s starts.
- Unlike traditional `kubeadm` Kubernetes, k3s does **not** require disabling
  swap. Nothing to do there.
- If this is a VM (Proxmox, or any other hypervisor): install the guest
  agent too (step 7) so the hypervisor can report the VM's actual IP — easy
  to forget until something needs to auto-discover it later.

## 1. Update the system

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot   # if a new kernel was installed
```

## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sudo sh -
```

This installs k3s as a systemd service, starts it, and sets up a single-node
cluster (this node acts as both control-plane and worker). Takes under a
minute on modern hardware.

## 3. Verify the cluster is up

```bash
sudo systemctl status k3s          # should be active (running)
sudo k3s kubectl get nodes         # should show this node, STATUS = Ready
```

## 4. Get a working kubeconfig

k3s's own kubectl works immediately via `sudo k3s kubectl`. To use a normal
`kubectl` binary (locally on this box, or from another machine):

```bash
# On the node itself, avoid needing sudo every time:
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

To use it from a **different** machine, copy `/etc/rancher/k3s/k3s.yaml`
over and edit it: it defaults to `server: https://127.0.0.1:6443`, which only
works locally — change that to `https://<node-ip>:6443` before it'll work
remotely.

## 5. Smoke-test with a real workload

Don't trust "the node says Ready" alone — deploy something and confirm
networking, scheduling, and storage all actually work end to end:

```bash
kubectl create deployment hello-nginx --image=nginx
kubectl expose deployment hello-nginx --port=80 --type=NodePort
kubectl get svc hello-nginx   # note the NodePort, e.g. 3XXXX
curl http://localhost:<nodeport>
```

If that returns the nginx welcome page, the cluster is genuinely working.
Clean up after: `kubectl delete deployment hello-nginx; kubectl delete svc hello-nginx`.

## 6. What's already included

k3s ships with sane defaults out of the box, so there's nothing extra to
install for a basic working cluster:

- **Storage**: `local-path` provisioner (dynamic `PersistentVolumeClaim`
  support, backed by local disk). Fine for single-node; look at Longhorn
  only if you need multi-node replicated storage later.
- **Ingress**: Traefik, enabled by default. Disable it at install time with
  `curl -sfL https://get.k3s.io | sudo sh -s - --disable traefik` if you'd
  rather run ingress-nginx or nothing at all.
- **Load balancer**: a lightweight built-in `ServiceLB` (klipper-lb), enough
  for a homelab; look at MetalLB only if you need something more featureful.

## 7. If this is a VM: install the guest agent

Lets the hypervisor (e.g. Proxmox) report the VM's actual LAN IP —
required for any tooling that auto-discovers VMs by querying the hypervisor
API rather than the guest itself.

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

On Proxmox specifically, also make sure the VM config has the agent flag set
(`qm set <vmid> --agent enabled=1` on the Proxmox host), then confirm with
`qm agent <vmid> ping` from the Proxmox host.

## 8. Optional: Helm

Needed for any chart-based install (e.g. the Kubernetes Dashboard). Not
installed by default:

```bash
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## 9. Firewall notes

If UFW (or any firewall) is active, k3s needs at minimum:

| Port | Purpose |
|---|---|
| 6443/tcp | Kubernetes API server |
| 10250/tcp | Kubelet metrics/exec |
| 8472/udp | Flannel VXLAN (pod-to-pod networking) |

For a single-node homelab cluster with no firewall between the VM and the
rest of the LAN, none of this usually needs touching — only relevant if
you've locked the host down or are adding more nodes later.

## 10. Uninstalling

k3s installs its own uninstall script:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

## Common pitfalls (things that actually went wrong doing this for real)

- **Resizing VM memory/CPU after the fact needs a reboot** if the
  hypervisor doesn't have hotplug enabled for that VM — a `qm set --memory`
  change alone won't be picked up by the running guest.
- **Pod resource limits are capped by node capacity**: don't set a pod's
  memory limit higher than the node actually has free after OS + k3s
  overhead, or it'll never schedule.
- **`kubectl patch`/`create` commands with embedded JSON break across
  PowerShell**: PowerShell doesn't treat `\"` as an escaped quote the way
  bash does. SSH into the node and run the command directly in its own bash
  shell rather than trying to embed complex quoting in a one-liner from
  Windows.
