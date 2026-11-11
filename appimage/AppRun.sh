#!/bin/sh
# AppImage entry point: Dolphin set up to boot Mario Kart: Double Dash!!.
# The sharun AppRun binary runs this script. Dolphin's own AppRun.sh is kept
# as AppRun.dolphin.sh and does the actual launch.
#
#   MKDD.AppImage                    settings window: disc, a few settings, Play
#   MKDD.AppImage --game [DISC]      start the game right away, fullscreen (Steam, Steam Deck)
#   MKDD.AppImage DISC               start DISC with the saved settings and remember it
#   MKDD.AppImage --settings         the settings window
#   MKDD.AppImage --dol [DOL] [DISC] boot a main.dol built by this decomp, with DISC's files
#   MKDD.AppImage --pads             show connected controllers and their ports
#   MKDD.AppImage --dolphin ARGS...  plain Dolphin
#   MKDD.AppImage --tool ARGS...     dolphin-tool
#   MKDD.AppImage --forget           forget the remembered disc
#   MKDD.AppImage --help
#
# The settings window (settings.cpp) writes $CONFIG_DIR/settings.ini. Those
# choices reach Dolphin as -C overrides for one run, so Dolphin's own config,
# which an installed Dolphin shares, stays as it is.
#
# Before a game boots, connected gamepads are mapped to GameCube ports 1-4,
# and gamepads plugged in while Dolphin runs get the next free port (see automap
# below). --no-automap or MKDD_AUTOMAP=0 skips that.
set -e

DOLPHIN="$APPDIR/AppRun.dolphin.sh"
PADS_TOOL="$APPDIR/bin/mkdd-pads"
SETTINGS_TOOL="$APPDIR/bin/mkdd-settings"
# Dolphin's hooks read this. Its own uruntime set it; the type2 runtime does not.
: "${APPIMAGE_ARCH:=$(uname -m)}"
export APPIMAGE_ARCH

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mkdd-appimage"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mkdd-appimage"
SETTINGS="$CONFIG_DIR/settings.ini"
# Where the disc path lived before settings.ini.
OLD_DISC_FILE="$CONFIG_DIR/disc"
DEFAULT_DOL="build/MarioClub_us/main.dol"
SELF="${APPIMAGE##*/}"
SELF="${SELF:-MKDD.AppImage}"

# Dolphin's config folder, picked the way Dolphin does (UICommon::SetUserDirectory).
if [ -n "$DOLPHIN_EMU_USERPATH" ]; then
	DOLPHIN_CONFIG="$DOLPHIN_EMU_USERPATH/Config"
elif [ -d "$HOME/.dolphin-emu" ]; then
	DOLPHIN_CONFIG="$HOME/.dolphin-emu/Config"
else
	DOLPHIN_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/dolphin-emu"
fi
PAD_INI="$DOLPHIN_CONFIG/GCPadNew.ini"
MAIN_INI="$DOLPHIN_CONFIG/Dolphin.ini"
# What automap last wrote, and the GCPadNew.ini it replaced.
WRITTEN_INI="$CONFIG_DIR/GCPadNew.written.ini"
BACKUP_INI="$CONFIG_DIR/GCPadNew.backup.ini"

say() { printf '%s\n' "$*" >&2; }

