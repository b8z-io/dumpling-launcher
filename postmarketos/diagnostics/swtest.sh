#!/bin/sh
# Run straight after a fresh boot:   sh swtest.sh
# 0. is anything frozen before we touch the screen?
# 1. cage + terminal, no GPU at all (cage composites in software)
# 2. plain WebKit page, no GPU anywhere
# 3. the jellyfish launcher, no GPU anywhere
# Stops at the first freeze. Screenshots: /tmp/sw-*.png. The last stage is left running.
RT=/tmp/dumpling-rt
SW="WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1 GSK_RENDERER=cairo WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 WEBKIT_DISABLE_DMABUF_RENDERER=1"

frozen() { ps -o pid,stat,args | awk '$2 ~ /^D/'; }
check() { f=$(frozen); [ -z "$f" ] && { echo "   nothing frozen"; return 0; }; echo "   FROZEN:"; echo "$f" | sed 's/^/     /'; return 1; }

cat > /tmp/plain.html <<'EOF'
<!doctype html><meta charset="utf-8"><title>plain</title>
<style>html,body{margin:0;height:100%;background:#04060c;color:#f39200;font:600 13vw system-ui,sans-serif;
display:grid;place-items:center}div{animation:p 2s ease-in-out infinite}@keyframes p{50%{opacity:.25}}</style>
<div>PLAIN OK</div><p id="t" style="font-size:5vw;color:#e9ecf2"></p>
<script>setInterval(()=>t.textContent=new Date().toLocaleTimeString(),500)</script>
EOF

run() {  # name, what you should see, command...
	name=$1; see=$2; shift 2
	pkill -x cage 2>/dev/null; sleep 2; pkill -9 -x cage 2>/dev/null; sleep 1
	rm -rf "$RT"; mkdir -m 0700 "$RT"
	env XDG_RUNTIME_DIR="$RT" LIBSEAT_BACKEND=seatd $SW setsid nohup dbus-run-session -- cage -s -- "$@" \
		>"/tmp/sw-$name.log" 2>&1 </dev/null &
	echo "== $name: LOOK AT THE PHONE NOW - you should see: $see"
	sleep 20
	sock=$(ls "$RT" 2>/dev/null | grep -m1 '^wayland-[0-9]*$')
	echo "   display socket: ${sock:-none}"
	[ -n "$sock" ] && XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$sock" timeout 10 grim "/tmp/sw-$name.png" 2>/dev/null \
		&& echo "   screenshot: /tmp/sw-$name.png ($(wc -c < /tmp/sw-$name.png) bytes)"
	grep -vE 'INFO|GL_|EGL|a11y|atspi|portal|Xwayland|XWayland|EDID|^$' "/tmp/sw-$name.log" | tail -6 | sed 's/^/   log: /'
	check
}

echo "== 0. right after boot, before touching the screen"
check || { echo "The display driver was frozen before any test ran, so it isn't the launcher."; exit 1; }
run 1-terminal "a terminal with a text prompt" foot || exit 1
run 2-plain "PLAIN OK in orange, with a ticking clock" env DUMPLING_URL=file:///tmp/plain.html python3 "$HOME/launcher/dumpling-shell.py" || exit 1
run 3-jellyfish "the orange jellyfish mesh moving" python3 "$HOME/launcher/dumpling-shell.py" || exit 1
echo "== all three ran without freezing; the jellyfish is left running"
