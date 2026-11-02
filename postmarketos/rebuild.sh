#!/bin/bash
# Rebuild the phone image with everything baked in, so nothing depends on reaching the phone over Wi-Fi.
# Run inside Colima from a clone of this repo on the Mac (Colima mounts /Users):
#   colima ssh      then      bash /Users/<you>/<path>/dumpling-launcher/postmarketos/rebuild.sh
# It asks for the phone's password once (pmbootstrap install). Images land in <repo>/out.
# Optional, not in git: postmarketos/*.pub (extra SSH keys), postmarketos/tailscale-authkey.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd)
L="$REPO/launcher"
P="$REPO/postmarketos"
OUT="${OUT:-$REPO/out}"; mkdir -p "$OUT"
W=$(pmbootstrap config work)
R="$W/chroot_rootfs_oneplus-dumpling"

say() { printf '\n== %s\n' "$*"; }

say "1/6 Stopping any running chroots"
pmbootstrap shutdown

[ -d "$R/home" ] || { echo "Can't find the phone's rootfs at $R"; exit 1; }
sudo test -f "$R/etc/NetworkManager/system-connections/home.nmconnection" \
	|| { echo "The Wi-Fi connection file is missing from the rootfs; stop and tell Claude."; exit 1; }
uid=$(sudo awk -F: '$1=="user"{print $3}' "$R/etc/passwd"); uid=${uid:-10000}

say "2/6 Packages for the launcher"
# soc-qcom-msm8998-nonfree-firmware brings diag-router: without it the MSM8998 Wi-Fi firmware crashes soon after
# boot. Nothing pulls it in for the 5T, so it has to be asked for by name.
pmbootstrap config extra_packages "soc-qcom-msm8998-nonfree-firmware,tailscale,cage,seatd,mesa-dri-gallium,webkit2gtk-6.0,py3-gobject3,dbus,bubblewrap,xdg-dbus-proxy,foot,chrony,iw,gst-plugins-good,gst-libav"
pmbootstrap config ssh_keys False     # we write authorized_keys ourselves below; don't let install replace it