usage() {
	cat <<EOF
Mario Kart: Double Dash!! on Dolphin. You supply your own disc image.

Usage: $SELF [--no-automap] [DISC | OPTION]

  (no argument)          settings window: pick the disc, change a few settings, Play
  --game [DISC]          start the game right away in fullscreen, e.g. from Steam
  DISC                   start DISC (ISO, RVZ, GCZ, CISO, WIA, ...) and remember it
  --settings             the settings window
  --dol [DOL] [DISC]     boot a main.dol built by the decomp (default: $DEFAULT_DOL)
                         with the game files of DISC (default: the remembered disc)
  --pads                 show connected controllers and the ports they get
  --no-automap           leave Dolphin's controller mapping alone for this run
  --dolphin ARGS...      plain Dolphin, ARGS go to dolphin-emu
  --tool ARGS...         dolphin-tool
  --forget               forget the remembered disc
  --version              the AppImage and Dolphin versions

Escape quits the game. Gamepads connected at start are mapped to GameCube ports
1-4. Without one, the keyboard is port 1. A gamepad plugged in later gets the
next free port: quit and start the game again to use it. Once you change the
mapping in Dolphin, it stays yours.

Settings: $SETTINGS
Dolphin settings: $DOLPHIN_CONFIG
EOF
}

# --- disc handling ---------------------------------------------------------------

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

# setting KEY DEFAULT: the value from settings.ini, or DEFAULT when the key is missing.
setting() {
	if [ -f "$SETTINGS" ] && v=$(awk -v k="$1" '
		index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit }
		END { exit !found }' "$SETTINGS"); then
		printf '%s\n' "$v"
	else
		printf '%s\n' "$2"
	fi
}

# set_setting KEY VALUE
set_setting() {
	mkdir -p "$CONFIG_DIR"
	{
		# grep finds nothing when KEY was the only line; that is fine.
		if [ -f "$SETTINGS" ]; then grep -v "^$1=" "$SETTINGS" || true; fi
		printf '%s=%s\n' "$1" "$2"
	} > "$SETTINGS.tmp"
	mv -f "$SETTINGS.tmp" "$SETTINGS"
}

# The disc path used to live in its own file.
if [ -f "$OLD_DISC_FILE" ]; then
	[ -n "$(setting disc '')" ] || set_setting disc "$(cat "$OLD_DISC_FILE")"
	rm -f "$OLD_DISC_FILE"
fi

remembered_disc() {
	d=$(setting disc '')
	[ -f "$d" ] && printf '%s\n' "$d"
	return 0
}

