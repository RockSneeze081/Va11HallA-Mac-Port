# VA-11 Hall-A on macOS

A native, standalone macOS build of *VA-11 Hall-A: Cyberpunk Bartender Action*, via
[Butterscotch](https://github.com/MrPowerGamerBR/Butterscotch), an open-source
reimplementation of the GameMaker: Studio runtime. Packaged as a real `.app` +
`.dmg` with a proper icon — not an emulator, not a VM, the actual game running
directly on Apple Silicon or Intel Macs.

**This repo contains no game data**, same reasoning as the [3DS port](https://github.com/RockSneeze081/va11-hall-a-3ds):
you supply your own legally-obtained copy of the game. Nothing extracted from
the game — no `data.win`, no textures, no icon art — is committed here.

## Backstory: how a Mac port came out of a 3DS project

This didn't start as a Mac project at all. It's a byproduct of a separate,
much longer effort: getting the same game running on **3DS homebrew** (see
[va11-hall-a-3ds](https://github.com/RockSneeze081/va11-hall-a-3ds)), which is where the actual game data
this needs originally came from.

Short version of that chain: the game is legitimately owned on **PS Vita**,
but the Vita's own exported data file turned out to be genuinely encrypted
(confirmed by entropy analysis and a systematic XOR sweep, not just assumed).
Research into the GameMaker-on-Vita/3DS homebrew scene confirmed this is a
known, universal wall — nobody sources from console-native exports for this,
everyone uses a plain PC build instead. A friend separately had a GOG Linux
offline installer for the same game and shared it; its `data.win`-equivalent
(`game.unx`) turned out to be clean, unencrypted, and bytecode-compatible,
and became the data source for the whole 3DS port from that point on — same
game, same purchase-worthy content, just sourced from a build that wasn't
locked behind Vita's encryption.

The 3DS port itself (via [Cinnamon](https://github.com/Project-Sunshine-Native/cinnamon),
a GameMaker-runtime reimplementation forked from Butterscotch and narrowed
to target 3DS/Wii U) got genuinely far — booting, real audio, real mouse/touch
input added from scratch, a forced intro-loop bug root-caused and fixed — but
hit a real, still-unresolved rendering bug on the title screen (renders
black; see that repo's README), and separately, real-3DS hardware testing
turned up touch/button/resolution problems that don't reproduce in the
emulator used to develop it. Progress on both stalled mid-session.

While waiting on that, the obvious question came up: *if the actual goal is
just to play the game, does it have to be on the 3DS at all?* That's what
led to checking whether Cinnamon could be built for desktop directly — and
when that turned out to be a dead end, to checking the *upstream* Butterscotch
project instead, which is where this repo actually starts.

## Why Butterscotch works for this and Cinnamon doesn't (yet)

The first instinct — build Cinnamon itself for desktop — turned out to be a dead
end: Cinnamon only has `main()` entry points for `n3ds/` and `wiiu/`; its `gl/`
directory is shared renderer code with no actual desktop window/input/event-loop
implementation behind it. Checking the *upstream* project it forked from told a
different story: Butterscotch's own README explicitly lists **macOS** as a
supported platform, with a dedicated native **AppKit** backend (`src/backends/appkit.m`,
709 lines of real Cocoa/OpenGL/GameController code — a real window, real mouse
and keyboard handling, real gamepad support), completely separate from the
narrower 3DS/Wii U-focused fork. It also explicitly lists **WAD version 15**
(GameMaker: Studio 1.4.1675+) as supported — exactly VA-11 Hall-A's bytecode
version, the same one that Cinnamon's documented "16/17 only" support doesn't
cover.

Built clean on the first try: `cmake -DPLATFORM=cli -DBACKEND=appkit -DAUDIO_BACKEND=miniaudio`,
pointed at the same `data.win` sourced for the 3DS port (see that repo's README
for how — a GOG Linux offline installer, extracted without running it), and it
booted straight into the real game: correct art, correct audio, real mouse
input out of the box. Dramatically less work than the 3DS port, because desktop
is Butterscotch's actual home turf rather than a console port's afterthought.

## What was actually wrong, and how it was found

### The mouse Y-axis was inverted

The only real bug hit. `src/backends/appkit.m`'s `platformGetMousePos()` read
`[window mouseLocationOutsideOfEventStream]` and passed the result straight
through:

```objc
void platformGetMousePos(double *xPos, double *yPos) {
    NSPoint mouseLocation = [window mouseLocationOutsideOfEventStream];
    *xPos = mouseLocation.x;
    *yPos = mouseLocation.y;
}
```

AppKit's window/view coordinate space is **bottom-up** (origin at the
bottom-left, Y grows upward) — a long-standing Cocoa convention. Every other
backend in the same codebase reports mouse position **top-down** instead
(origin at the top-left, Y grows downward, the standard game/GUI convention):
`glfwGetCursorPos` and `SDL_GetMouseState` both already do this correctly,
confirmed by reading `glfw3.c`/`sdl2.c`'s own implementations of the same
function side by side. AppKit was the one inconsistent backend.

**Fix** (`patches/01-macos-mouse-y-flip.patch`): flip against the content
view's height, matching what the other backends already do —

```objc
void platformGetMousePos(double *xPos, double *yPos) {
    NSPoint mouseLocation = [window mouseLocationOutsideOfEventStream];
    NSRect bounds = [glView bounds];
    *xPos = mouseLocation.x;
    *yPos = bounds.size.height - mouseLocation.y;
}
```

Confirmed fixed by the person actually playing it in real time, not just by
reading the code.

### New Game hung on a black screen, cursor spinning, music still playing

Two separate problems stacked on top of each other, found with `sample` (a
call-stack profile of the hung process, showing `executeLoop` stuck calling
the file-read builtins in a tight loop) plus temporary diagnostic logging in
those builtins:

1. **`show_error` was entirely unimplemented.** Real GameMaker's
   `show_error(message, abort)` logs/displays an error and, if `abort` is
   true, halts the game. Butterscotch had no registration for it at all, so
   it fell through the VM's generic "unknown function → return undefined,
   keep going" fallback. VA-11 Hall-A calls `show_error` as part of its own
   error-recovery path when a script file lookup fails — with the builtin
   silently doing nothing, that recovery path never actually recovered,
   and the caller looped forever instead of bailing out. Fixed by
   implementing it properly in `src/vm_builtins.c` (log the message, set
   the runner's exit flag when `abort` is true) and registering it.
2. **That alone wasn't the real fix** — implementing `show_error` just
   turned the silent infinite loop into a *logged* infinite loop
   (`Error locating pointer!` repeated hundreds of times). The actual root
   cause: `scripts/eng/anna_script.txt` (and its language siblings) are
   GameMaker "Included Files" — loose asset files shipped as siblings to
   `data.win`, not embedded inside it. Their *names* live in `data.win`'s
   string table (confirmed with `grep -a`), but the file content itself has
   to be extracted and bundled separately, and that step had been missed
   when the original `data.win` was pulled from the GOG installer. Once the
   `scripts/` directory was actually extracted and bundled next to
   `data.win`, the hang was gone.

Confirmed fixed by the person playing it. `packaging/build-app.sh` now
bundles `scripts/` automatically (see **Building it yourself** below) —
previously this was done by hand and easy to forget, which is exactly how
it got missed the first time.

### Small QoL additions

- **Cursor hidden over the game window** — the game draws its own cursor
  sprite, so the OS arrow was doubling up on top of it. Fixed with the
  standard AppKit pattern (an invisible `NSCursor` tied to a cursor rect via
  `resetCursorRects`), rather than manually toggling `NSCursor hide`/`unhide`
  on enter/exit events, which is easy to leave desynced.
- **Window title branded** — turned out `platformSetWindowTitle` only fires
  if the game itself calls `window_set_caption()` from GML, which VA-11
  Hall-A never does; the title actually shown at launch is set directly in
  `platformInit`. Branded both spots for consistency, but the one in
  `platformInit` is the one that actually matters here.

### Everything else

Nothing else needed touching. Save-file/config path handling wasn't obviously
implemented for desktop as of the commit this was built against (Butterscotch's
own README: *"still VERY early in development"*), so the packaged app's
launcher script runs the game from a dedicated writable directory
(`~/Library/Application Support/VA-11 Hall-A`) rather than wherever Finder
happens to set the working directory, so save data has somewhere sane to land
if and when that lands upstream — cheap insurance, not a fix for a confirmed bug.

## Building it yourself

You need your own legally-obtained copy of the game's data file (any
GameMaker export — Windows, Mac, Linux — as long as it's not YYC-compiled),
**and** the `scripts/` folder that ships alongside it (GameMaker "Included
Files" — dialogue scripts the game opens by filename at runtime; without
them, New Game hangs on a black screen). In a typical export this sits right
next to the data file; if it doesn't, pass its path explicitly. This repo
provides neither.

```bash
git clone <this-repo-url>
cd va11-mac-port
packaging/build-app.sh /path/to/data.win [/path/to/icon.png] [/path/to/scripts]
```

This clones Butterscotch fresh, applies every patch in `patches/*.patch` in
order, builds it (`-DBACKEND=appkit -DAUDIO_BACKEND=miniaudio`, both
dependency-free — AppKit/Cocoa/GameController are system frameworks,
miniaudio is header-only), stages a proper `.app` bundle (using
`packaging/Info.plist.template` and `packaging/launcher.sh.template`,
including `scripts/` if found), builds an `.icns` from the optional icon PNG
via `sips`/`iconutil`, and packages the result as `dist/VA-11 Hall-A.dmg`
with the usual drag-to-`/Applications` layout.

**First launch**: since this isn't signed with an Apple Developer certificate,
Gatekeeper will flag it as from an unidentified developer. Right-click → Open
the first time instead of double-clicking; it opens normally after that.

If you'd rather build Butterscotch manually instead of via the script:

```bash
git clone https://github.com/MrPowerGamerBR/Butterscotch.git
cd Butterscotch
git apply /path/to/patches/01-macos-mouse-y-flip.patch
git apply /path/to/patches/02-newgame-hang-fix-and-branding.patch
mkdir build && cd build
cmake -DPLATFORM=cli -DBACKEND=appkit -DAUDIO_BACKEND=miniaudio -DCMAKE_BUILD_TYPE=Release ..
cmake --build .
./butterscotch /path/to/data.win
```

Note that running it this way, outside the packaged `.app`, means the
process's own working directory has to actually be the folder containing
`scripts/` for New Game to work — the packaged launcher handles this for
you (see **New Game hung...** above); a bare manual run doesn't.

Built and tested against Butterscotch commit `5330e02feb0ebadc79262cdaeec7ba2cd404fb73`
(2026-08-24) — it's explicitly early-stage software per its own README, so a
later commit may behave differently.

## Repo layout

- `patches/01-macos-mouse-y-flip.patch` — the mouse Y-axis fix, against
  upstream Butterscotch.
- `patches/02-newgame-hang-fix-and-branding.patch` — the `show_error`
  implementation, cursor-hide, and window-title branding, against upstream
  Butterscotch (applies on top of patch 01).
- `packaging/` — the `.app`/`.dmg` build tooling (`build-app.sh`,
  `Info.plist.template`, `launcher.sh.template`). All original to this repo,
  no upstream/copyrighted content.
- `butterscotch/`, `dist/`, `dmg_staging/`, `*.dmg`, `*.icns`, `data.win` —
  all gitignored. Clone/build/package fresh per the instructions above.

## Credits

- [Butterscotch](https://github.com/MrPowerGamerBR/Butterscotch) by
  MrPowerGamerBR — the actual GameMaker runtime reimplementation this runs
  on, including the native macOS AppKit backend. All credit for this working
  *at all* belongs there; the one fix in this repo is a small correction to
  otherwise-solid existing code, not new groundwork.
- Sukeban Games — VA-11 Hall-A itself. Go buy it if you haven't:
  [sukeban.moe](https://sukeban.moe).
