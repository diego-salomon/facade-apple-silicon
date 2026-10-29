# How it works — running Façade on Apple Silicon

Reverse-engineering notes behind `install.sh`. Written from a static teardown of a
**working** wrapper on a Mac Studio M1 Max (macOS 27), cross-checked against the
upstream Sikarugir release artifacts. Method: triage → static → synthesis
(reverse-engineering skill, `macos-reverse` bundle-triage checklist).

---

## 1. The problem

Façade (2005, Michael Mateas & Andrew Stern / Procedural Arts) ships as two builds:

- a **32-bit Windows** build (`FacadeInstaller1.1b.exe`), and
- a **32-bit Mac (PowerPC/Intel)** build (`Facade-Mac.dmg`).

macOS 26+ dropped 32-bit support, so the Mac build is dead on Apple Silicon. The
only path left is the Windows build under a translation layer. That means a
**Wine wrapper**, and Wine on Apple Silicon needs **Rosetta 2** (Wine runs the
x86 Windows binaries; Rosetta runs Wine's own x86 helpers).

Running the game turns out to be a four-link chain, and link 3 is where everyone
hits a wall:

```
Rosetta 2  →  Sikarugir (Wine) wrapper  →  Façade game files  →  bundled Java 1.4.2  →  OpenGL renderer
  (x86 on ARM)     (Win32 on macOS)          (the 2005 build)        ↑ BLACK SCREEN       ↑ visuals off
```

---

## 2. Anatomy of a Sikarugir wrapper (from the live teardown)

Sikarugir is the current successor to Wineskin/Kegworks. A wrapper is an ordinary
`.app` bundle — **everything in it is just files and `Info.plist` keys**, which is
what makes a headless build possible (§6). The working `Facade.app` looks like:

```
Facade.app/Contents/
├── Info.plist                 # all wrapper config lives here (see §6)
├── MacOS/
│   ├── Sikarugir              # the launcher (universal x86_64 + arm64 Mach-O)
│   ├── launcher           ->  Sikarugir   (symlink)
│   └── wineskinlauncher   ->  launcher    (symlink, back-compat)
├── Frameworks/                # MoltenVK, SDL2/3, GStreamer, SikarugirSdk.framework …
├── SharedSupport/
│   ├── wine/                  # the Wine ENGINE  → "WineCX 24.0.7 (rev 6) / wine-9.0 SikarugirCX"
│   ├── renderer/              # all backends: apple_gptk, cnc_ddraw, d3dmetal, d9vk, dxmt, dxvk, dxvk3
│   └── prefix/drive_c/        # the Wine PREFIX (the virtual C: drive)
├── Configure.app/             # the GUI config editor (NOT needed at runtime)
└── drive_c -> SharedSupport/prefix/drive_c   (convenience symlink)
```

Two pieces come from **separate upstream downloads** and the Creator GUI just
stitches them together:

| Piece | Upstream (GitHub release, stable URLs) | Matches this wrapper |
|---|---|---|
| **Template** (the skeleton `.app`) | `Sikarugir-App/Template` → `Template-1.0.24.tar.xz` | `CFBundleVersion = 1.0.24` ✓ |
| **Engine** (the Wine build) | `Sikarugir-App/Engines` → `WS12WineCX24.0.7_7.tar.xz` | engine `WineCX 24.0.7` ✓ |

The game itself lives entirely inside `prefix/drive_c/Program Files (x86)/Facade/`
(~468 MB): `readme.txt`, `stageplays/`, and `util/` (the engine, Java, and
`sources/facade/` with `animEngineStarter.exe`, `animEngineDLL.dll`, and — tellingly
— `glut32.dll`).

---

## 3. What the launcher actually runs

`Info.plist` → **`Program Name and Path = /Program Files (x86)/Facade/util/sources/facade/animEngineStarter.exe`**.

`animEngineStarter.exe` kicks off the 3D animation engine (`animEngineDLL.dll`),
which in turn **spawns a Java process** for the AI (the drama manager / natural
language understanding). The engine then **blocks waiting for that Java process**.
If Java never comes up, the 3D window stays black forever and `stageplays/` stays
empty. This is the infamous black screen.

---

## 4. The black-screen bug and the fix (link 3)

Façade bundles its own **Java 1.4.2** at `util/j2re1.4.2_06/`. That 2004-era JRE
does not start under modern Wine → the engine waits forever → black screen.

`animEngineDLL.dll` **hardcodes** the Java path and launch flags (relative to
`sources/facade/`):

```
..\..\j2re1.4.2_06\bin\java.exe  -Xms70m -Xmx150m -XX:NewSize=25m \
    -enableassertions -Xfuture -Xincgc -showversion \
    -classpath ../../classes;../../classes/jess.jar  facade.Main
```

Because the path and the folder name are baked into the DLL, **the fix is to keep
the folder name `j2re1.4.2_06` and swap its *contents*** for a modern 32-bit JRE
that still accepts those flags: **Eclipse Temurin 8 (JRE, Windows x86-32)**.

Confirmed on the working wrapper — `util/j2re1.4.2_06/release` reads:

```
JAVA_VERSION="1.8.0_472"   OS_ARCH="i586"   IMPLEMENTOR="Eclipse Adoptium"   FULL_VERSION="1.8.0_472-b08"
```

…and the original JRE is preserved next to it as `util/j2re1.4.2_06.orig/`. Java 8
still honours `-Xincgc`, `-Xfuture`, `-enableassertions`, etc., so `facade.Main`
launches, the engine unblocks, and the game reaches the name screen.

Download (verified — HTTP 307→302→200, 38.7 MB):
`https://api.adoptium.net/v3/binary/latest/8/ga/windows/x32/jre/hotspot/normal/eclipse`
→ `OpenJDK8U-jre_x86-32_windows_hotspot_8u472b08.zip` — i.e. the exact `8u472-b08`
already running in the wrapper. (`x32` JRE is mandatory: Façade is a 32-bit process.)

---

## 5. The visuals (mouse solved, text still off)

Façade uses OpenGL (`readme.txt` says *"Videocard supporting OpenGL"*, and `glut32.dll`
sits in `sources/facade/`), so the tempting hypothesis was: the DirectX shims the
template leaves on (`D9VK = 1`, `CNC_DDRAW = 1`) are useless for an OpenGL game and
are what makes "some visual elements look off." Turn them off, add an 800×600 virtual
desktop (the game's native resolution), done.

**That hypothesis is wrong, and testing it was instructive.** Setting `CNC_DDRAW = 0`
doesn't improve the visuals, it stops the game from starting at all: Façade throws
*"Facade is having trouble running… some other factor limiting the CPU"* and no
`java.exe` ever launches. Façade's 2D UI layer depends on the DirectDraw shim, so
`CNC_DDRAW` has to stay **1**. The template defaults (`D9VK = 1`, `CNC_DDRAW = 1`,
`DXVK = 0`, `D3DMETAL = 0`, no virtual desktop) already match a known-good Façade
wrapper, and the installer should leave every one of them alone (see §6).

An 800×600 virtual desktop **is** compatible (the game still starts with it), but it
does **not** fix the real symptoms. A quick reverse-engineering pass on the engine
binaries (`rabin2 -i` / `-zz` over `animEngineDLL.dll` and `glut32.dll`) pinned down
both, and one of the two is now fixed:

- **Mouse — solved.** The engine takes input through **DirectInput8**
  (`DINPUT8.DirectInput8Create`) and also calls `SetCursorPos`/`ClipCursor`. Façade is
  a point-and-click game, not a mouselook one, so Wine's default cursor warping fights
  the pointer and the mouse goes dead. Setting
  `HKCU\Software\Wine\DirectInput` `MouseWarpOverride = "disable"` stops the warp and
  the cursor tracks and clicks normally. (`"force"` also appears to work but is for
  relative-mode games and is unreliable here — it dies intermittently.)
- **Menu text — still off.** The engine builds its text as OpenGL outlines from a
  Windows font: `GDI32.CreateFontA("Comic Sans MS")` + `OPENGL32.wglUseFontOutlinesA`.
  Comic Sans MS wasn't in the prefix, so Wine substituted a different-metric font;
  installing the real one (macOS ships it) fixes the glyphs but **not** the overlap.
  The remaining fault is in Wine's `wglUseFontOutlines` line spacing: a sentence that
  wraps is drawn on top of the next line. That lives inside the engine's text path and
  can't be fixed from the outside short of patching the DLL, so it's left as-is.

Both symptoms affect other Wine/CrossOver installs of Façade too; neither is a wrapper
setting. The installer applies the two fixes it can (the real font and the mouse
override) in `configure()`.

---

## 6. Building the wrapper headless (no Creator / no Configure)

Because a wrapper is just files + plist, the Creator GUI is avoidable entirely:

1. **Template** — download `Template-1.0.24.tar.xz`, extract → gives the `Facade.app`
   skeleton (launcher, Frameworks, empty-ish `SharedSupport`).
2. **Engine** — download `WS12WineCX24.0.7_7.tar.xz`, extract the Wine tree into the
   wrapper's `SharedSupport/wine/` *(exact placement to be confirmed at build time
   by diffing the template layout against the engine tarball — see §8).*
3. **Game files** — put Façade into `SharedSupport/prefix/drive_c/Program Files (x86)/Facade/`.
4. **Java swap** — replace the contents of `util/j2re1.4.2_06/` with Temurin 8 x32
   (keep the folder name; back up the original to `.orig`).
5. **Config** — set exactly one `Info.plist` key: `Program Name and Path` →
   `…/animEngineStarter.exe`. Use `plutil -replace` (the key name has spaces, which
   `PlistBuddy -c` can't parse). Leave every other key at its template default; those
   defaults already match a working wrapper, and changing the renderer keys breaks the
   game (§5).
6. **De-quarantine + ad-hoc sign** — `xattr -dr com.apple.quarantine Facade.app` and
   `codesign --force --deep --sign -` so Gatekeeper lets the unsigned wrapper run.
7. Place in `~/Applications/`.

This removes the two worst parts of the manual process: the Creator's flaky
`EngineDownloadError` and Configure's false *"No new executables found."*

Homebrew is **not** required — template and engine come straight from the stable
GitHub release URLs above.

---

## 7. Getting the game files (the installer) — the part that fought back

Source (freeware; the script downloads it, the repo never ships it):
**Internet Archive item `Faafade`** → `Facade-Win.rar` (170,928,752 B ≈ 163 MB),
which contains a single file, `FacadeInstaller1.1b.exe` (175,523,943 B uncompressed).

This step took four wrong turns before it worked. The write-up is worth keeping,
because every wrong turn looked right at the time.

**Wrong turn 1 — "it's NSIS."** `strings` on the exe showed `nsis` and `SFX`, so it
looked like a Nullsoft self-extractor → use `/S` to install silently. In fact the
`nsis` match was inside the word "co**nsis**ting". The real installer is a
**Caphyon Advanced Installer** bootstrapper (`ADVINSTSFX` / "Advanced Installer"):
a tiny 77 KB PE stub with a ~175 MB *proprietary* overlay (no `MSCF` CAB magic), so
no third-party tool can unpack the overlay, and the inner MSI, extracted, refuses
to run ("can only be run from a bootstrapper"). The right silent switch is
**`/exenoui /qn`** (bootstrapper UI off, MSI silent), not `/S`.

**Wrong turn 2 — "it can't install silently."** Every silent attempt exited doing
nothing, and with MSI logging forced on, `msiexec` never even launched. The
conclusion ("the prerequisites wizard blocks silent mode; ship a guided 3-click
install") was **wrong** — see wrong turn 3 for why.

**Wrong turn 3 — the real bug: a corrupt extraction.** macOS's built-in `bsdtar`
*appears* to extract the RAR (it produces a file of exactly the right size) but
prints `Parsing filters is unsupported` and silently writes **garbage** in the
filtered regions — this RAR uses a compression filter libarchive can't do. The
77 KB PE stub survived (so the installer's window opened), but its compressed
payload was mangled, so it rejected its own archive: *"This archive has an
unsupported version."* Every "silent is impossible" result above was really this
corruption. **Fix: extract with `unar`** (The Unarchiver's CLI, `brew install unar`).
`unar`'s output has a different checksum from `bsdtar`'s at the same size — proof
the bytes differ. With the clean installer, `/exenoui /qn` installs with **zero
clicks**. `bsdtar` is the one macOS built-in that can't be trusted here; `unar` is
the single external dependency, forced by the RAR format.

**Wrong turn 4 — "268 MB means done."** After the file copy the MSI runs a custom
action, `speexdecode.bat`, that **decompresses ~900 MB of Speex audio** and warns it
"may take up to 30 minutes." A watchdog that stopped at the copy plateau (~270 MB)
produced a wrapper missing almost a gigabyte of sound — and could kill the decode
mid-run. The reliable completion signal is the **`msiexec` engine exiting** (it runs
the MSI *including* the slow custom action); the bootstrapper process lingers after
that (the "never closes" behaviour) and is killed once `msiexec` is gone. Since the
audio is decoded natively after the copy (wrong turn 6), the post-check is that
**every `.spk` in `Sounds/` has a matching `.wav`**.

**Wrong turn 5 — "silent means zero clicks."** With a warmed-up prefix, `/exenoui /qn`
installed with no interaction, so the plan was a fully silent install. But that test
prefix had already run the installer many times, so its **prerequisites were already
satisfied**. On a fresh prefix the Advanced Installer shows a short wizard (welcome,
prerequisites, install folder) that it won't pass silently, so the installer is run
with its normal UI and the user clicks **Next** a few times. Everything after that is
automatic.

**Wrong turn 6 — the slow-decode trap, and the native fix.** After the file copy,
a custom action runs `speexdecode.bat`, which turns ~8,400 compressed `.spk` voice
clips into `.wav`. That batch is a flat list of **thousands** of individual
`speexdec in.spk out.wav` calls, each a separate short-lived x86 process. Under
Rosetta the whole thing is **slow — often more than an hour**, and a 50-minute
watchdog cap cut it off mid-run, producing a wrapper missing almost a gigabyte of
sound.

The fix is to stop fighting the Rosetta decoder and skip it. Façade's `.spk` files
are **standard Ogg Speex** (the header reads `OggS…Speex`, 22050 Hz wideband mono),
so the host's own `speexdec` from `brew install speex` decodes them directly. The
output is **byte-for-byte the same format** the game produces (RIFF PCM 16-bit mono
22050 Hz) and, on a spot check against a game-decoded clip, the same length and
content apart from a few milliseconds of leading-silence alignment. All ~8,400 clips
decode in **about 25 seconds** instead of 30 to 60 minutes.

So the installer now only needs the file **copy** from the wizard. The script waits
until the launcher exe is present, the `.spk` payload has been written, and
`msiexec` has exited (copy done), then kills the installer and its bundled decoder
and decodes the audio natively itself. `speexdec` joins `unar` as a required tool.

The final, scriptable recipe:

```
unar  Facade-Win.rar                                  # NOT bsdtar: it corrupts this RAR
cp    FacadeInstaller1.1b.exe  drive_c/FacadeInstaller.exe
wine  C:\FacadeInstaller.exe                          # user clicks Next through the wizard
# wait until the .spk payload is copied and msiexec has exited, then kill the
# installer (and its slow Rosetta decoder) and decode natively:
find Sounds -name '*.spk' | while read s; do speexdec "$s" "${s%.spk}.wav"; done
```

---

## 8. Resolved during the build

1. **Installer type** → Caphyon Advanced Installer SFX; extract with `unar`, install
   silently with `/exenoui /qn`, wait for `msiexec` to exit (§7). ✓
2. **Engine placement** → the engine tarball's `wswine.bundle/` becomes
   `Contents/SharedSupport/wine/` (§6). ✓
3. **The dependencies** → `unar` (unpack the RAR) and `speex` (decode the audio
   natively), both from Homebrew. Everything else uses macOS built-ins (`curl`,
   `tar`, `ditto`, `shasum`) and the wrapper's own Wine. ✓

4. **Mouse** → the engine uses DirectInput8; Wine's cursor warping fought the pointer
   and left it dead. `HKCU\Software\Wine\DirectInput` `MouseWarpOverride = "disable"`
   fixes it (§5). ✓
5. **Menu font** → the engine asks for Comic Sans MS; install the real one (macOS ships
   it) so glyphs render right (§5). ✓

Still open: the **menu-text overlap** (§5). The game runs and is fully playable, mouse
included, but Wine's `wglUseFontOutlines` gets the engine's per-line spacing slightly
wrong, so wrapped lines of menu text overlap. It affects other Wine/CrossOver installs
too and lives inside the engine's text path, so it can't be fixed from the outside
short of patching the DLL.

---

## 9. Verified facts (quick reference)

| Thing | Value |
|---|---|
| Host | Mac Studio M1 Max, arm64, macOS 27; Rosetta 2 running |
| Wrapper | `~/Applications/Sikarugir/Facade.app`, `com.sikarugir.Facade…`, `LSMinimumSystemVersion 14.6` |
| Launcher | universal Mach-O (x86_64 + arm64) |
| Engine | WineCX 24.0.7 (rev 6) / wine-9.0 SikarugirCX |
| Exe path | `/Program Files (x86)/Facade/util/sources/facade/animEngineStarter.exe` |
| Java (after swap) | Temurin `1.8.0_472-b08`, `i586` (32-bit) in `util/j2re1.4.2_06/` |
| Installer type | Caphyon Advanced Installer SFX → `/exenoui /qn` (silent); unpack with `unar` |
| Game install size | ~1.1 GB (incl. ~946 MB of Speex audio decompressed by `speexdecode.bat`) |
| Dependency | `unar` (`brew install unar`) — the one tool macOS doesn't ship that this needs |
| Success proof | a `Facade Stageplay …txt` appears in `Facade/stageplays/` after a session |
| Template URL | `github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz` |
| Engine URL | `github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz` |
| Java URL | `api.adoptium.net/v3/binary/latest/8/ga/windows/x32/jre/hotspot/normal/eclipse` |
| Game URL | `archive.org/download/Faafade/Facade-Win.rar` |

> Legal: Façade's own `readme.txt` states *"Façade is freeware - please give copies
> to your friends!"* (© 2005–2006 Procedural Arts). The repo ships **no** game files,
> installer, Java, or Wine engine — `install.sh` fetches each at runtime.