remember_disc() {
	set_setting disc "$1"
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

# --- controller automap ------------------------------------------------------------
#
# Dolphin binds a mapping to one device by name ("SDL/0/Xbox Series X Controller"),
# so a fixed config only works for the controller it was made with. Before each
# boot, mkdd-pads lists the connected controllers with the names Dolphin's SDL
# backend will give them, and pad N gets GameCube port N in GCPadNew.ini.
#
# Only the keys below are written; everything else in the file stays. A copy of
# what was written goes to WRITTEN_INI. Dolphin rewrites GCPadNew.ini at every
# start, so a marker comment would not survive. Instead, the next launch compares
# the file against that copy: if any written key differs, the user remapped in
# Dolphin and automap leaves the file alone from then on.
#
# A GCPadNew.ini that automap did not write is only taken over when it maps no
# gamepad at all (Dolphin's keyboard defaults); it is kept in BACKUP_INI and put
# back when no gamepad is connected, so the keyboard works again.
#
# While Dolphin runs, mkdd-pads --watch reports controllers coming and going
# (watch_pads below). A new gamepad gets the first free port, and the player is
# told to start the game again, because Dolphin reads the mapping at game start.

# ini_get FILE SECTION KEY: print the value, or nothing.
ini_get() {
	[ -f "$1" ] || return 0
	awk -v s="[$2]" -v k="$3" '
		{ sub(/\r$/, "") }
		/^\[/ { in_s = ($0 == s); next }
		in_s && (i = index($0, "=")) {
			key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
			if (key == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }
		}' "$1"
}

# ini_pairs FILE SECTION: print "key=value" lines of SECTION.
ini_pairs() {
	[ -f "$1" ] || return 0
	awk -v s="[$2]" '
		{ sub(/\r$/, "") }
		/^\[/ { in_s = ($0 == s); next }
		in_s && (i = index($0, "=")) {
			key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
			v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
			print key "=" v
		}' "$1"
}

# ini_contains WANT HAVE: true when every key of WANT has the same value in HAVE.
ini_contains() {
	awk '
		{ sub(/\r$/, "") }
		/^\[/ { sec = $0; next }
		(i = index($0, "=")) {
			key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
			v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
			if (FILENAME == ARGV[1]) want[sec SUBSEP key] = v
			else have[sec SUBSEP key] = v
		}
		END { for (k in want) if (!(k in have) || have[k] != want[k]) exit 1 }' "$1" "$2"
}

# ini_merge NEW CURRENT: print CURRENT with every key of NEW set to its NEW value.
# A line "-key" in NEW removes that key from the section.
ini_merge() {
	awk '
		function flush(   j) {
			if (cur == "" || !(cur in nkeys)) return
			for (j = 1; j <= nkeys[cur]; j++)
				if (!done[cur SUBSEP j]) print order[cur SUBSEP j] " = " val[cur SUBSEP order[cur SUBSEP j]]
			seen[cur] = 1
		}
		{ sub(/\r$/, "") }
		FILENAME == ARGV[1] {
			if (/^\[/) { sec = $0; if (!(sec in nkeys)) { nkeys[sec] = 0; secs[++nsecs] = sec } ; next }
			if (/^-/) { del[sec SUBSEP substr($0, 2)] = 1; next }
			if ((i = index($0, "="))) {
				key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
				v = substr($0, i + 1); sub(/^[ \t]+/, "", v)
				order[sec SUBSEP (++nkeys[sec])] = key; pos[sec SUBSEP key] = nkeys[sec]; val[sec SUBSEP key] = v
			}
			next
		}
		/^\[/ { flush(); cur = $0; print; next }
		(i = index($0, "=")) && (cur in nkeys) {
			key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
			if ((cur SUBSEP key) in del) next
			if ((cur SUBSEP key) in pos) {
				if (!done[cur SUBSEP pos[cur SUBSEP key]]) print key " = " val[cur SUBSEP key]
				done[cur SUBSEP pos[cur SUBSEP key]] = 1
				next
			}
		}
		{ print }
		END {
			flush()
			for (s = 1; s <= nsecs; s++) {
				if (secs[s] in seen) continue
				print secs[s]
				for (j = 1; j <= nkeys[secs[s]]; j++) print order[secs[s] SUBSEP j] " = " val[secs[s] SUBSEP order[secs[s] SUBSEP j]]
			}
		}' "$1" "$2"
}

# Connected controllers as "<id>\t<gamepad>\t<name>". MKDD_PADS replaces the
# detection (for testing), in the same format. Fails when detection fails.
list_pads() {
	if [ -n "${MKDD_PADS+x}" ]; then
		[ -n "$MKDD_PADS" ] && printf '%s\n' "$MKDD_PADS"
		return 0
	fi
	[ -x "$PADS_TOOL" ] || return 1
	# Dolphin's own SDL hints, so names come out the same.
	hints=$(ini_pairs "$MAIN_INI" SDL_Hints | tr '\n' ' ')
	# shellcheck disable=SC2086
	if command -v timeout >/dev/null 2>&1; then
		timeout 10 "$PADS_TOOL" $hints 2>/dev/null
	else
		"$PADS_TOOL" $hints 2>/dev/null
	fi
}

# The gamepads in a pad list, as "<id>/<name>" (the part after "SDL/").
gamepads() {
	printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $2 == 1 { print $1 "/" $3 }'
}

# The mapping for a gamepad. GameCube buttons go by position: A is the bottom
# face button, B the left one.
PAD_MAP='Buttons/A = `Button S`
Buttons/B = `Button W`
Buttons/X = `Button E`
Buttons/Y = `Button N`
Buttons/Z = `Shoulder R`
Buttons/Start = `Start`
Main Stick/Up = `Left Y+`
Main Stick/Down = `Left Y-`
Main Stick/Left = `Left X-`
Main Stick/Right = `Left X+`
C-Stick/Up = `Right Y+`
C-Stick/Down = `Right Y-`
C-Stick/Left = `Right X-`
C-Stick/Right = `Right X+`
Triggers/L = `Trigger L`
Triggers/R = `Trigger R`
Triggers/L-Analog = `Trigger L`
Triggers/R-Analog = `Trigger R`
D-Pad/Up = `Pad N`
D-Pad/Down = `Pad S`
D-Pad/Left = `Pad W`
D-Pad/Right = `Pad E`
Rumble/Motor = `Motor`'
# Keys from Dolphin's keyboard defaults that do not suit a gamepad: the square
# stick calibration would cut off the diagonals of a round stick.
PAD_DROP='Main Stick/Modifier
Main Stick/Calibration
C-Stick/Modifier
C-Stick/Calibration'
# A port turned on for hotplug but with no gamepad yet gets a device that does
# not exist. Dolphin then shows the port as unplugged to the game; without a
# section it would fall back to the keyboard and every port would move at once.
NO_PAD_DEVICE="SDL/0/No controller (mkdd-appimage)"

# section PORT [ID/NAME]: GCPadNew.ini section for a port, empty without a pad.
section() {
	printf '[GCPad%s]\n' "$1"
	if [ -n "$2" ]; then
		printf 'Device = SDL/%s\n%s\n' "$2" "$PAD_MAP"
		printf '%s\n' "$PAD_DROP" | sed 's/^/-/'
	else
		printf 'Device = %s\n' "$NO_PAD_DEVICE"
		printf '%s\n' "$PAD_MAP" | sed 's/ = .*//; s/^/-/'
	fi
}

# Who owns GCPadNew.ini. Prints: absent, automap, adoptable, adapter or user.
pad_ini_owner() {
	for i in 0 1 2 3; do
		# 12 = SIDEVICE_WIIU_ADAPTER: Dolphin drives the GameCube adapter itself.
		[ "$(ini_get "$MAIN_INI" Core "SIDevice$i")" = 12 ] && { echo adapter; return; }
	done
	if [ ! -f "$PAD_INI" ]; then
		echo absent
	elif [ -f "$WRITTEN_INI" ]; then
		# The previous copy counts too: Dolphin can save the mapping it loaded at
		# the last game start over a hotplug write, e.g. from the Controllers window.
		if ini_contains "$WRITTEN_INI" "$PAD_INI" \
			|| { [ -f "$WRITTEN_INI.prev" ] && ini_contains "$WRITTEN_INI.prev" "$PAD_INI"; }; then
			echo automap
		else
			echo user
		fi
	elif grep -qE '^Device *= *(SDL|evdev)/' "$PAD_INI"; then
		# The user mapped a controller themselves.
		echo user
	else
		# Keyboard only, which is Dolphin's default.
		echo adoptable
	fi
}

# Port state. PORT_DEV_n is the "<id>/<name>" of the gamepad on port n, empty
# for none. PORT_ON_n: 1 = a standard controller this run, 2 = free to turn on,
# 0 = the user set the port up as something else.
PORT_DEV_1= PORT_DEV_2= PORT_DEV_3= PORT_DEV_4=
PORT_ON_1=0 PORT_ON_2=0 PORT_ON_3=0 PORT_ON_4=0
AUTOMAP_ARGS=
AUTOMAP_ACTIVE=0

read_port_setup() {
	for n in 1 2 3 4; do
		cur=$(ini_get "$MAIN_INI" Core "SIDevice$((n - 1))")
		# 6 = SIDEVICE_GC_CONTROLLER, Dolphin's default for port 1 only.
		[ "$n" = 1 ] && [ -z "$cur" ] && cur=6
		case "$cur" in
			6) on=1 ;;
			''|0) on=2 ;;
			*) on=0 ;;
		esac
		eval "PORT_ON_$n=$on"
	done
}

# Write the port state into GCPadNew.ini, taking over a keyboard-only file
# first, and keep a copy of what was written.
write_ports() {
	owner="$1"
	mkdir -p "$CONFIG_DIR" "$DOLPHIN_CONFIG"
	[ "$owner" = adoptable ] && cp -f "$PAD_INI" "$BACKUP_INI"
	new="$CONFIG_DIR/GCPadNew.new.ini"
	: > "$new"
	for n in 1 2 3 4; do
		# Names of their own: sh has no local variables, and callers use dev and on.
		eval "w_dev=\$PORT_DEV_$n w_on=\$PORT_ON_$n"
		if [ -n "$w_dev" ]; then
			section "$n" "$w_dev" >> "$new"
		elif [ "$w_on" = 1 ] && [ "$n" != 1 ]; then
			# Port 1 without a gamepad keeps the keyboard.
			section "$n" >> "$new"
		fi
	done
	if [ -f "$PAD_INI" ]; then
		ini_merge "$new" "$PAD_INI" > "$PAD_INI.mkdd-tmp"
	else
		grep -v '^-' "$new" > "$PAD_INI.mkdd-tmp" || true
	fi
	mv -f "$PAD_INI.mkdd-tmp" "$PAD_INI"
	[ -f "$WRITTEN_INI" ] && mv -f "$WRITTEN_INI" "$WRITTEN_INI.prev"
	grep -v '^-' "$new" > "$WRITTEN_INI" || true
	rm -f "$new"
}

# Map connected gamepads to ports before Dolphin starts. Sets AUTOMAP_ARGS
# (extra dolphin-emu arguments) and AUTOMAP_ACTIVE (watch for hotplug).
automap() {
	[ "${MKDD_AUTOMAP:-$(setting automap 1)}" = 0 ] && return 0
	owner=$(pad_ini_owner)
	case "$owner" in
		adapter|user) return 0 ;;
	esac
	pads=$(list_pads) || { say "Controller detection failed; leaving the mapping alone."; return 0; }
	AUTOMAP_ACTIVE=1
	read_port_setup
	found=$(gamepads "$pads")

	if [ -z "$found" ]; then
		# No gamepad: give the keyboard back if automap had taken over. Ports
		# 2-4 stay off, so a gamepad plugged in during this run gets port 1.
		if [ "$owner" = automap ]; then
			if [ -f "$BACKUP_INI" ]; then mv -f "$BACKUP_INI" "$PAD_INI"; else rm -f "$PAD_INI"; fi
			rm -f "$WRITTEN_INI" "$WRITTEN_INI.prev"
		fi
		for n in 2 3 4; do eval "[ \"\$PORT_ON_$n\" = 2 ] && PORT_ON_$n=0"; done
		say "No gamepad found; port 1 uses Dolphin's keyboard mapping."
		return 0
	fi

	# Pads fill the ports in order. Every free port is turned on for this run
	# (-C is not saved), so a gamepad plugged in later has somewhere to go.
	rest="$found"
	for n in 1 2 3 4; do
		eval "on=\$PORT_ON_$n"
		[ "$on" = 0 ] && continue
		if [ "$on" = 2 ]; then
			eval "PORT_ON_$n=1"
			AUTOMAP_ARGS="$AUTOMAP_ARGS -C Dolphin.Core.SIDevice$((n - 1))=6"
		fi
		[ -n "$rest" ] || continue
		dev=$(printf '%s\n' "$rest" | head -n 1)
		rest=$(printf '%s\n' "$rest" | sed 1d)
		eval "PORT_DEV_$n=\$dev"
		say "Port $n: ${dev#*/}"
	done
	write_ports "$owner"
}

# notify TITLE TEXT: tell the player, also outside the terminal.
notify() {
	say "$1: $2"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -a "Mario Kart: Double Dash!!" "$1" "$2" >/dev/null 2>&1 || true
	fi
}

# The controller events while Dolphin runs: lines "<tag>\t<id>\t<gamepad>\t<name>"
# with tag "=" (there at start), "+" (plugged in) or "-" (unplugged), and a
# line "." after the "=" lines. MKDD_PADS_EVENTS replaces them (for testing).
pad_events() {
	if [ -n "${MKDD_PADS_EVENTS+x}" ]; then
		printf '%s\n' "$MKDD_PADS_EVENTS"
		return 0
	fi
	hints=$(ini_pairs "$MAIN_INI" SDL_Hints | tr '\n' ' ')
	# shellcheck disable=SC2086
	"$PADS_TOOL" --watch "$1" $hints 2>/dev/null
}

# Hotplug: give a gamepad plugged in during the run a port and write its
# mapping. Dolphin reads GCPadNew.ini when a game starts (Core.cpp, Pad::LoadConfig),
# so it works once the game is started again. A pad that already
# has a port needs nothing: Dolphin binds it again by name when it comes back.
watch_pads() {
	connected=
	initial=
	pad_events "$1" | while IFS="$(printf '\t')" read -r tag id gamepad name; do
		dev="$id/$name"
		case "$tag" in
			-)
				connected=$(printf '%s\n' "$connected" | grep -vxF -- "$dev" || true)
				continue ;;
			=)
				connected=$(printf '%s\n%s' "$connected" "$dev")
				[ "$gamepad" = 1 ] && initial=$(printf '%s\n%s' "$initial" "$dev")
				continue ;;
			.)
				# Pads that were there at start but missed by automap, e.g. plugged
				# in while Dolphin started.
				todo="$initial" ;;
			+)
				connected=$(printf '%s\n%s' "$connected" "$dev")
				[ "$gamepad" = 1 ] || continue
				todo="$dev" ;;
			*) continue ;;
		esac
		printf '%s\n' "$todo" | while IFS= read -r dev; do
			[ -n "$dev" ] || continue
			assign_port "$dev" "$connected"
		done
	done
}

