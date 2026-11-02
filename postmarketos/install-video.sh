#!/bin/sh
# Run on the phone:  doas sh ~/dumpling-video/install-video.sh
# Adds the video players WebKit needs, installs the launcher with video wallpaper, restarts it.
B=/home/user/dumpling-video
cd "$B" || exit 1
sha256sum -c SHA256SUMS >/dev/null || { echo "BUNDLE DAMAGED - nothing changed"; exit 1; }
echo "== 1. Video playback support (MP4 container + H.264 decoder for WebKit)"
yes | apk add gst-plugins-good gst-libav || { echo "COULD NOT INSTALL VIDEO SUPPORT - nothing else changed"; exit 1; }
echo "== 2. Launcher + wallpaper loop"
install -o user -g user -m 0644 index.html jellyfish-loop.mp4 /home/user/launcher/
echo "== 3. Restarting the launcher (about a minute to appear)"
rc-service dumpling-launcher restart
sleep 45
echo "== Wallpaper:"
grep -E "WALLPAPER|RENDERER" /var/log/dumpling-launcher.log | tail -4
