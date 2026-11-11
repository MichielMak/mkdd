#!/usr/bin/env bash
# Tests for the launcher (AppRun.sh): settings, --game and the controller
# automap. Dolphin and the settings window are replaced by stubs that record
# their arguments, and MKDD_PADS stands in for connected controllers.
#
# Usage: appimage/test-launcher.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/appdir"
cat > "$T/appdir/AppRun.dolphin.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_OUT"
EOF
chmod +x "$T/appdir/AppRun.dolphin.sh"
touch "$T/disc.iso"

TAB=$'\t'
PAD_INI="$T/home/.config/dolphin-emu/GCPadNew.ini"
MAIN_INI="$T/home/.config/dolphin-emu/Dolphin.ini"
WRITTEN="$T/home/.config/mkdd-appimage/GCPadNew.written.ini"
fails=0

reset() { rm -rf "$T/home"; mkdir -p "$T/home"; }
# run [ARGS...]: launch with MKDD_PADS from the caller's environment.
run() {
  launch "$@" "$T/disc.iso"
}
# launch [ARGS...]: like run, without adding the disc. No display unless DISPLAY
# is passed in as SHOW_DISPLAY.
launch() {
  rm -f "$T/args" "$T/window"
  env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u DOLPHIN_EMU_USERPATH -u DISPLAY -u WAYLAND_DISPLAY \
    ${SHOW_DISPLAY:+DISPLAY=$SHOW_DISPLAY} HOME="$T/home" \
    APPDIR="$T/appdir" STUB_OUT="$T/args" sh "$HERE/AppRun.sh" "$@" 2>"$T/stderr"
}
SETTINGS="$T/home/.config/mkdd-appimage/settings.ini"
has_arg() { [ -f "$T/args" ] && grep -qxF -- "$1" "$T/args"; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; sed 's/^/     /' "$T/stderr"; fi; }
value() { awk -v s="[$1]" -v k="$2" '/^\[/{in_s=($0==s);next} in_s{i=index($0,"=");key=substr($0,1,i-1);sub(/ +$/,"",key);if(key==k){v=substr($0,i+1);sub(/^ +/,"",v);print v;exit}}' "$PAD_INI"; }

echo "# fresh install, one pad"
reset
MKDD_PADS="0${TAB}1${TAB}Xbox Series X Controller" run
check "port 1 device" '[ "$(value GCPad1 Device)" = "SDL/0/Xbox Series X Controller" ]'
check "A on bottom face button" '[ "$(value GCPad1 Buttons/A)" = "\`Button S\`" ]'
check "B on left face button" '[ "$(value GCPad1 Buttons/B)" = "\`Button W\`" ]'
check "analog R" '[ "$(value GCPad1 Triggers/R-Analog)" = "\`Trigger R\`" ]'
check "free ports 2-4 on for hotplug" '[ "$(grep -c "^Dolphin.Core.SIDevice" "$T/args")" = 3 ] && ! grep -q SIDevice0 "$T/args"'
check "ports 2-4 unplugged until a pad comes" '[ "$(value GCPad2 Device)" = "SDL/0/No controller (mkdd-appimage)" ] && [ -z "$(value GCPad2 Buttons/A)" ]'
check "boots the disc" 'tail -1 "$T/args" | grep -q disc.iso'

echo "# Dolphin rewrites the file and adds its own keys; then a different pad"
sed -i '/^\[GCPad1\]$/a Main Stick/Dead Zone = 12.0\nOptions/Always Connected = True' "$PAD_INI"
MKDD_PADS="0${TAB}1${TAB}PS5 Controller" run
check "device follows the connected pad" '[ "$(value GCPad1 Device)" = "SDL/0/PS5 Controller" ]'
check "Dolphin's own keys kept" '[ "$(value GCPad1 "Main Stick/Dead Zone")" = "12.0" ] && [ "$(value GCPad1 "Options/Always Connected")" = True ]'
check "no duplicate keys" '[ "$(grep -c "^Buttons/A" "$PAD_INI")" = 1 ]'

