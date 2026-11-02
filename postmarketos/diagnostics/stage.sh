#!/bin/sh
# Launcher tests, one stage at a time, run as `user` on the phone:   sh stage.sh plain|soft|gpu|stop
#   plain  WebKit showing a simple animated page, no WebGL
#   soft   the jellyfish, with WebKit drawing in software (the GPU only shows the result)
#   gpu    the jellyfish, everything on the GPU (what froze the display)
#   stop   end whatever stage is running
# Each stage runs in the background, survives you logging out, and reports after 25 s:
# whether cage is alive or frozen in the kernel, any errors, and a screenshot at /tmp/stage-<name>.png
L="$HOME/launcher"
RT=/tmp/dumpling-rt          # our own runtime folder: logins wipe /run/user/<uid>
stage="${1:-}"

cage_pid() { pgrep -x cage | head -1; }
cage_state() { p=$(cage_pid); [ -n "$p" ] && awk '/^State/{print $2}' "/proc/$p/status" 2>/dev/null; }

if [ "$stage" = stop ]; then
	p=$(cage_pid)
	[ -z "$p" ] && { echo "nothing running"; exit 0; }
	[ "$(cage_state)" = D ] && { echo "cage is frozen in the kernel: only a reboot clears it (doas reboot)"; exit 1; }
	pkill -x cage; sleep 2; pkill -9 -x cage 2>/dev/null; pkill -f "[d]umpling-shell" 2>/dev/null
	echo "stopped"; exit 0
fi

case "$stage" in
	plain) url="file:///tmp/plain.html"; extra="" ;;
	soft)  url=""; extra="LIBGL_ALWAYS_SOFTWARE=1" ;;
	gpu)   url=""; extra="" ;;
	*) echo "usage: sh stage.sh plain|soft|gpu|stop"; exit 2 ;;
esac

if [ -n "$(cage_pid)" ]; then
	if [ "$(cage_state)" = D ]; then echo "a frozen cage is still holding the screen: reboot first (doas reboot)"
	else echo "a stage is already running: sh stage.sh stop  first"; fi
	exit 1
fi

# the shell takes its start page from DUMPLING_URL when set (patched in once, harmlessly)
python3 - "$L/dumpling-shell.py" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'HOME_URI = "file://" + os.path.join(HERE, "index.html") + "#kiosk"'
new = 'HOME_URI = os.environ.get("DUMPLING_URL") or "file://" + os.path.join(HERE, "index.html") + "#kiosk"'
if old in s:
    open(p, "w").write(s.replace(old, new))
EOF

cat > /tmp/plain.html <<'EOF'
<!doctype html><meta charset="utf-8"><title>plain</title>
<style>html,body{margin:0;height:100%;background:#04060c;color:#f39200;font:600 13vw system-ui,sans-serif;
display:grid;place-items:center}div{animation:p 2s ease-in-out infinite}@keyframes p{50%{opacity:.25}}</style>
<div>PLAIN OK</div><p id="t" style="font-size:5vw;color:#e9ecf2"></p>
<script>setInterval(()=>t.textContent=new Date().toLocaleTimeString(),500)</script>
EOF

rm -rf "$RT"; mkdir -m 0700 "$RT"
log="/tmp/stage-$stage.log"
env XDG_RUNTIME_DIR="$RT" LIBSEAT_BACKEND=seatd GSK_RENDERER=gl WEBKIT_DISABLE_DMABUF_RENDERER=1 \
	setsid nohup dbus-run-session -- cage -s -- env $extra ${url:+DUMPLING_URL=$url} \
	python3 "$L/dumpling-shell.py" >"$log" 2>&1 </dev/null &

echo "== stage '$stage' started; checking in 25 s"
sleep 25
st=$(cage_state)
case "$st" in
	"") echo "RESULT: cage exited (it failed to start)";;
	D)  echo "RESULT: FROZEN - cage is stuck in the kernel. Reboot before the next stage: doas reboot";;
	*)  echo "RESULT: alive (cage state $st)";;
esac
sock=$(ls "$RT" 2>/dev/null | grep -m1 '^wayland-[0-9]*$')
if [ -n "$sock" ] && [ "$st" != D ]; then
	XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$sock" timeout 10 grim "/tmp/stage-$stage.png" \
		&& echo "screenshot: /tmp/stage-$stage.png" || echo "screenshot failed"
fi
echo "== errors from this stage"
grep -vE 'INFO|GL_|EGL|a11y|atspi|portal|Xwayland|XWayland|EDID|^$' "$log" | tail -15