# assign_port ID/NAME CONNECTED: give a new gamepad the first port that is on
# and has no connected gamepad. The port state lives in this file, since the
# watch loop runs in subshells.
assign_port() {
	dev="$1"
	connected="$2"
	state="$CONFIG_DIR/ports.run"
	# shellcheck disable=SC1090
	[ -f "$state" ] && . "$state"
	for n in 1 2 3 4; do
		eval "[ \"\$PORT_DEV_$n\" = \"\$dev\" ]" && return 0
	done
	owner=$(pad_ini_owner)
	case "$owner" in
		adapter|user) return 0 ;;
	esac
	free=
	for n in 1 2 3 4; do
		eval "on=\$PORT_ON_$n cur=\$PORT_DEV_$n"
		[ "$on" = 1 ] || continue
		if [ -z "$cur" ] || ! printf '%s\n' "$connected" | grep -qxF -- "$cur"; then
			free=$n
			break
		fi
	done
	if [ -z "$free" ]; then
		if [ "$PORT_ON_2$PORT_ON_3$PORT_ON_4" = 000 ]; then
			notify "Controller connected" "${dev#*/}: quit and start the game again to use it next to the first one."
		else
			notify "Controller connected" "${dev#*/}: all ports are in use."
		fi
		return 0
	fi
	eval "PORT_DEV_$free=\$dev"
	write_ports "$owner"
	save_port_state
	notify "Controller on port $free" "${dev#*/}: quit and start the game again to use it."
}

