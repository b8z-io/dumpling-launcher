# Dumpling Launcher for LineageOS

The launcher as an Android home app for the OnePlus 5T on LineageOS. It's one activity holding a WebView around [`../launcher/index.html`](../launcher/index.html), so the page is the same file as before; here the wallpaper is the live WebGL shader on the phone's GPU (Adreno 540), not the pre-rendered video.

## Install it from the Mac

With LineageOS on the phone, plug it in over USB, turn on **Settings › System › Developer options › USB debugging** and accept the prompt on the phone. Then:

```sh
cd android
./deploy.sh
```

That builds the app, installs it, makes it the home screen and installs [Telescope](https://github.com/LunarKittyy/Telescope) from its latest release if it isn't there. If a JDK or the Android SDK is missing it installs them with Homebrew first (`openjdk@21`, `android-commandlinetools`, then the SDK parts into `~/Library/Android/sdk`); the first build also downloads Gradle and the Android plugin.

| Command | What it does |
|---|---|
| `./deploy.sh` | Build, install, set as home, install Telescope if missing |
| `./deploy.sh live` | Serve `../launcher` from the Mac (over `adb reverse`) and point the phone at it. Edit `index.html`, run `./deploy.sh reload` to see it; Ctrl‑C goes back to the page built into the APK. |
| `./deploy.sh reload` | Reload the page on the phone |
| `./deploy.sh logs` | Follow the launcher's log, the page's `console.log` lines (`FPS`, `RENDERER`, `WALLPAPER`) included |
| `./deploy.sh telescope` | Install or update Telescope |
| `./deploy.sh restore` | Give the home screen back to LineageOS's own launcher |
| `./deploy.sh build` | Just build `app/build/outputs/apk/debug/app-debug.apk` |

With the phone plugged in, **chrome://inspect** in Chrome on the Mac opens DevTools on the launcher page (debug builds).

## How it fits together

- **The page** is packed into the APK at build time straight from `../launcher` (the postmarketOS `.py` shell is left out) and served from `https://appassets.androidplatform.net/assets/index.html#android`: a secure origin rather than `file://`. `#android` gives the full-screen kiosk layout but leaves the live shader on.
- **The bridge:** the page posts JSON to `window.dumplingShell.postMessage()`, the same call it made to the postmarketOS shell:
  - `{"open": url}`: a second WebView fades in over the wallpaper, between the status bar and a strip with the home bar. Swipe up on the strip, press Home, or press Back with no page history left to come home. The wallpaper's WebView is hidden meanwhile, so the shader stops drawing.
  - `{"android": package, "name": label}`: starts that Android app (`settings` is the system Settings). Home brings you back.
- **Apps on the ring** are the `CONFIG.apps` list at the top of `index.html`. `android:` entries are package names; `only: "android"` / `only: "linux"` keeps an entry to one shell. Telescope is `com.telescope`. With no app drawer, **Settings** is on the ring so the rest of the phone stays reachable.
- **Home screen manners:** `singleTask`, so Home or the swipe-up gesture from another app comes back to the one instance (and closes whatever was open on the page); bars hidden over the wallpaper, shown in a web app; the WebViews pause while another app has the screen (so Telescope gets the GPU and CPU); a crashed web renderer is rebuilt rather than taking the launcher down; WebGL context loss is handled in the page.
- **Plain http** is allowed (`usesCleartextTraffic`) because the homelab apps on the ring are http on the LAN. Web apps get Android's file picker for uploads. They don't get camera, microphone or location.

## Files

| Path | What it is |
|---|---|
| `app/src/main/java/io/b8z/dumpling/LauncherActivity.java` | The whole app: the two WebViews, the bridge, the edge swipe, insets, lifecycle |
| `app/src/main/AndroidManifest.xml` | The HOME activity, `<queries>` so it can see other apps, cleartext for the LAN |
| `app/build.gradle` | Points the APK's assets at `../launcher`; minSdk 30, targetSdk 35 (LineageOS 22.2 is Android 15) |
| `deploy.sh` | Everything on the Mac side |

Package `io.b8z.dumpling`; AGP 9.5, Gradle 9.8 (wrapper), Java 17, one dependency (`androidx.webkit`).

## Getting LineageOS back on the phone

postmarketOS replaced LineageOS's partitions, so it's a fresh install: the [LineageOS install guide for dumpling](https://wiki.lineageos.org/devices/dumpling/install/) (bootloader is already unlocked; flash LineageOS Recovery with `fastboot`, then *Factory reset › Format data* and *Apply update › Apply from ADB* to sideload the zip). Then turn on USB debugging and run `./deploy.sh`.
