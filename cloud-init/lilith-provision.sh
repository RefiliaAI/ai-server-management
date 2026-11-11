#!/bin/bash
# Provisioning script for the "lilith" Arch Linux VM (vmid 103).
#
# Run once over SSH, right after first boot of the official Arch Linux
# cloud image (cloud-init already created the "lilith" user and brought up
# networking by that point). See docs/lilith-arch-vm.md for why this runs
# over SSH instead of as a cloud-init cicustom snippet: the Proxmox API
# token available to Claude Code in this project doesn't have
# Datastore.Allocate on storage config, which is what adding the
# "snippets" content type (required for cicustom) would need.
set -euxo pipefail

# ---- user-space config (runs as lilith) ----
mkdir -p ~/.config/i3 ~/.config/i3status ~/.config/alacritty

cat > ~/.xinitrc <<'EOF'
exec i3
EOF

cat > ~/.bash_profile <<'EOF'
[[ -z "$DISPLAY" && "$(tty)" == "/dev/tty1" ]] && exec startx -- -keeptty
EOF

cat > ~/.config/i3/config <<'EOF'
set $mod Mod4
font pango:DejaVu Sans Mono 10

exec --no-startup-id xsetroot -solid "#000000"
exec --no-startup-id picom --config ~/.config/picom.conf

client.focused          #00ff66 #001a00 #00ff66 #00ff66 #00ff66
client.focused_inactive #003311 #000000 #00ff66 #003311 #003311
client.unfocused        #003311 #000000 #336644 #003311 #003311
client.urgent           #ff0033 #000000 #ff0033 #ff0033 #ff0033
client.placeholder      #000000 #000000 #00ff66 #000000 #000000
client.background       #000000

default_border pixel 2
default_floating_border pixel 2
gaps inner 8
gaps outer 2

floating_modifier $mod

bindsym $mod+Return exec alacritty
bindsym $mod+d exec --no-startup-id "dmenu_run -nb '#000000' -nf '#00ff66' -sb '#00ff66' -sf '#000000'"
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

bindsym $mod+v split h
bindsym $mod+b split v
bindsym $mod+f fullscreen toggle
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle
bindsym $mod+a focus parent

bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5

mode "resize" {
    bindsym h resize shrink width 10 px or 10 ppt
    bindsym j resize grow height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow width 10 px or 10 ppt
    bindsym Escape mode "default"
    bindsym Return mode "default"
}
bindsym $mod+r mode "resize"

bar {
    status_command i3status
    position bottom
    colors {
        background #000000
        statusline #00ff66
        separator  #003311
        focused_workspace  #00ff66 #001a00 #00ff66
        active_workspace   #003311 #000000 #00ff66
        inactive_workspace #000000 #000000 #336644
        urgent_workspace   #ff0033 #000000 #000000
    }
}
EOF

cat > ~/.config/i3status/config <<'EOF'
general {
    colors = true
    interval = 5
    color_good = "#00ff66"
    color_degraded = "#ffaa00"
    color_bad = "#ff0033"
}
order += "ethernet _first_"
order += "wireless _first_"
order += "load"
order += "memory"
order += "tztime local"

ethernet _first_ {
    format_up = "E: %ip (%speed)"
    format_down = "E: down"
}
wireless _first_ {
    format_up = "W: (%quality at %essid) %ip"
    format_down = "W: down"
}
load {
    format = "L: %1min"
}
memory {
    format = "M: %used/%total"
    threshold_degraded = "10%"
}
tztime local {
    format = "%Y-%m-%d %H:%M"
}
EOF

cat > ~/.config/alacritty/alacritty.toml <<'EOF'
[window]
opacity = 0.95
padding = { x = 10, y = 10 }

[font]
size = 11
normal = { family = "DejaVu Sans Mono" }

[colors.primary]
background = "#000000"
foreground = "#00ff66"

[colors.cursor]
text = "#000000"
cursor = "#00ff66"

[colors.normal]
black   = "#000000"
red     = "#ff0033"
green   = "#00ff66"
yellow  = "#ffd700"
blue    = "#00aeef"
magenta = "#ff00ff"
cyan    = "#00ffff"
white   = "#ccffcc"

[colors.bright]
black   = "#003311"
red     = "#ff4466"
green   = "#33ff99"
yellow  = "#ffe066"
blue    = "#33c3ff"
magenta = "#ff66ff"
cyan    = "#66ffff"
white   = "#e6ffe6"
EOF

cat > ~/.config/picom.conf <<'EOF'
backend = "xrender";
vsync = true;
shadow = false;
fading = true;
fade-in-step = 0.05;
fade-out-step = 0.05;
EOF

# ---- system-level config + packages (needs sudo) ----
sudo bash -s <<'ROOTEOF'
set -euxo pipefail

# Grow the root filesystem to fill the 250G disk.
ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no pkname "$ROOT_DEV")
PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')
growpart "/dev/$ROOT_DISK" "$PART_NUM" || true
if [ "$(findmnt -no FSTYPE /)" = "btrfs" ]; then
  btrfs filesystem resize max / || true
else
  resize2fs "$ROOT_DEV" || true
fi

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "de"
    Option "XkbModel" "pc105"
EndSection
EOF

cat > /etc/vconsole.conf <<'EOF'
KEYMAP=de-latin1
EOF
loadkeys de-latin1 || true

cat > /etc/sudoers.d/99-wheel-nopasswd <<'EOF'
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/99-wheel-nopasswd

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin lilith --noclear %I $TERM
EOF

pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  xorg-server xorg-xinit xorg-xsetroot xf86-input-libinput \
  i3-wm i3status i3lock dmenu alacritty picom ttf-dejavu \
  openssh sudo git vim htop qemu-guest-agent

systemctl enable --now qemu-guest-agent
systemctl enable --now sshd
systemctl daemon-reload
systemctl restart getty@tty1.service || true
ROOTEOF

echo "LILITH_PROVISION_DONE"