echo "# two identical pads plus a non-gamepad joystick"
MKDD_PADS="0${TAB}1${TAB}Xbox Controller
0${TAB}0${TAB}Racing Wheel
1${TAB}1${TAB}Xbox Controller" run
check "port 1 is the first pad" '[ "$(value GCPad1 Device)" = "SDL/0/Xbox Controller" ]'
check "port 2 is the second, id 1" '[ "$(value GCPad2 Device)" = "SDL/1/Xbox Controller" ]'
check "wheel gets no port" '! grep -q "Racing Wheel" "$PAD_INI"'
check "port 2 enabled for this run" 'grep -qx "Dolphin.Core.SIDevice1=6" "$T/args"'
check "port 3 cleared when its pad is gone" '[ "$(value GCPad3 Device)" = "SDL/0/No controller (mkdd-appimage)" ]'
check "port 2 setting not saved" '[ ! -f "$MAIN_INI" ] || ! grep -q SIDevice1 "$MAIN_INI"'

echo "# five pads: only four ports"
MKDD_PADS=$(for i in 0 1 2 3 4; do printf '%s\t1\tPad\n' "$i"; done) run
check "port 4 mapped" '[ "$(value GCPad4 Device)" = "SDL/3/Pad" ]'
check "no port 5" '! grep -q "^\[GCPad5\]" "$PAD_INI"'
check "ports 2-4 enabled" '[ "$(grep -c "^Dolphin.Core.SIDevice" "$T/args")" = 3 ]'

echo "# a port the user set up stays as it is"
mkdir -p "$(dirname "$MAIN_INI")"
printf '[Core]\nSIDevice1 = 5\n' > "$MAIN_INI"
MKDD_PADS="0${TAB}1${TAB}A
0${TAB}1${TAB}B" run
check "port 2 not overridden" '! grep -q SIDevice1 "$T/args"'
rm -f "$MAIN_INI"

echo "# no pad: keyboard again"
MKDD_PADS="" run
check "automap file removed" '[ ! -f "$PAD_INI" ] && [ ! -f "$WRITTEN" ]'
check "says keyboard" 'grep -q "keyboard" "$T/stderr"'
check "ports 2-4 stay off" '! grep -q SIDevice "$T/args"'

echo "# the keyboard mapping's square stick calibration is dropped for a pad"
reset
mkdir -p "$(dirname "$PAD_INI")"
printf '[GCPad1]\nDevice = XInput2/0/Virtual core pointer\nMain Stick/Calibration = 100.00 141.42\nMain Stick/Modifier = `Shift`\n' > "$PAD_INI"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "calibration and modifier gone" '! grep -q "Calibration\|Modifier" "$PAD_INI"'

echo "# hotplug: a second pad while Dolphin runs"
reset
MKDD_PADS="0${TAB}1${TAB}Xbox" MKDD_PADS_EVENTS="=${TAB}0${TAB}1${TAB}Xbox
.
+${TAB}0${TAB}1${TAB}PS5 Controller" run
check "PS5 pad on port 2" '[ "$(value GCPad2 Device)" = "SDL/0/PS5 Controller" ]'
check "port 1 unchanged" '[ "$(value GCPad1 Device)" = "SDL/0/Xbox" ]'
check "tells to restart the game" 'grep -q "port 2.*start the game again" "$T/stderr"'
check "still automap afterwards" 'MKDD_PADS="0${TAB}1${TAB}Xbox" run; grep -q "Port 1" "$T/stderr"'

echo "# hotplug: the same pad unplugged and back needs nothing"
reset
MKDD_PADS="0${TAB}1${TAB}Xbox" MKDD_PADS_EVENTS="=${TAB}0${TAB}1${TAB}Xbox
.
-${TAB}0${TAB}1${TAB}Xbox
+${TAB}0${TAB}1${TAB}Xbox" run
check "no notice" '! grep -q "start the game again" "$T/stderr"'
check "port 2 still free" '[ "$(value GCPad2 Device)" = "SDL/0/No controller (mkdd-appimage)" ]'

