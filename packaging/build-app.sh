#!/bin/bash
# Builds Butterscotch for macOS (AppKit backend) and packages VA-11 Hall-A as a standalone
# .app + .dmg. Run from the repo root. Needs your own legally-obtained data.win/game.unx -
# this script does not provide one and will refuse to run without a path to it.
#
# Usage: packaging/build-app.sh /path/to/data.win [/path/to/icon.png] [/path/to/scripts]
set -euo pipefail

DATA_WIN="${1:?Usage: $0 /path/to/data.win [/path/to/icon.png] [/path/to/scripts]}"
ICON_PNG="${2:-}"
# GameMaker "Included Files" the game opens by relative path at runtime (dialogue scripts,
# etc.) - not embedded in data.win itself. Defaults to a sibling `scripts/` next to data.win,
# which is where it lands in a typical GameMaker export; pass a third argument to override.
SCRIPTS_DIR="${3:-$(dirname "$DATA_WIN")/scripts}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUTTERSCOTCH_DIR="$REPO_ROOT/butterscotch"
BUILD_DIR="$BUTTERSCOTCH_DIR/build"
STAGING="$REPO_ROOT/dmg_staging"
APP="$STAGING/VA-11 Hall-A.app"
DIST_DIR="$REPO_ROOT/dist"

if [ ! -f "$DATA_WIN" ]; then
    echo "error: data file not found: $DATA_WIN" >&2
    exit 1
fi

# 1. Clone Butterscotch fresh if it's not already there, and apply this repo's patches.
if [ ! -d "$BUTTERSCOTCH_DIR" ]; then
    echo "Cloning Butterscotch..."
    git clone https://github.com/MrPowerGamerBR/Butterscotch.git "$BUTTERSCOTCH_DIR"
    for patch in "$REPO_ROOT"/patches/*.patch; do
        echo "Applying $(basename "$patch")..."
        (cd "$BUTTERSCOTCH_DIR" && git apply "$patch")
    done
else
    echo "Using existing clone at $BUTTERSCOTCH_DIR (not re-cloning or re-patching - apply patches/*.patch yourself if this is a fresh clone)"
fi

# 2. Build (AppKit backend - the native macOS windowing/input path, no external deps beyond
#    the system SDKs; miniaudio is header-only, no external audio library needed either).
echo "Building..."
mkdir -p "$BUILD_DIR"
cmake -S "$BUTTERSCOTCH_DIR" -B "$BUILD_DIR" -DPLATFORM=cli -DBACKEND=appkit -DAUDIO_BACKEND=miniaudio -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.ncpu)"

# 3. Stage the .app bundle.
echo "Staging .app bundle..."
rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/butterscotch" "$APP/Contents/MacOS/butterscotch-bin"
cp "$DATA_WIN" "$APP/Contents/Resources/data.win"

if [ -d "$SCRIPTS_DIR" ]; then
    echo "Bundling Included Files from $SCRIPTS_DIR..."
    cp -R "$SCRIPTS_DIR" "$APP/Contents/Resources/scripts"
else
    echo "warning: no scripts/ directory found at $SCRIPTS_DIR - dialogue-heavy scenes (e.g. New Game) will hang. Pass it explicitly as a third argument if it lives elsewhere." >&2
fi

cp "$REPO_ROOT/packaging/Info.plist.template" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/packaging/launcher.sh.template" "$APP/Contents/MacOS/VA-11 Hall-A"
chmod +x "$APP/Contents/MacOS/VA-11 Hall-A"

if [ -n "$ICON_PNG" ] && [ -f "$ICON_PNG" ]; then
    echo "Building app icon from $ICON_PNG..."
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "No icon supplied - app will use the default generic icon."
fi

ln -sf /Applications "$STAGING/Applications"

# 4. Package as .dmg.
echo "Packaging .dmg..."
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/VA-11 Hall-A.dmg"
hdiutil create -volname "VA-11 Hall-A" -srcfolder "$STAGING" -ov -format UDZO "$DIST_DIR/VA-11 Hall-A.dmg"

echo "Done: $DIST_DIR/VA-11 Hall-A.dmg"