save_port_state() {
	mkdir -p "$CONFIG_DIR"
	for n in 1 2 3 4; do
		eval "v=\$PORT_DEV_$n o=\$PORT_ON_$n"
		printf 'PORT_DEV_%s=%s\nPORT_ON_%s=%s\n' "$n" "$(quote "$v")" "$n" "$o"
	done > "$CONFIG_DIR/ports.run"
}

# quote STRING: STRING as a single-quoted shell word.
quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# boot ARGS...: start Dolphin; with automap on, watch for hotplug while it runs.
boot() {
	if [ "$AUTOMAP_ACTIVE" = 1 ] && { [ -n "${MKDD_PADS_EVENTS+x}" ] || [ -x "$PADS_TOOL" ]; }; then
		save_port_state
		# shellcheck disable=SC2086
		"$DOLPHIN" dolphin-emu $AUTOMAP_ARGS "$@" &
		dolphin_pid=$!
		watch_pads "$dolphin_pid" &
		watch_pid=$!
		status=0
		wait "$dolphin_pid" || status=$?
		# mkdd-pads stops by itself within half a second once Dolphin is gone.
		wait "$watch_pid" || true
		rm -f "$CONFIG_DIR/ports.run"
		exit "$status"
	fi
	# shellcheck disable=SC2086
	exec "$DOLPHIN" dolphin-emu $AUTOMAP_ARGS "$@"
}

