# Phase 1 runbook: Proxmox VE + k3s

**Status: executed.** Proxmox VE and k3s are live and have been for weeks — this
doc is kept as a reference for the intended process (useful for a rebuild, a
second node, or onboarding) rather than a pending to-do list. Real current state
was confirmed via SSH on 2026-09-01 and is summarized in
[Actual current state](#actual-current-state-as-of-2026-09-01) below; it differs
from — and goes well beyond — what this runbook originally described. Commands
in the numbered sections below are kept as the believed-correct process, not
necessarily an exact transcript of what was run.

Target hardware: Ryzen 9 9900X (12c/24t), 96GB DDR5-4800, 1x 1TB SSD. Proxmox VE
replaced the prior Ubuntu 24.04 headless install entirely — Proxmox VE is itself
a Debian-based hypervisor OS, it does not run on top of Ubuntu.

## Actual current state (as of 2026-09-01)

Confirmed live via SSH (`pve` = 192.168.178.39, `k3s-node1` = 192.168.178.40):

- **Proxmox**: `pve-manager/9.2.10`. Storage is single-disk ZFS (`rpool`, one
  NVMe partition, `ONLINE`, no mirror) — matches the single-point-of-failure
  caveat in [section 6](#6-backup-and-redundancy-caveats-single-disk-zfs)
  below; no external backup target confirmed set up yet.
- **k3s**: `v1.36.3+k3s1`, single node. `k3s-node1` (VMID 101) is allocated
  **8 vCPU / 54GB RAM / 200GB disk** (resized 2026-09-01 from 4 vCPU/48GB,
  applied via `qm set` + a reboot since no CPU/memory hotplug was
  configured), unpinned (no CPU affinity configured — these vCPUs are
  scheduled dynamically across the host's 24 logical CPUs, not reserving
  dedicated physical cores). Node is `Ready`. Storage class
  is the default `local-path`, as planned.
- **Minecraft — three separate deployments exist, not just one validation
  server**:
  - `prominence` namespace: `prominence-server` (Prominence II: Hasturian Era
    modpack), currently **running**, `LoadBalancer` service on `25565→30970`,
    40Gi PVC. See the RAM note in section 3 below for its memory history.
  - `ita7761` namespace: a second Minecraft deployment, currently **scaled to
    0 replicas** (stopped), `NodePort` `25565:30565` plus a voice-chat UDP
    port `24454:30454`, 20Gi PVC.
  - `e2e-extended` namespace: a third Minecraft-flavored deployment, also
    **scaled to 0**, `LoadBalancer` `25567:30566` with a separate RCON
    service, 15Gi PVC — looks like an early smoke-test from initial k3s
    validation.
- **Infrastructure beyond this runbook's original scope, also live and not
  documented anywhere in `docs/`**: a Traefik ingress fronting three services
  on custom DNS names with TLS (a `refilia-tls` secret per namespace) —
  `k8s.refilia.net` → Kubernetes Dashboard, `mon.refilia.net` → a monitoring
  dashboard, `pve.refilia.net` → a Proxmox UI reverse proxy — backed by a
  `dnsmasq` deployment in a `dns` namespace for the `*.refilia.net`
  resolution; plus an `apache-test` namespace running a simple Apache smoke
  test. This was clearly built deliberately (custom domains, real TLS certs,
  a Dashboard, a monitoring UI) but **how** isn't written down anywhere —
  worth a dedicated write-up later if reproducing this matters, e.g. before
  a rebuild.
- **Confirmed, not hypothetical**: the Kubernetes Dashboard has an
  `admin-user` ServiceAccount in the `kubernetes-dashboard` namespace, bound
  via `ClusterRoleBinding` directly to `cluster-admin`. This is a live,
  currently-active blanket admin token — exactly the anti-pattern the
  Phase 2/3 doc's credential design explicitly calls out as the wrong
  default. **Decision (2026-09-01): keep it as-is for now** — revisit before
  the Phase 2a Action Execution Gateway goes live, since an autonomous agent
  sharing this cluster is exactly the case that credential design guards
  against.

## 1. Install Proxmox VE

1. Download the latest Proxmox VE ISO from proxmox.com and write it to a USB stick
   (`dd` from another Linux box, or Rufus on Windows).
2. Boot the server from the USB stick, run the graphical installer.
3. Storage: choose **ZFS (RAID0 / single disk)** over the default ext4+LVM-thin.
   Rationale: ZFS gives VM snapshots/rollback now, and if a second drive is added
   later it can be converted into a mirror without reinstalling — ext4/LVM-thin
   would require a rebuild to get that. **This is not redundancy on its own** —
   see [section 6](#6-backup-and-redundancy-caveats-single-disk-zfs) before
   trusting this setup with anything you can't afford to lose.
4. Network: assign a static IP on the LAN during install (or via DHCP reservation
   on the router, then never let it move).
5. Set a strong root password; note the Proxmox web UI URL (`https://<ip>:8006`).

## 2. Post-install hardening/setup

Proxmox ships pointed at the paid enterprise repo by default, which will fail to
update without a subscription. **Prefer configuring this through the Proxmox web
UI** (Datacenter → Node → Updates → Repositories). Confirmed on the live host
(Proxmox VE 9.2.10): repos use the newer deb822 `.sources` format, not the old
flat `.list` files — `/etc/apt/sources.list.d/pve-enterprise.sources.disabled`
(already disabled) and `pve-no-subscription.sources`. The old `.list`-based CLI
commands previously in this doc **do not work on this version at all** (that
file doesn't exist) and have been removed rather than kept as a stale,
copy-paste-able fallback. If CLI is preferred over the UI, edit the `.sources`
files directly:

```bash
# Proxmox VE 9+: disable enterprise, enable no-subscription (deb822 format)
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update && apt full-upgrade -y
```

Create a non-root admin user for day-to-day use instead of `root@pam`:

```bash
pveum user add admin@pve --password <choose-one>
pveum aclmod / -user admin@pve -role Administrator
```

**Firewall: confirmed disabled on the live host** (`pve-firewall status` →
`disabled/running`, no `/etc/pve/firewall/cluster.fw` rules exist) — the
original intent below was apparently never actually applied. This is an open
Phase 1 hardening task, not just a step to remember for a future rebuild:
enable the Proxmox firewall at the datacenter level and allow only LAN CIDR to
the web UI (port 8006) and SSH (port 22); once the Phase 2/3 Action Execution
Gateway exists, also restrict the Proxmox API to just the gateway's IP per
that doc's network-protection requirements. Full ruleset is a detail to work
out at execution time, this is LAN-only for Phase 1 so keep it simple.

## 3. Resource budget (actuals, as of the real cluster)

`win11-vm` (VMID 200) has been permanently removed — it was only a test VM, not
needed for this project. Removing it is what makes the remaining budget actually
comfortable, without needing to shut anything down to run the full future AI
stack:

| Workload                    | vCPU (actual/start) | RAM (actual/start) | Notes |
|------------------------------|:---:|:---:|---|
| Proxmox/ZFS host reserve      | —    | 8–12GB  | headroom for the hypervisor itself, ZFS ARC, and future growth |
| k3s node (`k3s-node1`, VMID 101) | **8 actual** (of 12 physical, unpinned — see CPU note below) | **54GB actual** | resized 2026-09-01 from 4 vCPU/48GB; running Minecraft (`prominence-server`, see note below) plus monitoring/dashboard/DNS/proxmox-ui and the future Phase 2/3 orchestrator/agent services |
| AI GPU VM                     | 8–12 | 24–32GB | STT/TTS/local LLM once the GPU arrives (Phase 2b) — real footprint unknown until a model is chosen, treat as a placeholder, re-check per `phase2-3-ai-agent-architecture.md` |

Real total: 8–12GB (host) + 54GB (k3s, already allocated) + 24–32GB (future AI
GPU VM) = **86–98GB of 96GB. Headroom is now noticeably tighter than before
the resize** — the top of the AI GPU VM's placeholder range (32GB) would
technically exceed 96GB total; re-checking the real GPU VM footprint before
committing to its final size (per Phase 2b) matters more now, not less.
Still a large improvement over the earlier 3-VM budget, which didn't fit at
all without powering off `win11-vm` — removing it outright made that
tradeoff unnecessary rather than just deferred, but the k3s node resize
below spent some of that reclaimed room.

**CPU note**: `k3s-node1`'s 8 vCPUs (bumped from 4, 2026-09-01) are **not
pinned** to dedicated physical cores (confirmed: no `cpu`/`affinity`/`numa`
settings on the VM) — they're scheduled dynamically across the host's 24
logical CPUs (12 cores/24 threads). This was applied via `qm set --cores 8
--memory 55296` on Proxmox, which required a reboot of `k3s-node1` since no
CPU/memory hotplug was configured — a brief full outage of everything on
that node (confirmed all pods, including `prominence-server`, came back
healthy afterward; one transient `CrashLoopBackOff` on the Minecraft pod
self-resolved within ~90s once CoreDNS finished restarting — its
`AUTO_CURSEFORGE` init step does an online check against `api.curseforge.com`
on every startup and failed until cluster DNS was fully back).

**Real data point on Minecraft's actual footprint — and its ceiling is still
too high for this node.** `prominence-server` (a heavily modded Prominence II
pack) was found live-running with `MEMORY=40G` and `USE_AIKAR_FLAGS=true`,
which — per Aikar's own flag recommendations — sets `-Xms40G -Xmx40G`,
forcing the JVM to commit the full 40GB heap immediately regardless of load.
Measured idle usage with 0 players online was **~44.3GB**. First fix applied:
replacing `MEMORY` with `INIT_MEMORY=4G` + `MAX_MEMORY=40G` — idle usage
right after that restart measured **~9.2GB**. This solves *idle* usage but
not the *maximum*: the JVM can still legitimately grow to a 40GB heap under
real load, and with off-heap overhead the process could again approach
~44GB+ — on a 48GB node, that leaves almost nothing for k3s itself, Postgres,
n8n, the orchestrator, the gateway, and monitoring, all of which are meant to
share this same VM. The live container's `resources.limits.memory` was also
found set to `50Gi` — **exceeding the VM's entire 48GB of physical RAM**, an
impossible ceiling that provides no real protection at all, since the VM
would exhaust physical memory before that cgroup limit ever triggered.
**Corrected target, applied 2026-09-01**: `MAX_MEMORY=32G`, container
`limits.memory: 36Gi`, `requests.memory: 8Gi` (was `"0"`). Confirmed live:
the pod restarted healthy (RCON responsive, 0/20 players) at **~8.8GB**
immediately after the change. That leaves roughly 4-6GB for the OS/k3s and
6-10GB for the agent services on this node. If Minecraft genuinely needs a
40GB heap under real player load, the fix is growing this VM beyond 48GB or
moving the agent services elsewhere — not raising the ceiling on a node that
can't actually support it.

## 4. Create the k3s cluster

1. In Proxmox, build a cloud-init-enabled VM template (Debian 12 or Ubuntu 24.04
   cloud image), so future VMs can be cloned + configured without manual OS install.
2. Clone the template into one VM for the k3s node (single-node is fine for a
   homelab; add a second VM later only if HA is actually needed).
3. Install k3s, **pinned to a specific version** — do not install an unspecified
   "latest" via a bare `curl | sh`, since that's not reproducible and can pull in
   breaking changes silently on a future reinstall. The live cluster runs
   `v1.36.3+k3s1`; pin exactly that for a reproduction of current state, or
   check https://github.com/k3s-io/k3s/releases for a different target version:

   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.3+k3s1 sh -
   ```

   Record the exact version installed here once decided.
4. Pull the kubeconfig for use from outside the VM if needed:

   ```bash
   cat /etc/rancher/k3s/k3s.yaml
   ```

5. Decide at execution time whether to keep k3s's bundled Traefik ingress
   controller or swap it for ingress-nginx — either is fine for Phase 1.
6. Storage class: use the default `local-path` provisioner — sufficient for
   Minecraft and other single-node homelab workloads. Only look at Longhorn
   if/when multi-node HA is wanted.

## 5. Validate the cluster: Minecraft server

Deploy `itzg/docker-minecraft-server` as a smoke test — a good check that
storage, networking, and scheduling all work end to end.

```yaml
# k3s/minecraft.yaml (sketch — fill in exact resource numbers once the RAM
# budget in section 3 is finalized, and pick a concrete image tag)
apiVersion: v1
kind: Namespace
metadata:
  name: minecraft
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minecraft
  namespace: minecraft
spec:
  replicas: 1
  strategy:
    type: Recreate   # ReadWriteOnce PVC can't be mounted by two pods at once;
                      # the default RollingUpdate strategy would hang waiting
                      # for the old pod to release the volume.
  selector: { matchLabels: { app: minecraft } }
  template:
    metadata: { labels: { app: minecraft } }
    spec:
      containers:
        - name: minecraft
          image: itzg/minecraft-server:<pin-a-specific-tag>   # never :latest
          env:
            - { name: EULA, value: "TRUE" }
            # Start the JVM heap small and let it grow to a cap, rather than
            # pre-committing the full heap immediately — see the MEMORY vs.
            # INIT_MEMORY/MAX_MEMORY note from this project's own history.
            - { name: INIT_MEMORY, value: "2G" }
            - { name: MAX_MEMORY, value: "6G" }   # leave ~1-2GB headroom
                                                    # above this in the
                                                    # resources.limits below
                                                    # for JVM off-heap overhead
          ports:
            - { containerPort: 25565 }
          resources:
            requests: { cpu: "1", memory: "2Gi" }
            limits: { cpu: "4", memory: "8Gi" }
          readinessProbe:
            tcpSocket: { port: 25565 }
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: 25565 }
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: minecraft-data }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: minecraft-data, namespace: minecraft }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 10Gi } }
---
apiVersion: v1
kind: Service
metadata: { name: minecraft, namespace: minecraft }
spec:
  type: NodePort
  selector: { app: minecraft }
  ports:
    # nodePort pinned explicitly so it doesn't change if the Service is ever
    # recreated — players need a stable address to connect to.
    - { port: 25565, targetPort: 25565, nodePort: 30565 }
