# postmarketOS on the OnePlus 5T: what we hit and what fixed it

Oct–Nov 2026. Everything here was found the hard way; it's written down so none of it has to be found again.

## The setup

- **Phone:** OnePlus 5T, model ONEPLUS_A5010, codename `dumpling` (it was thought to be a OnePlus 6 until adb said otherwise). Bootloader unlocked; LineageOS 22.2 (Android 15) before the wipe. No A/B slots.
- **OS:** postmarketOS v25.12, **console** UI, mainline kernel **6.0** (`device-oneplus-dumpling-kernel-mainline`). The 5T is in postmarketOS's *testing* tier.
- **Build:** pmbootstrap 3.12.1 inside **Colima** on the MacBook Pro. The Colima VM is x86_64, so aarch64 builds run under qemu (a full image takes ~20 min; re-runs are quicker).
- **Flash:** `fastboot flash boot boot.img` and `fastboot flash userdata oneplus-dumpling.img` from the Mac.
- **Network:** home Wi‑Fi, DHCP reservation `192.168.68.191` in OPNsense, Tailscale.

## Where it ended up

Working: boots straight into the launcher; tap for the orb, press-and-drag to open apps (Home Assistant loads); Wi‑Fi stays up with a watchdog behind it; SSH by key.
Not working: GPU (everything is drawn in software, so it's never smooth); no on-screen keyboard; native apps (the terminal) can't be typed into or left; camera (so no Telescope). Parked in favour of LineageOS.

## Problems, causes and fixes

### Building and flashing

| Problem | Cause | Fix |
|---|---|---|
| `pmbootstrap` refuses to run | `kpartx` missing in the VM | `apt-get install kpartx` |
| Work path ended up as a pasted command under `/Users/...` | a stray paste at the prompt | Work path must be on the VM's own disk (`/home/...`), never the `/Users` mount |
| Built `qemu-amd64` instead of the phone | Enter pressed through vendor/device | Vendor `oneplus`, device `dumpling`; check with `pmbootstrap config device` |
| `android-tools-img2simg` not found | sparse-image tool unavailable | `pmbootstrap install --no-sparse`; fastboot handles the plain image |
| `No space left on device` while filling the image | an active chroot's mounts got copied into the rootfs | `pmbootstrap shutdown` before every `install` |
| Edits to the device package ignored | same version number, so apk kept the old one; and on this device `deviceinfo` ships in the **kernel-mainline** subpackage | bump `pkgrel`, `pmbootstrap checksum`, `build --force` |
| Launcher files missing on the phone | files placed in the rootfs chroot didn't all survive into the image | check inside the image after `install`; `rebuild.sh` now verifies and refuses to export if anything is missing |
| apk "hangs" in scripts | apk asks `Do you want to continue [Y/n]?`; hidden output hides the question | `yes \| apk add ...` |
| `iwd` won't install | `/etc/iwd/main.conf` is owned by `soc-qcom-msm8998-nonfree-firmware` | `apk add --force-overwrite iwd` (then re-add its setting, see Wi‑Fi) |

### Getting in

| Problem | Cause | Fix |
|---|---|---|
| Mac can't use the phone's USB networking | the kernel only has `usb_f_rndis`; postmarketOS asks for NCM and falls back to RNDIS; macOS has no RNDIS driver. Setting `ecm.usb0` doesn't help: no `usb_f_ecm` in this kernel | Use Wi‑Fi, or USB from a **Linux** host (`ssh user@172.16.42.1`) |
| No way to log in at the phone | console UI, no on-screen keyboard | Bake Wi‑Fi in: a NetworkManager keyfile in `/etc/NetworkManager/system-connections/` in the rootfs |
| New IP every boot; reservation misses | **ath10k_snoc picks a random MAC on every boot** (msm8998-mainline issue #21) | `cloned-mac-address=66:a3:bc:91:be:36` in the keyfile; the reservation then holds |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | every flash makes new host keys | `ssh-keygen -R 192.168.68.191` |
| Tailscale login hangs | clock boots at 1970 (no RTC across power loss), TLS fails | `chrony` at boot |
| DNS dead after `tailscale up` | Tailscale points resolv.conf at 100.100.100.100 | `tailscale up --accept-dns=false` |
| DNS dead in the built image | the build leaves **Colima's** DNS (`192.168.5.1`) in `/etc/resolv.conf`, and NetworkManager doesn't replace a plain file | `[main] rc-manager=file` in NetworkManager's conf.d |

### Wi‑Fi dropping

| Finding | Detail |
|---|---|
| Not power saving | Turning power save off from first boot didn't stop it (kept off anyway). |
| **Modem crashes take the Wi‑Fi down** | On msm8998 the WCN3990 Wi‑Fi firmware runs on the modem DSP. dmesg showed `qcom-q6v5-mss ... fatal error received: dog_hb.c:266:DOG_HB detects starvation`, six times in the first ~9 min after boot; usually `ath10k_snoc ... device successfully recovered`, sometimes not. |
| **diag-router** | The Wi‑Fi firmware crashes without `diag-router`. It comes with `soc-qcom-msm8998-nonfree-firmware` (enables it at boot), which **nothing pulls in for the 5T**: add it explicitly. With it: far fewer drops, stable after the first ~10 min. |
| Watchdog | `/etc/local.d/wifi-watchdog.start` (from `phone-fix.sh`): no gateway for 2 min, restart NetworkManager; 6 min, save the kernel log and reboot. |
| iwd | postmarketOS's other msm8998 workaround (`ControlPortOverNL80211=false`) only applies to iwd. Under iwd the pinned MAC wasn't used, so the phone came up at a different address; the automatic rollback put wpa_supplicant back. Not adopted. |

### The GPU

Any client that draws with the GPU wedges the msm display driver: WebKit, GTK's GL renderer, even the `eglgears_wayland` demo. A kernel worker (`kworker/u16:…+e`) and then `seatd` and `cage` go into `D` state (`__flush_work`) and can't be killed. The screen goes black, nothing new can take the display, and shutdown hangs (at the boot-splash's `chvt 7`). There's no sysrq and no `/dev/watchdog` on this kernel, so only the power button recovers it. The log repeatedly shows `MESA: warning: Failed to set BO metadata with DRM_MSM_GEM_INFO: -22`; the likely cause is Mesa 25 against the 6.0 kernel. cage compositing on the GPU with software-drawn clients is fine.

**Workaround (in use):** draw everything in software:
`WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1 GSK_RENDERER=cairo WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 WEBKIT_DISABLE_DMABUF_RENDERER=1`, the launcher at `nice -n 10` on at most 4 cores (`LP_NUM_THREADS=4`).

**Untried fix:** a newer kernel (the device package also offers `kernel-alpine`, unpatched linux-stable).

### Performance

- The live shader in software: **7–8 fps** at 378×756 even in "lite" mode (one mesh sheet).
- So the wallpaper is pre-rendered (`render/`) and played as `<video loop>`: better, still not perfectly smooth (full-screen video composited in software). Needs `gst-plugins-good` (MP4) and `gst-libav` (H.264) for WebKit.
- WebKit reports the WebGL renderer as **`Apple GPU`** (a privacy mask), so the page can't detect software drawing; kiosk mode forces the video instead (`CONFIG.forceVideo`).

### cage, GTK and WebKit quirks

| Symptom | Cause | Fix |
|---|---|---|
| Shell exits: `Unable to acquire session bus` | `Gtk.Application` needs a session D-Bus | run under `dbus-run-session`; `Gio.ApplicationFlags.NON_UNIQUE` |
| WebKit page process can't start | sandbox helpers missing | install `bubblewrap` and `xdg-dbus-proxy` (keep the sandbox on) |
| cage crashes: `wlr_xdg_surface_schedule_configure` assertion | `win.fullscreen()` before the window is mapped (cage 0.2.1) | don't ask for fullscreen; cage fills the screen anyway |
| A "Dumpling" title bar | client-side decorations | `win.set_decorated(False)` |
| GTK probes Vulkan, fails | Turnip doesn't support the Adreno 540 | `GSK_RENDERER=gl` (or `cairo` for software) |
| cage can't create its socket at boot | `/run/user` doesn't exist yet | create `/run/user` first; later moved to `/run/dumpling` (below) |
| Socket vanishes; screenshots and restarts fail | `openrc-user-pam` **wipes and recreates `/run/user/<uid>` on every SSH login** | the launcher uses its own runtime dir, `/run/dumpling` |
| Restart: `Could not poll connection: Broken pipe` | the old cage still holds the seat; seatd turns the new one away | `stop_post` kills cage, waits, then `kill -9` |
| `pkill -u` does nothing | BusyBox `pkill` has no `-u` | plain `pkill -x cage` |
| `pkill -f dumpling-shell.py` kills the SSH session | it matches its own command line | pattern `"[d]umpling-shell"` |
| Taps do nothing | WebKit on the phone sends **touch events** (plus emulated clicks), never pointer events | handle `touchstart`/`touchmove`/`touchend` |
| Long press shows Back/Forward/Stop/Reload | WebKit's context menu | `contextmenu` → `preventDefault()` |
| `FROZEN` false alarms in tests | `D` state is also normal while WebKit loads from flash | check for `D` that persists |

### Still open

- **No on-screen keyboard.** Console UI + cage has none; native windows (foot) can't be typed into, and there's no way back from them to the launcher. Options were a web terminal inside the launcher plus an on-screen keyboard in the page.
- Uptime Kuma, Homarr and Immich have no addresses on the ring yet.
- Reboots from software hang whenever the display driver has wedged.

## If coming back to Linux on this phone

1. Try the `kernel-alpine` (linux-stable) kernel for the GPU, first with `eglgears_wayland` in cage, before anything else.
2. Rebuild with `postmarketos/rebuild.sh`: it already bakes in diag-router, the pinned MAC, NetworkManager DNS, chrony, the launcher, the video and its codecs, and checks the image before exporting.
3. Keep a Linux machine handy for USB SSH (`172.16.42.1`); the Mac can't.

## LineageOS (from Nov 2026)

The launcher now runs as an Android home app; see [android/README.md](android/README.md). What's settled so far:

- **Telescope** is package `com.telescope` (minSdk 26); its latest APK is always at `github.com/LunarKittyy/Telescope/releases/latest/download/Telescope.apk`, which `deploy.sh` installs.
- **Network:** Android uses the hardware Wi‑Fi MAC here (Settings › Wi‑Fi › Privacy › Use device MAC); the OPNsense reservation is now **192.168.68.195** (`.191` was the pinned postmarketOS MAC). adb works over USB regardless; another adb device on the Mac (`Ucamera001`) means passing `ANDROID_SERIAL=8e6e7236`.
- **Telescope: don't use camera 3.** LineageOS lists it, the HAL opens it, then refuses every capture request (`QCamera3HWI`, `Unable to submit capture request 0 to HAL device: Function not implemented (-38)`; Telescope shows `Camera2 error code 4`). Telescope reopens the last lens on every start, so one switch to it fails every start after: pick the main back camera (0) on the phone, or clear Telescope's storage and pair again.
- **Tailscale** is on the phone (APK from pkgs.tailscale.com; no Play Store on LineageOS), always-on VPN, battery unrestricted.
- **No app drawer**, so Settings is on the ring; `./deploy.sh restore` hands the home screen back to Trebuchet if anything goes wrong.
- **The page needed little change:** `#android` gives the kiosk layout without forcing the video (the GPU should draw the shader live; the page still falls back to the video if WebGL reports SwiftShader), and `window.dumplingShell.postMessage()` mirrors the postmarketOS shell's message handler.
- The build was checked off the phone (APK builds; the page's ring, bridge messages and Home were driven in headless Chrome). **Still to see on the phone:** the shader's frame rate on the Adreno 540 (`./deploy.sh logs`, look for `FPS`; lower `renderScale` if it struggles) and the swipe-up strip next to LineageOS's own gesture bar.