echo "# hotplug: a different pad replaces an unplugged one"
reset
MKDD_PADS="0${TAB}1${TAB}Xbox" MKDD_PADS_EVENTS="=${TAB}0${TAB}1${TAB}Xbox
.
-${TAB}0${TAB}1${TAB}Xbox
+${TAB}0${TAB}1${TAB}8BitDo Pro 2" run
check "new pad takes port 1" '[ "$(value GCPad1 Device)" = "SDL/0/8BitDo Pro 2" ]'
check "notice names the new pad" 'grep -q "port 1: 8BitDo Pro 2" "$T/stderr"'

echo "# hotplug: no pad at start, then one"
reset
MKDD_PADS="" MKDD_PADS_EVENTS=".
+${TAB}0${TAB}1${TAB}Pad
+${TAB}1${TAB}1${TAB}Pad" run
check "first gets port 1" '[ "$(value GCPad1 Device)" = "SDL/0/Pad" ]'
check "second: ports 2-4 were off, restart needed" 'grep -q "next to the first one" "$T/stderr" && ! grep -q "^\[GCPad2\]" "$PAD_INI"'

echo "# hotplug: a pad that came while Dolphin started"
reset
MKDD_PADS="0${TAB}1${TAB}A" MKDD_PADS_EVENTS="=${TAB}0${TAB}1${TAB}A
=${TAB}0${TAB}1${TAB}B
." run
check "gets port 2" '[ "$(value GCPad2 Device)" = "SDL/0/B" ]'

echo "# hotplug: all four ports in use"
reset
MKDD_PADS=$(for p in A B C D; do printf '0\t1\t%s\n' "$p"; done) \
MKDD_PADS_EVENTS="$(for p in A B C D; do printf '=\t0\t1\t%s\n' "$p"; done)
.
+${TAB}0${TAB}1${TAB}E" run
check "says so" 'grep -q "all ports are in use" "$T/stderr"'
check "E not mapped" '! grep -q "SDL/0/E" "$PAD_INI"'

echo "# hotplug: a non-gamepad joystick is ignored"
reset
MKDD_PADS="0${TAB}1${TAB}A" MKDD_PADS_EVENTS=".
+${TAB}0${TAB}0${TAB}Wheel" run
check "no notice" '! grep -q "Wheel" "$T/stderr"'

echo "# hotplug: the user remapped, so nothing is written"
reset
MKDD_PADS="0${TAB}1${TAB}A" run
sed -i 's/^Buttons\/A = .*/Buttons\/A = `Button E`/' "$PAD_INI"
cp "$PAD_INI" "$T/user"
MKDD_PADS="0${TAB}1${TAB}A" MKDD_PADS_EVENTS=".
+${TAB}0${TAB}1${TAB}B" run
check "file untouched" 'cmp -s "$PAD_INI" "$T/user"'

echo "# Dolphin saves its stale mapping over a hotplug write"
reset
MKDD_PADS="0${TAB}1${TAB}A" run
cp "$PAD_INI" "$T/before"
MKDD_PADS="0${TAB}1${TAB}A" MKDD_PADS_EVENTS=".
+${TAB}0${TAB}1${TAB}B" run
cp "$T/before" "$PAD_INI"
MKDD_PADS="0${TAB}1${TAB}A
0${TAB}1${TAB}B" run
check "still automap" '[ "$(value GCPad2 Device)" = "SDL/0/B" ]'

echo "# Dolphin's keyboard defaults get backed up and restored"
reset
mkdir -p "$(dirname "$PAD_INI")"
printf '[GCPad1]\nDevice = XInput2/0/Virtual core pointer\nButtons/A = `X`\n' > "$PAD_INI"
cp "$PAD_INI" "$T/orig"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "taken over" '[ "$(value GCPad1 Device)" = "SDL/0/Pad" ]'
MKDD_PADS="" run
check "keyboard file restored" 'cmp -s "$PAD_INI" "$T/orig"'

