# Lilith: Arch Linux + i3 desktop VM

**Status: built, pending user verification in the console.** VM 103 (`lilith`)
on the Proxmox host (`pve`, 192.168.178.39), built from the official Arch
Linux cloud image with a fully custom first-boot config. Not yet merged to
`main` — see the workflow note at the bottom.

## Specs

- VMID **103**, name **lilith**
- 4 vCPU, **16GB RAM**, **250GB disk** (`local-zfs`, virtio-scsi, same bus
  type as the other VMs on this host)
- Bridge `vmbr0` (same LAN as `k3s-node1`/`ai-gpu-vm`), DHCP
- `qemu-guest-agent` installed and enabled from first boot, per the
  project's standing rule that every VM needs it for IP auto-discovery.

## Desktop

- **Arch Linux**, window manager **i3** (chosen over sway — more reliable
  inside a QEMU/Proxmox console; swapping to sway later is just a package
  swap plus a session-start change, not a rebuild).
- **German keyboard layout**, both console (`/etc/vconsole.conf`,
  `KEYMAP=de-latin1`) and X11 (`/etc/X11/xorg.conf.d/00-keyboard.conf`,
  `XkbLayout de`).
- Black-background / neon-green theme throughout: i3 borders and bar
  (`#00ff66` on `#000000`/`#001a00`), `alacritty` terminal, `dmenu` launcher,
  `i3status`. `picom` runs for subtle fading, no shadows (kept minimal).
- Auto-starts straight into i3: `getty@tty1` autologs in as `lilith`, whose
  `.bash_profile` runs `startx` on tty1, whose `.xinitrc` execs `i3`. Opening
  the VM's console in the Proxmox web UI should land directly in the i3
  desktop, no login step.
- Base packages: `xorg-server`, `xorg-xinit`, `xf86-input-libinput`,
  `i3-wm`, `i3status`, `i3lock`, `dmenu`, `alacritty`, `picom`,
  `ttf-dejavu`, `openssh`, `sudo`, `git`, `vim`, `htop`, `qemu-guest-agent`.
- User `lilith`, passwordless `sudo` (`wheel` group, matches the
  passwordless-sudo pattern already used on `k3s-node1`).

Keybindings are the standard i3 defaults (`$mod` = the Super/Windows key):
`$mod+Return` terminal, `$mod+d` dmenu, `$mod+1..5` workspaces,
`$mod+h/j/k/l` focus, `$mod+Shift+h/j/k/l` move, `$mod+Shift+q` close
window, `$mod+Shift+r` restart i3, `$mod+Shift+e` exit i3 (asks for
confirmation).

## How it was built

Everything beyond the base Proxmox `qm create`/resize calls lives in
[`cloud-init/lilith-user-data.yaml`](../cloud-init/lilith-user-data.yaml),
fetched by Proxmox straight from this repo's branch via `download-url` and
attached as a cloud-init `cicustom` snippet — no secrets in it, so it's safe
to keep in git. It writes the keyboard/theme/autologin config (via
`/etc/skel`, so it lands in `/home/lilith` with correct ownership once the
account is created) and runs one script, `/root/lilith-setup.sh`, that
refreshes the `archlinux-keyring`, upgrades, installs the package list
above, grows the root filesystem to fill the 250GB disk, and enables
`qemu-guest-agent`/`sshd`.

Roughly, in order:

1. `local` storage's content types were extended to include `snippets`
   (needed to host the cloud-init file; previously only
   `vztmpl,backup,import,iso`).
2. The cloud-init snippet was pulled from this repo's branch:
   `download-url` into `local:snippets/lilith-user-data.yaml`.
3. The official Arch Linux cloud image
   (`Arch-Linux-x86_64-cloudimg.qcow2` from
   `geo.mirror.pkgbuild.com`) was pulled into `local:import/...`.
4. VM 103 was created with that image as `scsi0` (via Proxmox's
   `import-from`), a `cloudinit` drive on `ide2`, `cicustom` pointing at the
   snippet above, `agent: enabled=1`, 4 cores, 16384MB RAM.
5. `scsi0` was resized to 250G before first boot (the setup script also
   grows the filesystem itself as a backstop).
6. VM started; cloud-init's `runcmd` does the rest on first boot.
7. Once `qemu-guest-agent` came up, the console login password for user
   `lilith` was set directly via `qm agent ... chpasswd` (not via
   cloud-init, so it's never been written to a file or to git) and handed
   to the user out of band.

## Access

- **Console (primary):** Proxmox web UI → VM 103 → Console. Auto-logs into
  i3 as `lilith`.
- **SSH:** `sshd` is enabled with password auth; ask for the console
  password if you want to SSH in instead, or drop your own key into
  `~lilith/.ssh/authorized_keys` once logged in.

## Workflow note

Per this repo's `CLAUDE.md`, this VM and this doc are **not final** until
the user confirms the desktop actually looks and works right in the
console. After that confirmation: no version bump applies here (this repo
doesn't ship a build artifact), so the remaining steps are just merging
this branch to `main` and deleting it.