```

Verify: `kubectl get pods -n minecraft`, then connect a Minecraft client to
`<node-ip>:30565`.

Once this is holding real world data: back it up. See section 6 — checked
directly against the live `prominence-server` deployment, no backup mod is
currently installed at all, so this needs building from scratch, not just
verifying.

## 6. Backup and redundancy caveats (single-disk ZFS)

Single-disk ZFS (as configured in step 1) gives snapshot/rollback convenience,
but it is easy to over-trust:

- **Snapshots are not backups.** A ZFS snapshot lives on the same physical disk
  as the data it snapshots — it protects against logical mistakes (a bad config
  change, an accidental delete) within the pool, not against the disk itself
  failing.
- **The SSD remains a single point of failure.** RAID0/single-disk ZFS has zero
  redundancy; a drive failure loses everything on it, snapshots included.
- **Adding a mirror disk later is not just `zpool attach`.** Proxmox's root
  pool also needs its bootloader/EFI partition replicated onto the new disk
  (`proxmox-boot-tool init` on the new disk's ESP) — `zpool attach` alone
  mirrors the data, not the ability to actually boot from the second disk if
  the first one fails.
- **Set up an external backup target and actually test a restore** before
  trusting this as anything beyond a lab. Proxmox's built-in `vzdump` can back
  up VMs/CTs to a separate target (NAS, external drive, or Proxmox Backup
  Server if one gets stood up later) — an untested backup is not a backup.

### Minecraft world backup — checked live, needs building

Before adding an independent copy mechanism, the right question is always
whether an in-game backup mod already produces application-consistent
archives — copying a live world directory mid-write with `rsync` risks a
corrupted/inconsistent copy that a mod-driven backup (which pauses or flushes
world writes first) wouldn't have. **Checked directly against the live
`prominence-server` pod** (`/data/mods`, `/data/config`): no backup mod is
installed. World is 1.9GB, `/data` total 3.4GB. So this needs to be built,
not just verified — the checklist below is what to confirm once a mod (or an
external approach) is in place:

- Which backup mod is installed, and whether it's actually enabled.
- How often it runs, and whether it pauses/flushes world writes before
  archiving (this is *why* a mod-driven backup beats a naive `rsync` of a
  live world — it produces a consistent snapshot, not a torn one).
- Where archives are stored, and how many are retained.
- Whether recent backup jobs have actually completed successfully — an
  archive file existing doesn't prove it's complete or valid.
- Whether an archive can actually be restored — untested, it isn't a backup.

**Correct design once a backup mod exists**: `Minecraft backup mod →
completed backup archive → copy archive to an external target` — not an
independent `rsync` of the live `/data/world` directory, which duplicates
what the mod already does correctly and risks copying a torn write. Whatever
copies archives off-host should either detect a completed archive
specifically (not just any file in the backup directory) or only copy files
that haven't changed for a defined period, so it never grabs an archive
mid-write. Regardless of what's in `/data` on the same PVC/VM/physical SSD:
those in-place backups protect against world corruption, accidental player
changes, and broken mod updates — they do **not** protect against the
physical SSD failing, since they live on it. Archives still need to be
copied periodically to somewhere physically separate (NAS, external drive,
another server, Proxmox Backup Server, or encrypted remote storage), and a
restore still needs to be tested — the existence of archive files doesn't
prove they contain everything required for a successful restoration.

## 7. End-to-end verification

- [ ] Proxmox web UI reachable on the LAN; create + delete a throwaway test VM
      through it successfully. (Not tested via the web UI this session — VM
      lifecycle was exercised via CLI instead: `win11-vm` was stopped and
      destroyed via `qm stop`/`qm destroy` successfully, which exercises the
      same underlying operations.)
- [x] `kubectl get nodes` shows all k3s node(s) `Ready` — confirmed
      2026-09-01: `k3s-node1` is `Ready`.
- [x] Minecraft server responsive — confirmed 2026-09-01 via RCON
      (`prominence-server`, 0/20 players, responded to `list`) and a
      successful config change + rollout. Not separately verified by
      actually joining with a Minecraft client this session.

## 8. Repo workflow

Per `CLAUDE.md`: this work happens on a branch, gets pushed, and the user verifies
the running system works before anything merges to `main`. Only after their
explicit confirmation: bump version, merge, delete the branch, cut a GitHub release.