show_pads() {
	pads=$(list_pads) || { say "Controller detection failed."; exit 1; }
	if [ -z "$pads" ]; then
		echo "No controllers connected."
	else
		port=0
		printf '%s\n' "$pads" | while IFS="$(printf '\t')" read -r id gamepad name; do
			if [ "$gamepad" = 1 ] && [ "$port" -lt 4 ]; then
				port=$((port + 1))
				echo "Port $port: SDL/$id/$name"
			else
				echo "No port: SDL/$id/$name (not a gamepad SDL knows)"
			fi
		done
	fi
	case "$(pad_ini_owner)" in
		adapter) echo "Mapping: left alone, Dolphin uses the GameCube adapter." ;;
		user) echo "Mapping: yours, automap leaves $PAD_INI alone." ;;
		*)
			if [ -n "$(gamepads "$pads")" ]; then
				echo "Mapping: automap writes $PAD_INI at the next boot."
			else
				echo "Mapping: Dolphin's keyboard mapping on port 1 (no gamepad)."
			fi ;;
	esac
}

# --- settings window and starting the game ----------------------------------------

has_display() { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }

# The settings window's choices as Dolphin overrides for this run (-C is not
# saved). Always batch mode: no Dolphin main window, and quitting the game
# (Escape, Dolphin's default Stop key) ends the run, as Steam expects.
# run_overrides [fullscreen]: sets RUN_ARGS; "fullscreen" forces it on.
RUN_ARGS=
run_overrides() {
	RUN_ARGS="-b -C Dolphin.Interface.ConfirmStop=False"
	if [ "$1" = fullscreen ] || [ "$(setting fullscreen 1)" = 1 ]; then
		RUN_ARGS="$RUN_ARGS -C Dolphin.Display.Fullscreen=True"
	else
		RUN_ARGS="$RUN_ARGS -C Dolphin.Display.Fullscreen=False"
	fi
	case "$(setting resolution 0)" in
		0|1|2|3|4|5|6|8) RUN_ARGS="$RUN_ARGS -C Graphics.Settings.InternalResolution=$(setting resolution 0)" ;;
	esac
	case "$(setting backend '')" in
		Vulkan|OGL) RUN_ARGS="$RUN_ARGS -C Dolphin.Core.GFXBackend=$(setting backend '')" ;;
	esac
	if [ "$(setting vsync 1)" = 1 ]; then
		RUN_ARGS="$RUN_ARGS -C Graphics.Hardware.VSync=True"
	else
		RUN_ARGS="$RUN_ARGS -C Graphics.Hardware.VSync=False"
	fi
	if [ "$(setting widescreen 0)" = 1 ]; then
		# 1 = AspectMode::ForceWide
		RUN_ARGS="$RUN_ARGS -C Graphics.Settings.wideScreenHack=True -C Graphics.Settings.AspectRatio=1"
	else
		RUN_ARGS="$RUN_ARGS -C Graphics.Settings.wideScreenHack=False"
	fi
	vol=$(setting volume 100)
	case "$vol" in
		''|*[!0-9]*) ;;
		*) [ "$vol" -le 100 ] && RUN_ARGS="$RUN_ARGS -C Dolphin.DSP.Volume=$vol" ;;
	esac
	return 0
}

