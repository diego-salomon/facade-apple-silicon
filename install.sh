#!/usr/bin/env bash
#
# install.sh — play Façade (2005) on an Apple Silicon Mac, in one command.
#
# Builds a Sikarugir (Wine) wrapper headlessly, installs the Windows build of
# Façade into it, and swaps the game's dead Java 1.4.2 for a modern 32-bit JRE so
# the AI actually starts. See docs/how-it-works.md for the why.
#
# No game files, Wine engine, or Java are shipped with this script — each is
# downloaded at run time from its official source and checksum-verified.
#
#   Usage:  ./install.sh [--force] [--keep-cache]
#
# MIT licensed. Façade © 2005–2006 Procedural Arts (freeware).

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned sources (verified 2026-10-29). size|sha256|url
# ---------------------------------------------------------------------------
APP_NAME="Facade.app"
APP_DIR="$HOME/Applications/$APP_NAME"
CACHE_DIR="${FACADE_CACHE:-$HOME/Library/Caches/facade-apple-silicon}"

TEMPLATE_URL="https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz"
TEMPLATE_SHA="4b5f89eeb9ef139936bdfad33d9b420b05ea4597cb7d63376674f7a8e171321c"
ENGINE_URL="https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz"
ENGINE_SHA="203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c"
RAR_URL="https://archive.org/download/Faafade/Facade-Win.rar"
RAR_SHA="26b664af41e6143b99018aff8e4b1548eb7810f2851792dd3c175fd7c4412554"
JRE_URL="https://api.adoptium.net/v3/binary/latest/8/ga/windows/x32/jre/hotspot/normal/eclipse"
JRE_SHA="21a2c5af684a658f1484daa85eabf4961ab9de28c0efbf31da2381d77fce3b5f"

# Paths inside the Wine prefix (C: drive).
GAME_WIN_DIR="Program Files (x86)/Facade"            # where the installer puts Façade
EXE_WIN_PATH="/Program Files (x86)/Facade/util/sources/facade/animEngineStarter.exe"
JRE_DIR_NAME="j2re1.4.2_06"                          # name hardcoded in animEngineDLL.dll; must keep

FORCE=0; KEEP_CACHE=0
for a in "$@"; do case "$a" in
  --force) FORCE=1 ;;
  --keep-cache) KEEP_CACHE=1 ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# download <url> <sha256> <dest>  — cached, resumable, checksum-verified.
