# Lilith: Arch Linux + i3 desktop VM

**Status: built, confirmed up, pending the user's visual check in the
console.** VM 103 (`lilith`) on the Proxmox host (`pve`, 192.168.178.39),
built from the official Arch Linux cloud image. Not yet merged to `main` —
see the workflow note at the bottom.

## Specs

- VMID **103**, name **lilith**
- 4 vCPU, **16GB RAM**, **250GB disk** (`local-zfs`, virtio-scsi, btrfs
  root — confirmed grown to the full 250G, `df -h /` shows 248G available)
- Bridge `vmbr0` (same LAN as `k3s-node1`/`ai-gpu-vm`), static IP
  `192.168.178.42/24` (gateway `192.168.178.1`) via cloud-init
- `qemu-guest-agent` installed, enabled, and confirmed running —
  `agent/network-get-interfaces` correctly reports the VM's IP, satisfying
  this project's standing rule that every VM needs the guest agent for IP
  auto-discovery.

## Desktop

- **Arch Linux**, window manager **i3** (chosen over sway — more reliable
  inside a QEMU/Proxmox console).
- **German keyboard layout**, both console (`/etc/vconsole.conf`,
  `KEYMAP=de-latin1`) and X11 (`/etc/X11/xorg.conf.d/00-keyboard.conf`,
  `XkbLayout de`).
- Black-background / neon-green theme throughout: i3 borders and bar
  (`#00ff66` on `#000000`/`#001a00`), `alacritty` terminal, `dmenu`
  launcher, `i3status`. `picom` runs for subtle fading, no shadows (kept
  minimal).
- Auto-starts straight into i3: `getty@tty1` autologs in as `lilith`, whose
  `.bash_profile` runs `startx` on tty1, whose `.xinitrc` execs `i3`.
  Opening the VM's console in the Proxmox web UI should land directly in
  the i3 desktop, no login step. **This part is confirmed written and
  enabled, but not yet visually confirmed — that's the one thing left for
  the user to check.**
- Base packages (all confirmed installed): `xorg-server`, `xorg-xinit`,
  `xf86-input-libinput`, `i3-wm`, `i3status`, `i3lock`, `dmenu`,
  `alacritty`, `picom`, `ttf-dejavu`, `openssh`, `sudo`, `git`, `vim`,
  `htop`, `qemu-guest-agent`.
- User `lilith`, passwordless `sudo` (`wheel` group, matches the
  passwordless-sudo pattern already used on `k3s-node1`).

Keybindings are the standard i3 defaults (`$mod` = the Super/Windows key):
`$mod+Return` terminal, `$mod+d` dmenu, `$mod+1..5` workspaces,
`$mod+h/j/k/l` focus, `$mod+Shift+h/j/k/l` move, `$mod+Shift+q` close
window, `$mod+Shift+r` restart i3, `$mod+Shift+e` exit i3 (asks for
confirmation).

## How it was built

1. VM 103 already existed when this was picked up — created by a separate
   process (not this session) with an earlier/smaller spec (2 vCPU/4GB
   RAM/2GB disk, same IP). Rather than create a conflicting second VM, it
   was reconfigured in place: `cores=4`, `memory=16384`, a fresh
   `cipassword`, then `scsi0` resized to 250G — all before first boot, so
   nothing was lost.
2. The VM was started from the official Arch Linux cloud image
   (`Arch-Linux-x86_64-cloudimg.qcow2` /
   `archlinux-cloudimg.qcow2` from `geo.mirror.pkgbuild.com` — two copies
   ended up in `local:import` from the two separate build attempts;
   harmless, just ~600MB of unused storage, safe to remove later).
3. Proxmox's basic cloud-init fields (`ciuser`, `cipassword`, `ipconfig0`)
   brought up the `lilith` user and networking — **not** a custom
   `cicustom` snippet: the Proxmox API token available here doesn't have
   `Datastore.Allocate` on storage config, which adding the `snippets`
   content type (required for `cicustom`) would need. `/access` (and by
   extension most storage-config changes) is intentionally off-limits to
   this project's automation.
4. Everything else —packages, the keyboard layout, the i3/alacritty/
   picom/i3status theme, the autologin/autostart chain, growing the root
   filesystem — was done by SSHing into the VM directly (password auth,
   LAN-reachable) and running
   [`cloud-init/lilith-provision.sh`](../cloud-init/lilith-provision.sh).
   That script is the actual, exact thing that ran; it's committed here
   for reproducibility, not as a template that still needs executing.
5. Confirmed via SSH and via the Proxmox guest-agent API: all packages
   installed, `qemu-guest-agent` and `sshd` active, root filesystem at
   250G, keyboard config files in place, dotfiles correctly owned by
   `lilith`, and the VM's LAN IP correctly reported through
   `agent/network-get-interfaces`.

## Access

- **Console (primary):** Proxmox web UI → VM 103 → Console. Should
  auto-log into i3 as `lilith` — this is the one thing the user still
  needs to eyeball.
- **SSH:** `ssh lilith@192.168.178.42`, password auth enabled. Ask for the
  current password (not stored in this repo or anywhere persistent) or set
  your own once logged in.

## Workflow note

Per this repo's `CLAUDE.md`, this VM and this doc are **not final** until
the user confirms the desktop actually looks and works right in the
console. After that confirmation: no version bump applies here (this repo
doesn't ship a build artifact), so the remaining steps are just merging
this branch to `main` and deleting it.
