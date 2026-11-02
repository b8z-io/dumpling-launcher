#!/bin/sh
# Run as root on the phone:  doas sh ~/dumpling/install.sh
# 1. installs the new launcher and makes it start at boot (software drawing, capped CPU)
# 2. switches Wi-Fi to iwd, which postmarketOS's fix for this chip's modem crashes is written for,
#    with a safety net: if the phone isn't back at 192.168.68.191 four minutes after boot, it puts
#    wpa_supplicant back and reboots by itself
# 3. reboots
B=/home/user/dumpling
cd "$B" || exit 1
sha256sum -c SHA256SUMS >/dev/null || { echo "BUNDLE DAMAGED - nothing changed"; exit 1; }

echo "== 1. Launcher"
install -o user -g user -m 0644 index.html /home/user/launcher/index.html
install -m 0755 dumpling-launcher.initd /etc/init.d/dumpling-launcher
rc-update add dumpling-launcher default >/dev/null 2>&1
echo "   launcher installed, starts at boot"

echo "== 2. Wi-Fi to iwd (with automatic rollback)"
echo "   modem crashes so far this boot: $(dmesg | grep -c 'crash detected in 4080000')"
apk add iwd >/dev/null || { echo "   could not install iwd (no network?) - Wi-Fi left as it was"; IWD=no; }
if [ "${IWD:-yes}" = yes ]; then
	mkdir -p /etc/iwd /etc/NetworkManager/conf.d
	grep -q ControlPortOverNL80211 /etc/iwd/main.conf 2>/dev/null || printf '[General]\nControlPortOverNL80211=false\n' >> /etc/iwd/main.conf
	printf '[device]\nwifi.backend=iwd\n' > /etc/NetworkManager/conf.d/80-iwd.conf
	rc-update add iwd default >/dev/null 2>&1
	rc-update del wpa_supplicant default >/dev/null 2>&1
	cat > /etc/local.d/wifi-rollback.start <<'EOR'
#!/bin/sh
( sleep 240
  if ip -4 addr show wlan0 2>/dev/null | grep -q 'inet 192.168.68.191/'; then
    logger -t wifi-rollback "iwd is up at 192.168.68.191: keeping it"
    rm -f /etc/local.d/wifi-rollback.start
  else
    logger -t wifi-rollback "iwd not at 192.168.68.191 after 4 min: back to wpa_supplicant"
    rm -f /etc/NetworkManager/conf.d/80-iwd.conf /etc/local.d/wifi-rollback.start
    rc-update del iwd default; rc-update add wpa_supplicant default
    sync; reboot
  fi ) >/dev/null 2>&1 &
EOR
	chmod 0755 /etc/local.d/wifi-rollback.start
	rc-update add local default >/dev/null 2>&1
	echo "   iwd set up; rollback armed for the next boot"
fi

echo "== 3. Rebooting now. Back at 192.168.68.191 in 2-5 minutes (worst case ~8 if it rolls back)."
sync; nohup setsid sh -c "sleep 3; reboot" >/dev/null 2>&1 &