# settings_window [NOTICE] [MODE]: show the window; Play starts the game in MODE.
settings_window() {
	if ! has_display || [ ! -x "$SETTINGS_TOOL" ]; then
		# No window possible (e.g. over ssh): start the game as before.
		play "$2" ""
	fi
	code=0
	MKDD_DOLPHIN_VERSION=$(cat "$APPDIR/dolphin-version" 2>/dev/null || true) \
	MKDD_APPIMAGE_VERSION=$(cat "$APPDIR/version" 2>/dev/null || true) \
		"$SETTINGS_TOOL" "$SETTINGS" "$1" || code=$?
	case "$code" in
		10) play "$2" "" asked ;;
		11) exec "$DOLPHIN" dolphin-emu ;;
		*) exit 0 ;;
	esac
}

# boot_dol DOL DISC: boot a main.dol built by the decomp with DISC's files.
boot_dol() {
	[ -f "$1" ] || { say "No DOL at $1. Build it first: python configure.py && ninja"; exit 1; }
	dol=$(abspath "$1")
	root=$(extract_disc "$2")
	# Dolphin boots <root>/sys/main.dol as a full disc, with <root>/files as its files.
	cp -f "$dol" "$root/sys/main.dol"
	automap
	say "Booting $dol with the files of $2"
	# shellcheck disable=SC2086
	boot $RUN_ARGS -e "$root/sys/main.dol"
}