echo "# the user remaps in Dolphin: automap stops"
reset
MKDD_PADS="0${TAB}1${TAB}Pad" run
sed -i 's/^Buttons\/A = .*/Buttons\/A = `Button E`/' "$PAD_INI"
cp "$PAD_INI" "$T/user"
MKDD_PADS="0${TAB}1${TAB}Other Pad" run
check "file untouched with a new pad" 'cmp -s "$PAD_INI" "$T/user"'
MKDD_PADS="" run
check "file untouched without a pad" 'cmp -s "$PAD_INI" "$T/user"'

echo "# an existing gamepad mapping automap never wrote"
reset
mkdir -p "$(dirname "$PAD_INI")"
printf '[GCPad1]\nDevice = SDL/0/My Pad\nButtons/A = `Button E`\n' > "$PAD_INI"
cp "$PAD_INI" "$T/user"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "left alone" 'cmp -s "$PAD_INI" "$T/user"'

echo "# GameCube adapter configured in Dolphin"
reset
mkdir -p "$(dirname "$MAIN_INI")"
printf '[Core]\nSIDevice0 = 12\n' > "$MAIN_INI"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "no mapping written" '[ ! -f "$PAD_INI" ]'

echo "# --no-automap"
reset
MKDD_PADS="0${TAB}1${TAB}Pad" run --no-automap
check "no mapping written" '[ ! -f "$PAD_INI" ]'
check "still boots" 'tail -1 "$T/args" | grep -q disc.iso'

echo "# detection fails (no mkdd-pads)"
reset
(unset MKDD_PADS; run)
check "no mapping written" '[ ! -f "$PAD_INI" ]'
check "says so" 'grep -q "detection failed" "$T/stderr"'

echo "# starting a disc: batch mode, saved settings as overrides, disc remembered"
reset
MKDD_PADS="" run
check "batch mode, no stop prompt" 'has_arg -b && has_arg Dolphin.Interface.ConfirmStop=False'
check "fullscreen by default" 'has_arg Dolphin.Display.Fullscreen=True'
check "disc remembered" 'grep -qx "disc=$T/disc.iso" "$SETTINGS"'
check "Dolphin config untouched" '[ ! -f "$MAIN_INI" ]'

echo "# settings become overrides"
reset
mkdir -p "$(dirname "$SETTINGS")"
printf 'fullscreen=0\nresolution=3\nbackend=Vulkan\nvsync=0\nwidescreen=1\nvolume=40\n' > "$SETTINGS"
MKDD_PADS="" run
check "windowed" 'has_arg Dolphin.Display.Fullscreen=False'
check "resolution" 'has_arg Graphics.Settings.InternalResolution=3'
check "renderer" 'has_arg Dolphin.Core.GFXBackend=Vulkan'
check "vsync off" 'has_arg Graphics.Hardware.VSync=False'
check "widescreen" 'has_arg Graphics.Settings.wideScreenHack=True && has_arg Graphics.Settings.AspectRatio=1'
check "volume" 'has_arg Dolphin.DSP.Volume=40'
printf 'backend=Bogus\nvolume=loud\nresolution=99\n' > "$SETTINGS"
MKDD_PADS="" run
check "bad values ignored" '! grep -q "GFXBackend\|DSP.Volume\|InternalResolution" "$T/args"'

echo "# --game: fullscreen even when the window said windowed"
reset
mkdir -p "$(dirname "$SETTINGS")"
printf 'fullscreen=0\ndisc=%s\n' "$T/disc.iso" > "$SETTINGS"
MKDD_PADS="" launch --game
check "fullscreen" 'has_arg Dolphin.Display.Fullscreen=True'
check "boots the remembered disc" 'tail -1 "$T/args" | grep -qx "$T/disc.iso"'

echo "# automap off in the settings"
reset
mkdir -p "$(dirname "$SETTINGS")"
printf 'automap=0\n' > "$SETTINGS"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "no mapping written" '[ ! -f "$PAD_INI" ]'

