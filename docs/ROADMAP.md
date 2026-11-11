# Roadmap

Hardware: Ryzen 9 9900X (12c/24t), 96GB DDR5-4800, 1TB SSD, running Proxmox VE.

## Phase 1 — Virtualization + K8s foundation

Replaced Ubuntu with Proxmox VE, stood up a k3s cluster on top of it, and
validated with a Minecraft server. See
[`phase1-proxmox-k3s.md`](./phase1-proxmox-k3s.md) for the runbook and current
real cluster state.

Status: **operational.** Core deployment is complete: Proxmox VE 9.2.10
(single-disk ZFS) and k3s v1.36.3+k3s1 (single node, `k3s-node1`) are live,
with SSH access wired up for Claude Code. Actual state goes beyond the
original scope here — custom `*.refilia.net` DNS + TLS, a monitoring
dashboard, and the Kubernetes Dashboard are also running, none of which is
documented anywhere yet. The one-off `win11-vm` test VM has been removed
entirely. `prominence-server`'s Minecraft memory config was corrected
2026-09-01 (`MAX_MEMORY=32G`, container limit `36Gi`, real `8Gi` request —
was an impossible `50Gi` limit exceeding the VM's own 48GB), and
`k3s-node1` was resized the same day from 4 vCPU/48GB to **8 vCPU/54GB**
(required a reboot; confirmed all workloads came back healthy). **Backup,
permission auditing, and final hardening remain open** — see the runbook's
"Actual current state" section for the full list (no confirmed external
backup target, no restore test, the Proxmox firewall confirmed disabled, MFA
undocumented). A near-empty disk is not a reason to defer any of this — low
storage usage doesn't reduce the risk of the single SSD failing.

The Kubernetes Dashboard's `admin-user` → `cluster-admin` binding is
confirmed live and was **deliberately left as-is for now** (explicit
decision, not an oversight) — revisit before Phase 2a's Action Execution
Gateway goes live, since that doc's credential design explicitly treats this
pattern as the wrong default for an autonomous agent sharing the cluster.

Immediate follow-up tasks:
- Verify Minecraft backup and restore process — confirmed no backup mod is
  installed on `prominence-server`, so this needs building, not just
  verifying.
- Copy backup archives off-host once they exist, and test a restoration.
- Document the Proxmox firewall's actual state and bring it in line with
  the original hardening intent (currently disabled, no rules defined).
- Document the existing DNS/TLS/monitoring/Dashboard deployment — built,
  but how isn't written down anywhere.
- Revisit the Dashboard's `cluster-admin` binding before Phase 2a ships.

## Phase 2a — Action platform (text-only, no GPU needed)

A cost-aware Capability Router that dispatches infra actions across n8n,
local models, Claude Code, and other APIs, through a fixed catalogue of
typed actions enforced by an Action Execution Gateway (risk classification,
approval, credentials, idempotency, logging — all gateway-side, not
LLM-trusted). Status: **ready to start — no GPU required.** See
[`phase2-3-ai-agent-architecture.md`](./phase2-3-ai-agent-architecture.md)
for the full design, including the recommended first vertical slice
(a read-only `vm_status` action end-to-end) and safety requirements that
must be real (not just designed) before any write/destructive action is
enabled.

## Phase 2b — GPU + local LLM

Add the XFX Radeon AI Pro R9700 32GB to a dedicated Proxmox VM (ROCm, not
CUDA), serving a local personality LLM plus STT/TTS. Status: **blocked on
the GPU arriving.**

## Phase 3 — Discord voice AI

A Discord bot (Node.js/discord.js) joins a voice channel, transcribes German
speech, chats via the local personality LLM or dispatches real infra actions
through the Phase 2a router — with risk-tiered safety checks, human approval
via Discord buttons, a killswitch, permanent action/security audit logging
with bounded retention for casual conversation transcripts, and per-user
memory boundaries, all designed to never block the conversation on a slow
action. Status: **blocked on Phase 2a and Phase 2b.** See
[`phase2-3-ai-agent-architecture.md`](./phase2-3-ai-agent-architecture.md)
for the full design.

## Lilith — Arch Linux + i3 desktop VM

A minimalist, black/neon-green i3 desktop VM (VM 103, `lilith`), built from
the official Arch Linux cloud image and provisioned over SSH (German
keyboard, 16GB RAM, 250GB disk). See [`lilith-arch-vm.md`](./lilith-arch-vm.md)
for the full build and access details. Status: **built and verified up;
pending the user's visual check of the desktop in the console.**

## Later / opportunistic

- Remote access (Tailscale or similar) — deliberately deferred out of Phase 1,
  which is LAN-only.
- Storage expansion/redundancy (second drive, ZFS mirror) — deferred until usage
  patterns from Phase 1 show whether the single 1TB SSD is actually a
  bottleneck. Not yet: `local-zfs` is at ~3.8% used as of 2026-09-01. Single
  disk remains a real single point of failure regardless of usage %, though
  (see `phase1-proxmox-k3s.md` section 6) — this is about capacity, not risk.
