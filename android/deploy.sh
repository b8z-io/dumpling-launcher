#!/usr/bin/env bash
# Dumpling Launcher on LineageOS: build the home app, put it on the phone over USB and make it the
# home screen. Run on the Mac with the phone plugged in and USB debugging on.
#
#   ./deploy.sh            build, install, set as home, install Telescope if it isn't there
#   ./deploy.sh live       serve ../launcher from the Mac and point the phone at it: edit index.html,
#                          then run `./deploy.sh reload` (or Ctrl-C to stop and go back to the built-in page)
#   ./deploy.sh reload     reload the page on the phone
#   ./deploy.sh logs       follow the launcher's log (the page's console.log lines included)
#   ./deploy.sh telescope  install or update Telescope from its latest GitHub release
#   ./deploy.sh restore    hand the home screen back to LineageOS's own launcher (Trebuchet)
#
# Missing tools are installed with Homebrew: a JDK (openjdk@21) and the Android command-line tools,
# then the SDK parts the build needs, into ~/Library/Android/sdk.
set -euo pipefail
cd "$(dirname "$0")"

PKG=io.b8z.dumpling
ACT="$PKG/.LauncherActivity"
SDK_PLATFORM="platforms;android-36"
SDK_BUILD_TOOLS="build-tools;36.0.0"
TELESCOPE_PKG=com.telescope
TELESCOPE_APK=https://github.com/LunarKittyy/Telescope/releases/latest/download/Telescope.apk
LIVE_PORT=8765

say() { printf '\033[38;5;208m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------------------- tools
need_brew() { command -v brew >/dev/null || die "Homebrew is needed to install $1 (https://brew.sh)"; }

setup_java() {
  if [[ -z "${JAVA_HOME:-}" ]]; then
    JAVA_HOME=$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)
    if [[ -z "$JAVA_HOME" ]]; then
      for p in /opt/homebrew/opt/openjdk@21 /usr/local/opt/openjdk@21; do
        [[ -x "$p/bin/java" ]] && JAVA_HOME="$p/libexec/openjdk.jdk/Contents/Home" && break
      done
    fi
    if [[ -z "$JAVA_HOME" ]]; then
      need_brew "a JDK"; say "Installing a JDK (openjdk@21)"
      brew install openjdk@21
      JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
    fi
  fi
  export JAVA_HOME
}

setup_sdk() {
  export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local sdkm="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "$sdkm" ]]; then
    sdkm=$(command -v sdkmanager || true)
    if [[ -z "$sdkm" ]]; then
      need_brew "the Android command-line tools"; say "Installing the Android command-line tools"
      brew install --cask android-commandlinetools
      sdkm=$(command -v sdkmanager || echo "$(brew --prefix)/bin/sdkmanager")
    fi
  fi
  if [[ ! -d "$ANDROID_HOME/platforms/android-36" || ! -d "$ANDROID_HOME/build-tools/36.0.0" || ! -x "$ANDROID_HOME/platform-tools/adb" ]]; then
    say "Installing SDK parts into $ANDROID_HOME (accepting the SDK licences)"
    mkdir -p "$ANDROID_HOME"
    yes | "$sdkm" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
    "$sdkm" --sdk_root="$ANDROID_HOME" "platform-tools" "$SDK_PLATFORM" "$SDK_BUILD_TOOLS"
  fi
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
  ADB="$ANDROID_HOME/platform-tools/adb"
}

setup_adb() {
  ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
  [[ -x "$ADB" ]] || ADB=$(command -v adb || true)
  [[ -n "$ADB" ]] || { setup_java; setup_sdk; }
}

phone() {
  local list n state
  list=$("$ADB" devices | awk 'NR>1 && NF>=2 {print $1, $2}')
  if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    # one phone and nothing else that's online: use it (other gadgets that show up offline are ignored)
    n=$(awk '$2=="device"' <<<"$list" | wc -l | tr -d ' ')
    if [[ "$n" == 1 ]]; then export ANDROID_SERIAL; ANDROID_SERIAL=$(awk '$2=="device"{print $1}' <<<"$list"); fi
    [[ "$n" -le 1 ]] || die "More than one adb device; run with ANDROID_SERIAL=<serial> (see: $ADB devices -l)"
  fi
  state=$(awk -v s="${ANDROID_SERIAL:-}" '$1==s{print $2}' <<<"$list")
  case "$state" in
    device) ;;
    unauthorized) die "The phone hasn't allowed this Mac yet: unlock it and accept the USB debugging prompt" ;;
    sideload|recovery) die "The phone is in recovery; reboot it into Android first" ;;
    *) printf 'adb sees:\n%s\n' "${list:-  (nothing)}" >&2
       die "No phone over adb. Plug it in; on the phone: Settings › About phone › tap Build number 7 times, then Settings › System › Developer options › USB debugging" ;;
  esac
  say "Phone: $("$ADB" shell getprop ro.product.model | tr -d '\r') ($("$ADB" shell getprop ro.lineage.device | tr -d '\r')), Android $("$ADB" shell getprop ro.build.version.release | tr -d '\r')"
}

