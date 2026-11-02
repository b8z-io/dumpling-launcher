#!/bin/sh
# Does GTK draw a window under cage at all? Two runs, a screenshot each, ~1 minute in total.
#  A: a bare GTK window (orange text on dark blue), GTK's software renderer
#  B: the plain WebKit test page, GTK's software renderer
RT=/tmp/dumpling-rt
cat > /tmp/gtk-test.py <<'EOF'
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, Gtk
css = Gtk.CssProvider()
css.load_from_data(b"window{background:#04060c} label{color:#f39200;font-size:60px;font-weight:bold}")
def go(app):
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, 600)
    w = Gtk.ApplicationWindow(application=app); w.set_child(Gtk.Label(label="GTK OK")); w.present()
a = Gtk.Application(application_id="io.b8z.gtktest", flags=Gio.ApplicationFlags.NON_UNIQUE)
a.connect("activate", go); a.run([])
EOF

stop() { pkill -x cage 2>/dev/null; sleep 2; pkill -9 -x cage 2>/dev/null; sleep 1; }
run() {  # name, command...
	name=$1; shift
	stop; rm -rf "$RT"; mkdir -m 0700 "$RT"
	env XDG_RUNTIME_DIR="$RT" LIBSEAT_BACKEND=seatd GSK_RENDERER=cairo WEBKIT_DISABLE_DMABUF_RENDERER=1 \
		setsid nohup dbus-run-session -- cage -s -- "$@" >"/tmp/$name.log" 2>&1 </dev/null &
	sleep 20
	p=$(pgrep -x cage | head -1); st=$( [ -n "$p" ] && awk '/^State/{print $2}' /proc/$p/status )
	sock=$(ls "$RT" 2>/dev/null | grep -m1 '^wayland-[0-9]*$')
	echo "== $name: cage state ${st:-exited}"
	[ -n "$sock" ] && [ "$st" != D ] && XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$sock" timeout 10 grim "/tmp/$name.png"
	[ -f "/tmp/$name.png" ] && python3 -c "
import zlib,struct,sys
d=open('/tmp/$name.png','rb').read()
print('   screenshot', len(d), 'bytes')" 2>/dev/null
	grep -vE 'INFO|GL_|EGL|a11y|atspi|portal|Xwayland|XWayland|EDID|^$' "/tmp/$name.log" | tail -8
}
rm -f /tmp/A-gtk.png /tmp/B-webkit.png
run A-gtk python3 /tmp/gtk-test.py
[ "$st" = D ] && { echo "FROZEN on the bare GTK test: reboot needed"; exit 1; }
run B-webkit env DUMPLING_URL=file:///tmp/plain.html python3 "$HOME/launcher/dumpling-shell.py"
echo "== leaving B running: look at the phone"