echo "# old disc file moves into settings.ini"
reset
mkdir -p "$T/home/.config/mkdd-appimage"
printf '%s\n' "$T/disc.iso" > "$T/home/.config/mkdd-appimage/disc"
MKDD_PADS="" launch --game
check "migrated" 'grep -qx "disc=$T/disc.iso" "$SETTINGS" && [ ! -f "$T/home/.config/mkdd-appimage/disc" ]'
check "and used" 'tail -1 "$T/args" | grep -qx "$T/disc.iso"'

# A settings window stub: records its arguments, may write settings, exits with $WINDOW_EXIT.
mkdir -p "$T/appdir/bin"
cat > "$T/appdir/bin/mkdd-settings" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_WINDOW"
mkdir -p "$(dirname "$1")"
[ -n "$WINDOW_WRITES" ] && printf '%s\n' "$WINDOW_WRITES" >> "$1"
exit "${WINDOW_EXIT:-0}"
EOF
chmod +x "$T/appdir/bin/mkdd-settings"
export STUB_WINDOW="$T/window"

echo "# no arguments: the settings window"
reset
mkdir -p "$(dirname "$SETTINGS")"
printf 'disc=%s\nfullscreen=0\n' "$T/disc.iso" > "$SETTINGS"
SHOW_DISPLAY=:0 WINDOW_EXIT=0 MKDD_PADS="" launch
check "window shown with the settings file" '[ "$(head -1 "$T/window")" = "$SETTINGS" ]'
check "Quit starts nothing" '[ ! -f "$T/args" ]'
SHOW_DISPLAY=:0 WINDOW_EXIT=10 MKDD_PADS="" launch
check "Play boots the disc with the settings" 'tail -1 "$T/args" | grep -qx "$T/disc.iso" && has_arg Dolphin.Display.Fullscreen=False'
SHOW_DISPLAY=:0 WINDOW_EXIT=11 MKDD_PADS="" launch
check "Open Dolphin starts its main window" '[ -f "$T/args" ] && ! has_arg -b && ! has_arg -e'

echo "# no display: no window, the game starts as before"
SHOW_DISPLAY= MKDD_PADS="" launch
check "boots the remembered disc" '[ ! -f "$T/window" ] && tail -1 "$T/args" | grep -qx "$T/disc.iso"'

echo "# --game without a disc asks in the window, then plays fullscreen"
reset
SHOW_DISPLAY=:0 WINDOW_EXIT=10 WINDOW_WRITES="disc=$T/disc.iso" MKDD_PADS="" launch --game
check "window says why" 'grep -q "Pick your disc image" "$T/window"'
check "then boots fullscreen" 'tail -1 "$T/args" | grep -qx "$T/disc.iso" && has_arg Dolphin.Display.Fullscreen=True'
reset
SHOW_DISPLAY=:0 WINDOW_EXIT=0 MKDD_PADS="" launch --game
check "Quit there starts nothing" '[ ! -f "$T/args" ]'
reset
SHOW_DISPLAY=:0 WINDOW_EXIT=10 MKDD_PADS="" launch --game || true
check "Play without a disc asks only once" '[ "$(grep -c "No disc image" "$T/stderr")" = 1 ] && [ ! -f "$T/args" ]'
unset STUB_WINDOW
rm -f "$T/appdir/bin/mkdd-settings"

echo "# --version"
printf '1.2.3\n' > "$T/appdir/version"
printf '2609a\n' > "$T/appdir/dolphin-version"
out=$(launch --version 2>&1; cat "$T/stderr")
check "shows both versions" '[ "$out" = "MKDD AppImage 1.2.3 (Dolphin 2609a)" ]'
check "starts nothing" '[ ! -f "$T/args" ]'
rm -f "$T/appdir/version" "$T/appdir/dolphin-version"

echo "# CRLF line endings in an existing file"
reset
mkdir -p "$(dirname "$PAD_INI")"
printf '[GCPad1]\r\nDevice = XInput2/0/Virtual core pointer\r\n' > "$PAD_INI"
MKDD_PADS="0${TAB}1${TAB}Pad" run
check "taken over" '[ "$(value GCPad1 Device | tr -d "\r")" = "SDL/0/Pad" ]'

if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