# play MODE [DISC] [asked]: start the game with the saved settings. MODE
# "fullscreen" is --game. Without a disc, the settings window asks for one,
# once: "asked" means it already did.
play() {
	d="$2"
	[ -n "$d" ] || d=$(remembered_disc)
	if [ -z "$d" ] && [ "$3" != asked ] && has_display && [ -x "$SETTINGS_TOOL" ]; then
		settings_window "Pick your disc image, then press Play." "$1"
	fi
	disc=$(need_disc "$d")
	run_overrides "$1"
	if [ "$(setting use_dol 0)" = 1 ] && [ -n "$(setting dol '')" ]; then
		boot_dol "$(setting dol '')" "$disc"
	fi
	automap
	# shellcheck disable=SC2086
	boot $RUN_ARGS -e "$disc"
}

# --- main ----------------------------------------------------------------------

if [ "$1" = --no-automap ]; then
	MKDD_AUTOMAP=0
	shift
fi

case "$1" in
	''|--settings)
		settings_window "" "" ;;
	--game)
		shift
		play fullscreen "$1" ;;
	-h|--help)
		usage
		exit 0 ;;
	--version)
		printf 'MKDD AppImage %s (Dolphin %s)\n' "$(cat "$APPDIR/version" 2>/dev/null || echo unknown)" \
			"$(cat "$APPDIR/dolphin-version" 2>/dev/null || echo unknown)"
		exit 0 ;;
	--pads)
		show_pads
		exit 0 ;;
	--dolphin)
		shift
		exec "$DOLPHIN" dolphin-emu "$@" ;;
	--tool)
		shift
		exec "$DOLPHIN" dolphin-tool "$@" ;;
	--forget)
		set_setting disc ''
		say "Forgot the remembered disc."
		exit 0 ;;
	--dol)
		shift
		dol="${1:-$DEFAULT_DOL}"
		[ $# -gt 0 ] && shift
		disc=$(need_disc "$1")
		run_overrides ""
		boot_dol "$dol" "$disc" ;;
	-*)
		usage >&2
		exit 1 ;;
esac

play "" "$1"
