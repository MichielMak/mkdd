#!/usr/bin/env bash
# Build an AppImage of Dolphin that boots Mario Kart: Double Dash!!.
#
# Takes the pinned Dolphin AppImage from pkgforge-dev/Dolphin-emu-AppImage,
# unpacks it, puts appimage/AppRun.sh in front of Dolphin's own launcher and
# packs it again. No game data goes in: the user picks a disc image at runtime.
#
# Needs: bash, curl, sha256sum, dpkg-deb, a C and C++ compiler. No root, FUSE or docker.
#
# Usage: appimage/build.sh
#   The AppImage's version comes from appimage/VERSION (see appimage/README.md, Releases).
#   ARCH=x86_64|aarch64  target, default: this machine (appimagetool runs natively)
#   OUTDIR=...           where the AppImage goes, default: build/
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  x86_64) ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "unsupported ARCH=$ARCH" >&2; exit 1 ;;
esac
BUILD="$ROOT/build/appimage/$ARCH"
APPDIR="$BUILD/AppDir"
OUTDIR="${OUTDIR:-$ROOT/build}"
APPIMAGE_VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"

# Pinned Dolphin release. Bump all three together.
DOLPHIN_VERSION=2609a
DOLPHIN_TAG="2609a@2026-11-01_1793557796"
case "$ARCH" in
  x86_64)  DOLPHIN_SHA256=b1bb772cb5aeb26f44e005377201ea2f21ac4323c04d570a184763abb950b4e9 ;;
  aarch64) DOLPHIN_SHA256=04731b635b6ab41b123ca805cc765dddd57173e8b0fc014446692f458557bec6 ;;
esac
DOLPHIN_URL="https://github.com/pkgforge-dev/Dolphin-emu-AppImage/releases/download/${DOLPHIN_TAG//@/%40}/Dolphin_Emulator-$DOLPHIN_VERSION-anylinux-$ARCH.AppImage"

# The Dolphin AppImage uses uruntime with a DwarFS image. appimagetool only
# writes SquashFS, which that uruntime build does not read, so the result gets
# the standard type2 runtime instead.
TOOL_VERSION=1.9.1
RUNTIME_VERSION=20251108
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/$TOOL_VERSION/appimagetool-$ARCH.AppImage"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-$ARCH"
# Qt 6.4 headers (Debian 12) for the settings window. It links the Qt 6
# libraries Dolphin bundles (6.12 in 2609a); Qt keeps binary compatibility
# within 6.x, so older headers are fine.
QTDEV_DEB="qt6-base-dev_6.4.2%2Bdfsg-10"
QTDEV_POOL="http://deb.debian.org/debian/pool/main/q/qt6-base"
QTDEV_SNAPSHOT="https://snapshot.debian.org/archive/debian/20250101T000000Z/pool/main/q/qt6-base"
case "$ARCH" in
  x86_64)  QTDEV_ARCH=amd64; TRIPLET=x86_64-linux-gnu
           QTDEV_SHA256=6dd109236a612ab8f4acde31c6b7f71ef566ac66cd3b0b77d4d5114ba589ca5f ;;
  aarch64) QTDEV_ARCH=arm64; TRIPLET=aarch64-linux-gnu
           QTDEV_SHA256=53b9a0bba955f26dd8ba647e1995830ba9d9e72e50a24852045575d15b3c44dd ;;
esac
case "$ARCH" in
  x86_64)
    TOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64)
    TOOL_SHA256=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    RUNTIME_SHA256=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
esac

# fetch <url> <sha256> <file>: GitHub release downloads time out now and then,
# hence the retries; a file that does not match its checksum is refused.
fetch() {
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then return 0; fi
  echo ">> downloading $1"
  # return, not exit: a caller may try another URL. Plain calls still stop the
  # build through set -e.
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 -o "$3" "$1" || return 1
  if ! echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then
    echo "$1 does not match its pinned SHA-256" >&2
    rm -f "$3"
    return 1
  fi
}

mkdir -p "$BUILD" "$OUTDIR"
fetch "$DOLPHIN_URL" "$DOLPHIN_SHA256" "$BUILD/dolphin.AppImage"
fetch "$TOOL_URL" "$TOOL_SHA256" "$BUILD/appimagetool"
fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$BUILD/runtime"
# Debian moves old packages out of its pool; the snapshot keeps them.
if ! fetch "$QTDEV_POOL/${QTDEV_DEB}_$QTDEV_ARCH.deb" "$QTDEV_SHA256" "$BUILD/qt6-base-dev.deb" 2>/dev/null; then
  fetch "$QTDEV_SNAPSHOT/${QTDEV_DEB}_$QTDEV_ARCH.deb" "$QTDEV_SHA256" "$BUILD/qt6-base-dev.deb"
