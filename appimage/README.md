# Dolphin AppImage

A single Linux AppImage with [Dolphin](https://dolphin-emu.org) set up to boot Mario Kart: Double Dash!!.
It also boots a `main.dol` built from this decomp. It contains no game data, so you need your own disc image.

## Get it

Download it from [Releases](../../../releases), or build it yourself:

```sh
appimage/build.sh                 # for this machine's arch, result in build/
ARCH=aarch64 appimage/build.sh    # must run on an aarch64 machine
```

Needs `bash`, `curl` and `sha256sum`. No root, FUSE or docker.

## Use

```sh
./MKDD-Dolphin-*.AppImage                        # first run asks for the disc image, later runs reuse it
./MKDD-Dolphin-*.AppImage ~/games/mkdd.rvz       # boot this disc image and remember it
./MKDD-Dolphin-*.AppImage --dol                  # boot build/MarioClub_us/main.dol (run from the repo root)
./MKDD-Dolphin-*.AppImage --dol path/main.dol path/disc.iso
./MKDD-Dolphin-*.AppImage --dolphin              # plain Dolphin, e.g. to set up controllers
./MKDD-Dolphin-*.AppImage --help
```

- The disc picker uses `zenity` or `kdialog` if the host has one. Without either, pass the path.
- Remembered disc: `~/.config/mkdd-appimage/disc`. Forget it with `--forget`.
- Dolphin settings and saves are in `~/.local/share/dolphin-emu`, the same place an installed Dolphin uses.

## How `--dol` works

The decomp builds only the game executable (`main.dol`). The game also needs the files on the disc.

1. On first use, the launcher extracts the disc into `~/.cache/mkdd-appimage/disc-<id>/` with `dolphin-tool extract`.
   That takes about 1.5 GB. The cache is reused until the disc image changes.
2. It copies your `main.dol` over `sys/main.dol` in that folder.
3. It boots `sys/main.dol`. Dolphin treats a folder with `sys/` and `files/` as a full disc
   ("DirectoryBlob"), so the game finds its files.

The decomp currently matches the debug build (`MarioClub_us`), so use that disc image with `--dol`.

## How the AppImage is built

- `build.sh` downloads a pinned Dolphin AppImage from
  [pkgforge-dev/Dolphin-emu-AppImage](https://github.com/pkgforge-dev/Dolphin-emu-AppImage) and checks its SHA-256.
  Its libraries are bundled with [sharun](https://github.com/VHSgunzo/sharun), so it runs on most distributions.
- It unpacks that AppImage. Dolphin's `AppRun.sh` becomes `AppRun.dolphin.sh`, and `appimage/AppRun.sh` goes in front.
  The sharun `AppRun` binary still starts `AppRun.sh`, which now handles the options above and then calls Dolphin's launcher.
- The self-updater hook is removed, because it would replace this AppImage with plain Dolphin.
- It packs the result with pinned `appimagetool` and the standard type2 runtime. The Dolphin AppImage uses
  uruntime with a DwarFS image, but `appimagetool` only writes SquashFS, and that uruntime build cannot read SquashFS.

To update Dolphin, change `DOLPHIN_VERSION`, `DOLPHIN_TAG` and both `DOLPHIN_SHA256` values in `build.sh`.

## CI

`.github/workflows/appimage.yml` builds x86_64 and aarch64 when `appimage/` changes, and runs a smoke test.
On `main` it publishes the AppImages as release `appimage-dolphin-<version>`.
