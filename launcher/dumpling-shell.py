#!/usr/bin/env python3
"""Dumpling kiosk shell: one full-screen window inside cage.

The launcher page (index.html#kiosk) is the home view. When it asks to open an app it posts
{"open": url} or {"exec": cmd} to the 'shell' message handler:
  open -> a second web view slides in full screen; swipe up from the bottom edge to come home
  exec -> the command starts as its own window (cage shows it on top); closing it returns home
"""
import json
import os
import shlex
import subprocess

import gi

gi.require_version("Gtk", "4.0"); gi.require_version("Gdk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gdk, Gio, Gtk, WebKit  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
HOME_URI = os.environ.get("DUMPLING_URL") or "file://" + os.path.join(HERE, "index.html") + "#kiosk"
EDGE_PX = 36        # height of the bottom strip that takes the swipe home
SWIPE_PX = 60       # how far up the swipe has to go

CSS = b"""
window, stack { background: #04060c; }
.edge { background: alpha(#e9ecf2, 0.0); }
.edge .bar { background: alpha(#e9ecf2, 0.45); border-radius: 3px; min-height: 5px; min-width: 120px; margin: 14px 0 10px; }
"""


def settings():
    s = WebKit.Settings()
    s.set_enable_webgl(True); s.set_enable_write_console_messages_to_stdout(True)
    s.set_allow_file_access_from_file_urls(True)
    s.set_enable_developer_extras(True)
    try:
        s.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.ALWAYS)
    except Exception:
        pass
    return s


class Shell(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="io.b8z.dumpling.shell", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        win = Gtk.ApplicationWindow(application=self, title="Dumpling"); win.set_decorated(False)

        ucm = WebKit.UserContentManager()
        ucm.register_script_message_handler("shell", None)
        ucm.connect("script-message-received::shell", self.on_message)
        self.home = WebKit.WebView(user_content_manager=ucm, settings=settings())
        self.home.load_uri(HOME_URI)

        self.app_view = WebKit.WebView(settings=settings())
        overlay = Gtk.Overlay()
        overlay.set_child(self.app_view)
        edge = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.END, halign=Gtk.Align.FILL)
        edge.add_css_class("edge")
        edge.set_size_request(-1, EDGE_PX)
        bar = Gtk.Box(halign=Gtk.Align.CENTER)
        bar.add_css_class("bar")
        edge.append(bar)
        drag = Gtk.GestureDrag()
        drag.connect("drag-update", self.on_edge_drag)
        edge.add_controller(drag)
        overlay.add_overlay(edge)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=260)
        self.stack.add_named(self.home, "home")
        self.stack.add_named(overlay, "app")
        win.set_child(self.stack)
        win.present()

    def on_message(self, _ucm, value):
        try:
            msg = json.loads(value.to_string())
        except Exception:
            return
        if msg.get("open"):
            self.app_view.load_uri(msg["open"])
            self.stack.set_visible_child_name("app")
        elif msg.get("exec"):
            subprocess.Popen(shlex.split(msg["exec"]), start_new_session=True)

    def on_edge_drag(self, _gesture, _dx, dy):
        if dy < -SWIPE_PX and self.stack.get_visible_child_name() == "app":
            self.go_home()

    def go_home(self):
        self.stack.set_visible_child_name("home")
        self.app_view.load_uri("about:blank")
        self.home.evaluate_javascript("window.launcher && window.launcher.home()", -1, None, None, None, None, None)


if __name__ == "__main__":
    Shell().run([])