fi
chmod +x "$BUILD/dolphin.AppImage" "$BUILD/appimagetool"

# --- unpack Dolphin ------------------------------------------------------------
echo ">> unpacking Dolphin $DOLPHIN_VERSION"
rm -rf "$APPDIR" "$BUILD/squashfs-root"
(cd "$BUILD" && ./dolphin.AppImage --appimage-extract >/dev/null)
mv "$BUILD/AppDir" "$APPDIR.tmp" 2>/dev/null || mv "$BUILD/squashfs-root" "$APPDIR.tmp"
rm -rf "$BUILD/squashfs-root"
mv "$APPDIR.tmp" "$APPDIR"
[ -f "$APPDIR/AppRun.sh" ] && [ -e "$APPDIR/bin/dolphin-emu" ] \
  || { echo "unexpected Dolphin AppImage layout" >&2; exit 1; }

# --- put our launcher in front ---------------------------------------------------
mv "$APPDIR/AppRun.sh" "$APPDIR/AppRun.dolphin.sh"
install -m755 "$HERE/AppRun.sh" "$APPDIR/AppRun.sh"
# The self-updater would replace this AppImage with plain Dolphin.
rm -f "$APPDIR/bin/10-self-updater.hook"

# mkdd-pads lists controllers for the launcher's automap. It links the bundled
# libSDL3 and runs through sharun (bin/<name> is sharun, shared/bin/<name> the
# real binary), so it sees the same controller names as Dolphin.
[ -e "$APPDIR/shared/lib/libSDL3.so.0" ] || { echo "Dolphin AppImage has no libSDL3.so.0" >&2; exit 1; }
# The library goes in by path, not -L: that folder also holds the bundled
# libc.so, which must not replace the host's at link time.
"${CC:-cc}" -O2 -Wall -Wextra -o "$APPDIR/shared/bin/mkdd-pads" "$HERE/pads.c" \
  "$APPDIR/shared/lib/libSDL3.so.0" -Wl,--unresolved-symbols=ignore-in-shared-libs
ln -f "$APPDIR/sharun" "$APPDIR/bin/mkdd-pads"

# mkdd-settings is the window shown without arguments. Same scheme: Qt 6.4
# headers from the Debian package, the bundled Qt libraries by path.
QTINC="$BUILD/qt6-base-dev/usr/include/$TRIPLET/qt6"
if [ ! -d "$QTINC/QtWidgets" ]; then
  rm -rf "$BUILD/qt6-base-dev"
  dpkg-deb -x "$BUILD/qt6-base-dev.deb" "$BUILD/qt6-base-dev"
fi
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -fPIC -o "$APPDIR/shared/bin/mkdd-settings" "$HERE/settings.cpp" \
  -I"$QTINC" -I"$QTINC/QtCore" -I"$QTINC/QtGui" -I"$QTINC/QtWidgets" \
  "$APPDIR/shared/lib/libQt6Widgets.so.6" "$APPDIR/shared/lib/libQt6Gui.so.6" "$APPDIR/shared/lib/libQt6Core.so.6" \
  -Wl,--unresolved-symbols=ignore-in-shared-libs
ln -f "$APPDIR/sharun" "$APPDIR/bin/mkdd-settings"
echo "$DOLPHIN_VERSION" > "$APPDIR/dolphin-version"
echo "$APPIMAGE_VERSION" > "$APPDIR/version"

rm -f "$APPDIR"/*.desktop "$APPDIR/.DirIcon"
cp "$HERE/mkdd.desktop" "$APPDIR/mkdd.desktop"
cp "$HERE/mkdd.png" "$APPDIR/mkdd.png"
ln -s mkdd.png "$APPDIR/.DirIcon"
mkdir -p "$APPDIR/share/icons/hicolor/256x256/apps" "$APPDIR/share/icons/hicolor/scalable/apps"
cp "$HERE/mkdd.png" "$APPDIR/share/icons/hicolor/256x256/apps/mkdd.png"
cp "$HERE/mkdd.svg" "$APPDIR/share/icons/hicolor/scalable/apps/mkdd.svg"

# --- pack ----------------------------------------------------------------------
VERSION="$APPIMAGE_VERSION"
OUT="$OUTDIR/MKDD-Dolphin-$APPIMAGE_VERSION-$ARCH.AppImage"
echo ">> packing $OUT"
ARCH=$ARCH VERSION=$VERSION "$BUILD/appimagetool" --appimage-extract-and-run \
  --runtime-file "$BUILD/runtime" --no-appstream "$APPDIR" "$OUT"
echo ">> done: $OUT"