# ------------------------------------------------------------------------------------------- jobs
build() {
  setup_java; setup_sdk
  say "Building (the first build downloads Gradle and the Android plugin)"
  ./gradlew --quiet assembleDebug
  APK=app/build/outputs/apk/debug/app-debug.apk
  [[ -f "$APK" ]] || die "No APK at $APK"
}

install_launcher() {
  say "Installing $PKG"
  "$ADB" install -r "$APK" >/dev/null
  say "Making it the home screen"
  "$ADB" shell cmd package set-home-activity "$ACT" >/dev/null
  "$ADB" shell am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
}

telescope() {
  local f; f="$(mktemp -d)/Telescope.apk"
  say "Downloading Telescope (latest release)"
  curl -fsSL -o "$f" "$TELESCOPE_APK" || die "Couldn't download $TELESCOPE_APK"
  say "Installing Telescope"
  "$ADB" install -r "$f" >/dev/null
  rm -f "$f"
}

has_telescope() { "$ADB" shell pm path "$TELESCOPE_PKG" 2>/dev/null | grep -q package:; }

start_page() {   # $1: the URL for the page, or "bundled"
  "$ADB" shell am start -W -n "$ACT" --es dev_url "'$1'" >/dev/null
}

live() {
  setup_adb; phone
  has_app=$("$ADB" shell pm path "$PKG" 2>/dev/null | grep -c package: || true)
  [[ "$has_app" != 0 ]] || { build; install_launcher; }
  "$ADB" reverse "tcp:$LIVE_PORT" "tcp:$LIVE_PORT" >/dev/null
  trap 'say "Back to the built-in page"; start_page bundled; "$ADB" reverse --remove "tcp:$LIVE_PORT" >/dev/null 2>&1 || true' EXIT
  say "Serving ../launcher on port $LIVE_PORT; the phone sees it at http://localhost:$LIVE_PORT"
  say "Edit launcher/index.html, then run: ./deploy.sh reload   (Ctrl-C here to stop)"
  ( sleep 1; start_page "http://localhost:$LIVE_PORT/index.html#android" ) &
  python3 -m http.server "$LIVE_PORT" --bind 127.0.0.1 --directory ../launcher >/dev/null 2>&1
}

reload() {
  setup_adb; phone
  # the dev URL gets a fresh query so the page (and its cache) really reloads
  local url
  if "$ADB" reverse --list | grep -q "tcp:$LIVE_PORT"; then
    url="http://localhost:$LIVE_PORT/index.html?r=$(date +%s)#android"
  else
    url=bundled
  fi
  start_page "$url"
}

logs() {
  setup_adb; phone
  say "Launcher log (Ctrl-C to stop)"
  "$ADB" logcat -v time -s Dumpling:V chromium:W AndroidRuntime:E
}

restore() {
  setup_adb; phone
  # any other home app but Settings' boot-time placeholder: on LineageOS that's Trebuchet
  local other
  other=$("$ADB" shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME \
    | tr -d '\r' | awk '/\//{print $1}' | grep -v -e "^$PKG/" -e '^com.android.settings/' | head -1)
  [[ -n "$other" ]] || die "No other home app on the phone"
  say "Handing the home screen back to $other"
  "$ADB" shell cmd package set-home-activity "$other" >/dev/null
  "$ADB" shell am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
}

case "${1:-}" in
  "")        setup_java; setup_sdk; phone; build; install_launcher
             if has_telescope; then say "Telescope is already installed (./deploy.sh telescope to update it)"; else telescope; fi
             say "Done: tap the wallpaper for the orb" ;;
  build)     build; say "Built $APK" ;;
  live)      live ;;
  reload)    reload ;;
  logs)      logs ;;
  telescope) setup_adb; phone; telescope ;;
  restore)   restore ;;
  *)         sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