say "3/6 Launcher, SSH keys and fixes into the rootfs"
sudo install -d -o "$uid" -g "$uid" -m 0755 "$R/home/user" "$R/home/user/launcher"
sudo install -o "$uid" -g "$uid" -m 0644 "$L/index.html" "$L/dumpling-shell.py" "$L/jellyfish-loop.mp4" "$R/home/user/launcher/"
sudo install -d -o "$uid" -g "$uid" -m 0700 "$R/home/user/.ssh"
{ cat "$P"/*.pub 2>/dev/null || true; cat /Users/*/.ssh/*.pub 2>/dev/null || true; } | sort -u \
	| sudo tee "$R/home/user/.ssh/authorized_keys" >/dev/null
sudo chown "$uid:$uid" "$R/home/user/.ssh/authorized_keys"; sudo chmod 0600 "$R/home/user/.ssh/authorized_keys"

sudo install -d "$R/etc/NetworkManager/conf.d" "$R/etc/local.d" "$R/etc/doas.d" "$R/etc/runlevels/default"
printf '[connection]\nwifi.powersave = 2\n' | sudo tee "$R/etc/NetworkManager/conf.d/90-no-powersave.conf" >/dev/null
# the build leaves Colima's own DNS server (192.168.5.1) in resolv.conf; let NetworkManager own the file instead
printf '[main]\nrc-manager=file\n' | sudo tee "$R/etc/NetworkManager/conf.d/95-resolv.conf" >/dev/null
sudo install -m 0755 "$P/dumpling-launcher.initd" "$R/etc/init.d/dumpling-launcher"

# one Wi-Fi MAC for ever: the driver invents a new one every boot, which is why the .191 reservation kept missing
NM="$R/etc/NetworkManager/system-connections/home.nmconnection"
sudo sed -i '/^cloned-mac-address=/d' "$NM"
sudo sed -i 's/^\[wifi\]$/[wifi]\ncloned-mac-address=66:a3:bc:91:be:36/' "$NM"

# join the tailnet on first boot by itself (auth key from the Tailscale admin, saved as launcher/tailscale-authkey)
if [ -s "$P/tailscale-authkey" ]; then
	sudo install -m 0600 "$P/tailscale-authkey" "$R/etc/tailscale-authkey"
	sudo tee "$R/etc/local.d/tailscale-join.start" >/dev/null <<'EOF'
#!/bin/sh
[ -s /etc/tailscale-authkey ] || exit 0
( for i in $(seq 1 60); do
    if tailscale up --authkey="$(cat /etc/tailscale-authkey)" --hostname=dumpling --accept-dns=false >>/var/log/netlog.txt 2>&1; then
      rm -f /etc/tailscale-authkey; break
    fi
    sleep 10
  done ) &
EOF
	sudo chmod 0755 "$R/etc/local.d/tailscale-join.start"
fi

# screen never blanks
printf '#!/bin/sh\nprintf "\\033[9;0]\\033[14;0]" > /dev/tty1\n' | sudo tee "$R/etc/local.d/noblank.start" >/dev/null
# a heartbeat every 30 s: shows when Wi-Fi drops, and whether the phone was asleep (gaps in the times)
sudo tee "$R/etc/local.d/netlog.start" >/dev/null <<'EOF'
#!/bin/sh
# it also writes the address on the phone's own screen whenever it changes, so you can always see it
( echo "--- boot $(date '+%F %T')"
  last=""
  while true; do
    st="$(cat /sys/class/net/wlan0/operstate 2>/dev/null) $(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}') diag=$(pidof diag-router >/dev/null && echo on || echo OFF)"
    printf '%s %s ps=%s\n' "$(date '+%F %T')" "$st" "$(iw dev wlan0 get power_save 2>/dev/null | awk '{print $3}')"
    [ "$st" != "$last" ] && printf '\r\n[dumpling %s] wifi %s\r\n' "$(date '+%H:%M')" "$st" > /dev/tty1 2>/dev/null
    last="$st"
    sleep 30
  done ) >> /var/log/netlog.txt 2>&1 &
EOF
sudo chmod 0755 "$R/etc/local.d/noblank.start" "$R/etc/local.d/netlog.start"

# the launcher can be restarted over SSH without a password
sudo tee "$R/etc/doas.d/dumpling-launcher.conf" >/dev/null <<'EOF'
permit nopass user as root cmd rc-service args dumpling-launcher restart
permit nopass user as root cmd rc-service args dumpling-launcher stop
permit nopass user as root cmd rc-service args dumpling-launcher start
permit nopass user as root cmd rc-service args dumpling-launcher status
EOF
sudo chmod 0400 "$R/etc/doas.d/dumpling-launcher.conf"

# start at boot (the same links rc-update makes; the services arrive with the packages)
for s in seatd chronyd local tailscale sshd networkmanager dumpling-launcher; do
	sudo ln -sfn "/etc/init.d/$s" "$R/etc/runlevels/default/$s"
done
sudo install -d "$R/etc/runlevels/boot"
sudo ln -sfn /etc/init.d/diag-router "$R/etc/runlevels/boot/diag-router"   # the package does this too; belt and braces

say "4/6 Building the image (set the phone password when asked)"
pmbootstrap install --no-sparse

say "5/6 Checking the image has everything"
pmbootstrap chroot -r -- sh -c '
set -e
ls /home/user/launcher /home/user/.ssh/authorized_keys /etc/init.d/dumpling-launcher /usr/bin/cage /usr/bin/foot >/dev/null
test -x /etc/init.d/diag-router            || { echo "MISSING: diag-router (the Wi-Fi crash fix)"; exit 1; }
test -e /etc/runlevels/boot/diag-router    || { echo "MISSING: diag-router not enabled at boot"; exit 1; }
grep -q "^cloned-mac-address=66:a3:bc:91:be:36" /etc/NetworkManager/system-connections/home.nmconnection \
                                           || { echo "MISSING: pinned Wi-Fi MAC"; exit 1; }
test -s /home/user/.ssh/authorized_keys     || { echo "MISSING: SSH keys"; exit 1; }
echo "OK: launcher, keys, diag-router, pinned MAC"
ls /etc/runlevels/boot /etc/runlevels/default
if [ -e /etc/local.d/tailscale-join.start ]; then echo "OK: will join Tailscale on first boot"; else echo "NOTE: no Tailscale auth key, join by hand"; fi'
pmbootstrap shutdown

say "6/6 Exporting to ~/pmos-5t on the Mac"
pmbootstrap export
cp -fL /tmp/postmarketOS-export/boot.img "$OUT/boot.img"
cp -fL /tmp/postmarketOS-export/oneplus-dumpling.img "$OUT/oneplus-dumpling.img"
ls -l "$OUT/boot.img" "$OUT/oneplus-dumpling.img"
echo
echo "Done. Exit Colima, put the phone in fastboot (Power + Volume Up), then on the Mac:"
echo "  cd $OUT && fastboot flash boot boot.img && fastboot flash userdata oneplus-dumpling.img && fastboot reboot"
