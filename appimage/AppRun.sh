#!/bin/sh
# AppImage entry point: Dolphin set up to boot Mario Kart: Double Dash!!.
# The sharun AppRun binary runs this script. Dolphin's own AppRun.sh is kept
# as AppRun.dolphin.sh and does the actual launch.
#
#   MKDD.AppImage                    boot the remembered disc (asks for one the first time)
#   MKDD.AppImage DISC               boot DISC and remember it
#   MKDD.AppImage --dol [DOL] [DISC] boot a main.dol built by this decomp, with DISC's files
#   MKDD.AppImage --dolphin ARGS...  plain Dolphin
#   MKDD.AppImage --tool ARGS...     dolphin-tool
#   MKDD.AppImage --forget           forget the remembered disc
#   MKDD.AppImage --help
set -e

DOLPHIN="$APPDIR/AppRun.dolphin.sh"
# Dolphin's hooks read this. Its own uruntime set it; the type2 runtime does not.
: "${APPIMAGE_ARCH:=$(uname -m)}"
export APPIMAGE_ARCH

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mkdd-appimage"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mkdd-appimage"
DISC_FILE="$CONFIG_DIR/disc"
DEFAULT_DOL="build/MarioClub_us/main.dol"
SELF="${APPIMAGE##*/}"
SELF="${SELF:-MKDD.AppImage}"

say() { printf '%s\n' "$*" >&2; }

usage() {
	cat <<EOF
Mario Kart: Double Dash!! on Dolphin. You supply your own disc image.

Usage: $SELF [DISC | OPTION]

  (no argument)          boot the remembered disc (asks for one the first time)
  DISC                   boot DISC (ISO, RVZ, GCZ, CISO, WIA, ...) and remember it
  --dol [DOL] [DISC]     boot a main.dol built by the decomp (default: $DEFAULT_DOL)
                         with the game files of DISC (default: the remembered disc)
  --dolphin ARGS...      plain Dolphin, ARGS go to dolphin-emu
  --tool ARGS...         dolphin-tool
  --forget               forget the remembered disc

Remembered disc: $DISC_FILE
Dolphin settings and saves: ~/.local/share/dolphin-emu, the same as an installed Dolphin.
EOF
}

# Ask for a disc image with a host file picker. Prints the path, or nothing.
pick_disc() {
	filter="*.iso *.gcm *.rvz *.gcz *.ciso *.wia *.wbfs *.nfs *.tgc *.ISO *.GCM *.RVZ"
	if command -v zenity >/dev/null 2>&1; then
		zenity --file-selection --title="Mario Kart: Double Dash!! disc image" \
			--file-filter="GameCube disc images | $filter" 2>/dev/null || true
	elif command -v kdialog >/dev/null 2>&1; then
		kdialog --title "Mario Kart: Double Dash!! disc image" \
			--getopenfilename "$HOME" "$filter" 2>/dev/null || true
	fi
}

remembered_disc() {
	[ -f "$DISC_FILE" ] || return 0
	d=$(cat "$DISC_FILE")
	[ -f "$d" ] && printf '%s\n' "$d"
	return 0
}

remember_disc() {
	mkdir -p "$CONFIG_DIR"
	printf '%s\n' "$1" > "$DISC_FILE"
}

abspath() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s/%s\n' "$PWD" "$1" ;;
	esac
}

# Disc image, from the argument, the remembered one or the file picker.
# Exits when there is none.
need_disc() {
	d="$1"
	[ -n "$d" ] || d=$(remembered_disc)
	[ -n "$d" ] || d=$(pick_disc)
	if [ -z "$d" ]; then
		say "No disc image. Run: $SELF /path/to/MarioKartDoubleDash.iso"
		exit 1
	fi
	[ -f "$d" ] || { say "Not a file: $d"; exit 1; }
	d=$(abspath "$d")
	remember_disc "$d"
	printf '%s\n' "$d"
}

# Extract DISC once into the cache. Prints the folder that holds sys/ and files/.
extract_disc() {
	key=$(printf '%s %s' "$1" "$(stat -c '%s %Y' "$1")" | cksum | cut -d' ' -f1)
	out="$CACHE_DIR/disc-$key"
	if [ ! -f "$out/.done" ]; then
		say "Extracting $1 to $out (one time, about 1.5 GB)"
		rm -rf "$out"
		mkdir -p "$out"
		"$DOLPHIN" dolphin-tool extract -q -i "$1" -o "$out" >&2
		touch "$out/.done"
	fi
	main=$(find "$out" -path '*/sys/main.dol' | head -n 1)
	[ -n "$main" ] || { say "Extracted disc has no sys/main.dol: $out"; exit 1; }
	dirname "$(dirname "$main")"
}

case "$1" in
	-h|--help)
		usage
		exit 0 ;;
	--dolphin)
		shift
		exec "$DOLPHIN" dolphin-emu "$@" ;;
	--tool)
		shift
		exec "$DOLPHIN" dolphin-tool "$@" ;;
	--forget)
		rm -f "$DISC_FILE"
		say "Forgot the remembered disc."
		exit 0 ;;
	--dol)
		shift
		dol="${1:-$DEFAULT_DOL}"
		[ $# -gt 0 ] && shift
		[ -f "$dol" ] || { say "No DOL at $dol. Build it first: python configure.py && ninja"; exit 1; }
		dol=$(abspath "$dol")
		disc=$(need_disc "$1")
		root=$(extract_disc "$disc")
		# Dolphin boots <root>/sys/main.dol as a full disc, with <root>/files as its files.
		cp -f "$dol" "$root/sys/main.dol"
		say "Booting $dol with the files of $disc"
		exec "$DOLPHIN" dolphin-emu -e "$root/sys/main.dol" ;;
	-*)
		usage >&2
		exit 1 ;;
esac

disc=$(need_disc "$1")
exec "$DOLPHIN" dolphin-emu -e "$disc"