download() {
  local url="$1" sha="$2" dest="$3"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sha" ]; then
    info "cached: $(basename "$dest")"; return 0
  fi
  info "downloading $(basename "$dest") …"
  local try
  for try in 1 2 3; do
    if curl -fL --retry 2 -C - -o "$dest" "$url"; then
      [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sha" ] && return 0
      warn "checksum mismatch (attempt $try), re-downloading"
      rm -f "$dest"
    fi
    sleep 2
  done
  die "could not download $url (checksum/network). Delete $dest and retry."
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
preflight() {
  step "Checking your Mac"

  [ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS only."
  if [ "$(uname -m)" != "arm64" ]; then
    warn "this is tuned for Apple Silicon; on Intel the 64-bit wrapper still works but is untested here."
  fi
  info "macOS $(sw_vers -productVersion), $(uname -m)"

  # Disk space: downloads + extracted app + installed game ≈ 2 GB headroom.
  local free_gb
  free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
  [ "${free_gb:-0}" -ge 3 ] || die "need ~3 GB free in your home volume (have ${free_gb} GB)."
  info "${free_gb} GB free"

  # Rosetta 2: Wine's x86 helpers need it. Install only with consent.
  if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    info "Rosetta 2 present"
  else
    bold "Rosetta 2 is required (Wine runs Façade's 32-bit x86 code; Rosetta runs Wine's x86 parts)."
    if [ -t 0 ]; then
      read -r -p "    Install Rosetta 2 now? [Y/n] " ans
      case "${ans:-Y}" in
        [nN]*) die "Rosetta 2 is required — install it with: softwareupdate --install-rosetta --agree-to-license" ;;
      esac
    fi
    softwareupdate --install-rosetta --agree-to-license || die "Rosetta 2 install failed."
  fi

  # unar: the one external tool. macOS's bsdtar silently corrupts this RAR's
  # payload (right size, wrong bytes), so a real RAR extractor is required.
  command -v unar >/dev/null 2>&1 || die "'unar' is needed to unpack the game archive. Install it with:  brew install unar"
  info "unar present"

  # speexdec: decodes the game's ~8,400 Ogg Speex (.spk) voice clips natively, in
  # seconds. The installer's bundled decoder runs under Rosetta and takes ~30–60 min.
  command -v speexdec >/dev/null 2>&1 || die "'speexdec' is needed to decode the game audio. Install it with:  brew install speex"
  info "speexdec present"
}

# ---------------------------------------------------------------------------
# 2. Build the wrapper (template + engine), headless — no Creator/Configure.
# ---------------------------------------------------------------------------
build_wrapper() {
  step "Building the Wine wrapper"
  local tmpl_app
  tar -xJf "$CACHE_DIR/Template-1.0.24.tar.xz" -C "$WORK"
  tmpl_app=$(find "$WORK" -maxdepth 1 -name 'Template-*.app' | head -1)
  [ -d "$tmpl_app" ] || die "template did not extract as expected."
  mv "$tmpl_app" "$WORK/$APP_NAME"
  info "template 1.0.24 unpacked"

  # Engine: the tarball's wswine.bundle/ becomes Contents/SharedSupport/wine/.
  tar -xJf "$CACHE_DIR/WS12WineCX24.0.7_7.tar.xz" -C "$WORK"
  [ -d "$WORK/wswine.bundle" ] || die "engine did not extract as expected."
  rm -rf "$WORK/$APP_NAME/Contents/SharedSupport/wine"
  mv "$WORK/wswine.bundle" "$WORK/$APP_NAME/Contents/SharedSupport/wine"
  info "engine WineCX 24.0.7 placed"

  BUILD_APP="$WORK/$APP_NAME"
  SS="$BUILD_APP/Contents/SharedSupport"
  WINE="$SS/wine/bin/wine"
  chmod +x "$BUILD_APP/Contents/MacOS/Sikarugir" 2>/dev/null || true
  # Build headlessly with the engine's own wine binary (the Sikarugir launcher's
  # CLI needs GUI/bundle context; the engine does not). The launcher is only used
  # at runtime, when the user double-clicks the finished app.
  export WINEPREFIX="$SS/prefix"
  export WINEESYNC=1 WINEMSYNC=1 WINEDEBUG=-all
  export DYLD_FALLBACK_LIBRARY_PATH="$SS/wine/lib:$BUILD_APP/Contents/Frameworks"
}

# Run the engine's wine in the background (sets WINE_PID), so a process that
# refuses to exit (the Façade installer does this) can be watched and then killed.
wine_bg() { "$WINE" "$@" >/dev/null 2>&1 & WINE_PID=$!; }
wine_kill() { "$SS/wine/bin/wineserver" -k >/dev/null 2>&1 || true; kill "$WINE_PID" 2>/dev/null || true; wait "$WINE_PID" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# 3. Create prefix + install the game (unar the RAR, run the installer, watchdog).
# ---------------------------------------------------------------------------
install_game() {
  step "Creating the Windows environment"
  mkdir -p "$WINEPREFIX"
  wine_bg wineboot --init
  local drive_c="$SS/prefix/drive_c" waited=0
  while kill -0 "$WINE_PID" 2>/dev/null && [ $waited -lt 120 ]; do sleep 2; waited=$((waited+2)); done
  wine_kill
  [ -d "$drive_c" ] || die "Wine prefix was not created."
  info "prefix ready"

  step "Unpacking the installer"
  # The RAR holds one file: FacadeInstaller1.1b.exe (a 2005 Advanced Installer
  # self-extractor). unar handles this RAR's filtered compression; bsdtar does not.
  unar -quiet -force-overwrite -output-directory "$WORK" "$CACHE_DIR/Facade-Win.rar" >/dev/null \
    || die "could not unpack Facade-Win.rar with unar."
  local installer="$WORK/FacadeInstaller1.1b.exe"
  [ -s "$installer" ] || die "FacadeInstaller1.1b.exe not found after unpacking."
  cp "$installer" "$drive_c/FacadeInstaller.exe"
  info "installer unpacked ($(( $(stat -f%z "$installer") / 1048576 )) MB)"

  step "Installing Façade"
  # Façade's 2005 Advanced Installer shows a short wizard (incl. a prerequisites
  # page) on a clean prefix that it won't pass without a few clicks. So we open it
  # and the user clicks through. We only need the file COPY; the installer would
  # then spend 30–60 min decoding audio under Rosetta (speexdecode.bat), which we
  # skip and replace with a native decode below.
  printf '\n'
  bold "    A \"Façade Setup\" window is opening. Click through it:"
  info  "  • Next on the welcome + prerequisites pages (prerequisites show \"not required\"),"
  info  "  • keep the default folder  C:\\Program Files (x86)\\Facade  → Next,"
  info  "  • click Install and let it copy the files. When the copy finishes the"
  info  "    script takes over on its own (you can ignore any audio-decompression"
  info  "    window it opens — we decode the audio natively, in seconds)."
  printf '\n'
  wine_bg 'C:\FacadeInstaller.exe'
  local target="$drive_c/$GAME_WIN_DIR" key="$drive_c/$EXE_WIN_PATH"
  local sounds="$target/util/sources/facade/Sounds"
  # Wait for the MSI file copy to finish: the launcher exe is present, the audio
  # payload (.spk) has been written, msiexec has exited, and the .spk count has
  # stopped growing. The hour cap is only a safety net for a hung install.
  local spk prev=-1 stable=0 waited2=0
  while [ $waited2 -lt 3600 ]; do
    sleep 5; waited2=$((waited2+5))
    spk=$(find "$sounds" -name '*.spk' 2>/dev/null | wc -l | tr -d ' ')
    printf '\r    copying game files… %s audio clips    ' "${spk:-0}"
    if [ -f "$key" ] && [ "${spk:-0}" -gt 0 ] && ! pgrep -f 'msiexec.exe' >/dev/null 2>&1; then
      if [ "$spk" = "$prev" ]; then
        stable=$((stable+1)); [ $stable -ge 2 ] && break   # copy settled ~10 s
      else
        stable=0
      fi
      prev=$spk
    else
      stable=0
    fi
  done
  printf '\n'
  # Files are copied; stop the installer and its slow bundled decoder.
  pkill -f 'speexdec' >/dev/null 2>&1 || true
  wine_kill
  [ -f "$key" ] || die "install did not complete (animEngineStarter.exe missing) — see docs/how-it-works.md §7."
  rm -f "$drive_c/FacadeInstaller.exe"
  info "game files copied ($(du -ms "$target" | cut -f1) MB)"

  step "Decoding the audio (native)"
  # The ~8,400 voice clips ship as standard Ogg Speex (.spk); the game plays .wav.
  # Decode each once with the host speexdec — under a minute, versus ~30–60 min for
  # the installer's Rosetta decoder. Byte-for-byte compatible output.
  local total decoded=0 failed=0 w
  total=$(find "$sounds" -name '*.spk' 2>/dev/null | wc -l | tr -d ' ')
  while IFS= read -r f; do
    w="${f%.spk}.wav"
    [ -f "$w" ] && continue
    if speexdec "$f" "$w" >/dev/null 2>&1; then decoded=$((decoded+1)); else failed=$((failed+1)); fi
    [ $(( decoded % 500 )) -eq 0 ] && printf '\r    decoded %s / %s …    ' "$decoded" "$total"
  done < <(find "$sounds" -name '*.spk' 2>/dev/null)
  printf '\r    decoded %s clips%s                 \n' "$decoded" "$([ $failed -gt 0 ] && echo " ($failed failed)")"
  [ $failed -eq 0 ] || warn "$failed audio clips did not decode; the game still runs."
  DRIVE_C="$drive_c"
}

# ---------------------------------------------------------------------------
# 4. Swap the dead Java 1.4.2 for Temurin 8 (32-bit). Keep the folder name.
# ---------------------------------------------------------------------------
swap_java() {
  step "Replacing the game's 2004 Java (the black-screen fix)"
  local jre_parent="$DRIVE_C/$GAME_WIN_DIR/util"
  local dst="$jre_parent/$JRE_DIR_NAME"
  [ -d "$dst" ] || die "expected $JRE_DIR_NAME in the install — layout changed?"
  local tmp="$WORK/jre"; rm -rf "$tmp"; mkdir -p "$tmp"
  ditto -x -k "$CACHE_DIR/OpenJDK8U-jre_x86-32_windows_hotspot_8u472b08.zip" "$tmp"
  local jre_root
  jre_root=$(find "$tmp" -maxdepth 1 -type d -name 'jdk8u*-jre' | head -1)
  [ -d "$jre_root" ] || die "Temurin JRE did not extract as expected."
  [ -x "$jre_root/bin/java.exe" ] || [ -f "$jre_root/bin/java.exe" ] || die "java.exe missing in Temurin JRE."

  [ -d "$jre_parent/${JRE_DIR_NAME}.orig" ] || mv "$dst" "$jre_parent/${JRE_DIR_NAME}.orig"
  rm -rf "$dst"; mkdir -p "$dst"
  # Copy the JRE *contents* into the hardcoded folder name.
  ( cd "$jre_root" && tar -cf - . ) | ( cd "$dst" && tar -xf - )
  grep -q '1\.8\.0' "$dst/release" 2>/dev/null && info "Java 8 ($(awk -F'\"' '/JAVA_VERSION/{print $2}' "$dst/release")) in place" \
    || warn "swapped Java but could not confirm version from release file."
}

# ---------------------------------------------------------------------------
# 5. Configure: point the wrapper at the game's launcher exe (nothing else).
# ---------------------------------------------------------------------------
configure() {
  step "Configuring the wrapper"
  local plist="$BUILD_APP/Contents/Info.plist"
  # Point the wrapper at the game's launcher exe. plutil takes the key as its own
  # argument, so it handles the spaces in the key name (PlistBuddy's -c
  # string-splitting cannot). Every other display setting is left at the template
  # default — which already matches a known-good Façade wrapper (D9VK=1,
  # CNC_DDRAW=1, no virtual desktop). Turning CNC_DDRAW off or forcing an 800×600
  # desktop breaks Façade's 2D UI → "Facade is having trouble running".
  plutil -replace "Program Name and Path" -string "$EXE_WIN_PATH" "$plist"
  info "launch target set"

  # Font fix: the engine calls CreateFontA("Comic Sans MS") + wglUseFontOutlines.
  # Without that font in the prefix, Wine substitutes one with different metrics and
  # the menu text renders wrong. macOS ships the real Comic Sans MS, so install it.
  local fdir="$WINEPREFIX/drive_c/windows/Fonts" fsrc="/System/Library/Fonts/Supplemental"
  if [ -f "$fsrc/Comic Sans MS.ttf" ]; then
    mkdir -p "$fdir"
    cp "$fsrc/Comic Sans MS.ttf" "$fdir/comic.ttf"
    [ -f "$fsrc/Comic Sans MS Bold.ttf" ] && cp "$fsrc/Comic Sans MS Bold.ttf" "$fdir/comicbd.ttf"
    "$WINE" reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Comic Sans MS (TrueType)' /t REG_SZ /d 'comic.ttf' /f >/dev/null 2>&1
    "$WINE" reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' /v 'Comic Sans MS Bold (TrueType)' /t REG_SZ /d 'comicbd.ttf' /f >/dev/null 2>&1
    info "Comic Sans MS installed"
  else
    warn "Comic Sans MS not found on this Mac; the menu font will look off."
  fi

  # Mouse fix: Façade is a point-and-click game using DirectInput8. Wine's default
  # cursor warping fights the pointer and leaves the mouse unresponsive; disabling
  # the warp makes the cursor track and click normally.
  "$WINE" reg add 'HKCU\Software\Wine\DirectInput' /v MouseWarpOverride /t REG_SZ /d disable /f >/dev/null 2>&1
  "$SS/wine/bin/wineserver" -k >/dev/null 2>&1 || true
  info "mouse input fixed (DirectInput warp disabled)"
}

# ---------------------------------------------------------------------------
# 6. Finalize: de-quarantine, ad-hoc sign, move into ~/Applications.
# ---------------------------------------------------------------------------
finalize() {
  step "Finalizing"
  xattr -dr com.apple.quarantine "$BUILD_APP" 2>/dev/null || true
  codesign --force --deep --sign - "$BUILD_APP" >/dev/null 2>&1 || warn "ad-hoc code-sign skipped."
  mkdir -p "$HOME/Applications"
  rm -rf "$APP_DIR"
  mv "$BUILD_APP" "$APP_DIR"
  info "installed to $APP_DIR"
}

# ---------------------------------------------------------------------------
# 7. Self-check
# ---------------------------------------------------------------------------
verify() {
  step "Verifying"
  local dc="$APP_DIR/Contents/SharedSupport/prefix/drive_c"
  local ok=1
  [ -f "$dc/$EXE_WIN_PATH" ] || { warn "missing animEngineStarter.exe"; ok=0; }
  [ -d "$dc/$GAME_WIN_DIR/util/$JRE_DIR_NAME" ] && grep -q '1\.8\.0' "$dc/$GAME_WIN_DIR/util/$JRE_DIR_NAME/release" 2>/dev/null \
    || { warn "Java 8 not confirmed"; ok=0; }
  [ -x "$APP_DIR/Contents/SharedSupport/wine/bin/wine" ] || { warn "wine engine missing"; ok=0; }
  [ "$(plutil -extract 'Program Name and Path' raw "$APP_DIR/Contents/Info.plist" 2>/dev/null)" = "$EXE_WIN_PATH" ] \
    || { warn "launch path not set"; ok=0; }
  local snd="$dc/$GAME_WIN_DIR/util/sources/facade/Sounds" undecoded
  undecoded=$(find "$snd" -name '*.spk' 2>/dev/null | while IFS= read -r s; do [ -f "${s%.spk}.wav" ] || echo x; done | wc -l | tr -d ' ')
  [ "${undecoded:-0}" -eq 0 ] || warn "$undecoded voice clips are undecoded; re-run to finish the audio."
  [ -f "$dc/windows/Fonts/comic.ttf" ] || warn "Comic Sans MS not installed; menu text will look off."
  [ $ok -eq 1 ] || die "verification failed: the wrapper is incomplete."
  info "all checks passed"
}

# ---------------------------------------------------------------------------
main() {
  bold "Façade on Apple Silicon"
  if [ -d "$APP_DIR" ] && [ $FORCE -eq 0 ]; then
    die "$APP_DIR already exists. Re-run with --force to rebuild, or run uninstall.sh first."
  fi
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/facade.XXXXXX")"
  mkdir -p "$CACHE_DIR"

  preflight

  step "Fetching the pieces (≈ 450 MB, cached in $CACHE_DIR)"
  download "$TEMPLATE_URL" "$TEMPLATE_SHA" "$CACHE_DIR/Template-1.0.24.tar.xz"
  download "$ENGINE_URL"   "$ENGINE_SHA"   "$CACHE_DIR/WS12WineCX24.0.7_7.tar.xz"
  download "$RAR_URL"      "$RAR_SHA"      "$CACHE_DIR/Facade-Win.rar"
  download "$JRE_URL"      "$JRE_SHA"      "$CACHE_DIR/OpenJDK8U-jre_x86-32_windows_hotspot_8u472b08.zip"

  build_wrapper
  install_game
  swap_java
  configure
  finalize
  verify

  [ $KEEP_CACHE -eq 0 ] && rm -rf "$CACHE_DIR" && info "cache cleared (keep it with --keep-cache)"
  step "Done"
  bold "Play:  open \"$APP_DIR\""
  info  "Type to talk to Grace and Trip. Each session writes a transcript to"
  info  "$APP_DIR/Contents/SharedSupport/prefix/drive_c/$GAME_WIN_DIR/stageplays/"
}

main "$@"
