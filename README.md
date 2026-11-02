# Dumpling Launcher

A home screen for an old OnePlus 5T (codename **dumpling**): a living wallpaper of the orange jellyfish mesh from the ISE 2027 screensaver, with no buttons. Tap anywhere and an orb appears; press the orb and swipe towards an app to open it; swipe up from the bottom edge to come home.

First built on **postmarketOS** (Linux) in Oct–Nov 2026. It works there, but the phone's Linux support turned out too limited for it to be pleasant (no GPU, no on-screen keyboard, flaky modem/Wi‑Fi), so this part is **parked** and the next version targets **LineageOS** (Android). Everything learned is in [NOTES.md](NOTES.md).

## What's here

| Path | What it is |
|---|---|
| `launcher/index.html` | The launcher page. Open it in any desktop browser to try it: on a desktop it shows the phone screen with notes beside it; with `#kiosk` it fills the screen, as on the phone. App list and settings are in the `CONFIG` block at the top of the script. |
| `launcher/jellyfish-loop.mp4` | The wallpaper pre-rendered: a 30 s seamless loop, 540×1080, H.264. Used instead of the live shader when there's no GPU (the phone's kiosk mode always uses it). |
| `launcher/dumpling-shell.py` | The phone-side kiosk shell (Python, GTK 4, WebKitGTK 6): a full-screen window showing the page, a second web view for apps, swipe-up-to-go-home. |
| `render/` | Re-renders the video loop from the shader in `index.html`: `make-render-page.py`, then `render.js` (headless Chromium, ~10 min), then `encode.py` (crossfades the seam, encodes with ffmpeg). |
| `postmarketos/` | Building, installing and running it on postmarketOS. `rebuild.sh` builds a complete image with everything baked in (run inside Colima on the Mac); `dumpling-launcher.initd` is the boot service; the `install*.sh` scripts install onto a running phone; `phone-fix.sh` adds the Wi‑Fi watchdog and logging. |
| `postmarketos/diagnostics/` | The staged tests used to find what freezes the display: `swtest.sh` (all-software stack), `stage.sh` (plain page / software / GPU), `gtktest.sh` (bare GTK). |

## The gesture

1. **Tap** anywhere: an orb appears there, and a ripple runs through the wallpaper.
2. **Press the orb and drag** towards an app on the ring; let go to open it. A tap on the orb instead leaves the ring open to tap.
3. In an app, **swipe up from the bottom edge** to go home. Long-press menus are switched off.

Touch is handled from touch events as well as pointer events: WebKit on the phone sends touch events and emulated clicks, never pointer events.
