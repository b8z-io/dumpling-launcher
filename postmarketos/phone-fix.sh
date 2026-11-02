#!/bin/sh
# Run on the phone, in the window after a reboot:   doas sh phone-fix.sh      (safe to run again)
# 1. shows why the Wi-Fi dropped last time, if the phone kept a record
# 2. keeps a record from now on, and a watchdog that brings the network back if it drops
# 3. finishes the launcher (D-Bus session, WebKit's sandbox helpers)

echo "== 1. Wi-Fi evidence from earlier (kernel messages)"
if [ -s /var/log/dmesg-before-reboot.txt ]; then
	echo "-- saved by the watchdog before its last reboot:"
	grep -iE 'ath10k|remoteproc|wcn|q6v5|firmware|crash|wlan0|deauth|disassoc' /var/log/dmesg-before-reboot.txt | tail -40
fi
if [ -s /var/log/messages ]; then
	grep -iE 'ath10k|remoteproc|wcn|q6v5|firmware|crash|wlan0|deauth|disassoc|wifi-watchdog' /var/log/messages | tail -40
else
	echo "(nothing recorded yet; turning recording on now, so the next drop is caught)"
fi
rc-update add syslog boot >/dev/null 2>&1; rc-service syslog start >/dev/null 2>&1
rc-update add klogd boot >/dev/null 2>&1; rc-service klogd start >/dev/null 2>&1

echo "== 2. Wi-Fi watchdog: no network for 2 min -> restart Wi-Fi; for 6 min -> save the kernel log and reboot"
cat > /etc/local.d/wifi-watchdog.start <<'EOF'
#!/bin/sh
( sleep 180; bad=0
  while true; do
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    if [ -n "$gw" ] && ping -c 2 -W 3 "$gw" >/dev/null 2>&1; then bad=0; else bad=$((bad + 1)); fi
    case $bad in
      4)  logger -t wifi-watchdog "no network for 2 min, restarting NetworkManager"
          rc-service networkmanager restart ;;
      12) logger -t wifi-watchdog "no network for 6 min, rebooting"
          dmesg | tail -300 > /var/log/dmesg-before-reboot.txt; sync; reboot ;;
    esac
    sleep 30
  done ) >/dev/null 2>&1 &
EOF
chmod 0755 /etc/local.d/wifi-watchdog.start
rc-update add local default >/dev/null 2>&1
pgrep -f wifi-watchdog.start >/dev/null || /etc/local.d/wifi-watchdog.start

echo "== 3. Launcher: D-Bus session and WebKit sandbox helpers"
apk add dbus bubblewrap xdg-dbus-proxy || { echo "apk failed (no network?) - run this again after the next reboot"; exit 1; }
P=/home/user/launcher/dumpling-shell.py
sed -i -e 's/^gi.require_version("Gtk", "4.0")$/gi.require_version("Gtk", "4.0"); gi.require_version("Gdk", "4.0")/' \
       -e 's/from gi.repository import Gdk, Gtk, WebKit/from gi.repository import Gdk, Gio, Gtk, WebKit/' \
       -e 's/application_id="io.b8z.dumpling.shell")/application_id="io.b8z.dumpling.shell", flags=Gio.ApplicationFlags.NON_UNIQUE)/' "$P"
chown user:user "$P"
sed -i 's|LIBSEAT_BACKEND=seatd /usr/bin/cage|LIBSEAT_BACKEND=seatd /usr/bin/dbus-run-session -- /usr/bin/cage|' /etc/init.d/dumpling-launcher
rc-service dumpling-launcher restart
sleep 25
echo "== Launcher log (problems only)"
grep -vE 'INFO|^$|GL_|EGL' /var/log/dumpling-launcher.log | tail -25
