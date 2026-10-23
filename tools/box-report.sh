#!/usr/bin/env bash
# Collects what the dev sessions can't see from the box, into one folder and
# one .tar.gz to copy back to the dev machine. Read-only apart from writing
# the report and pausing the launcher's input service during --keys; it never
# uses sudo itself.
#
#   tools/box-report.sh             system, input devices, desktop settings,
#                                   apps, icons, open windows (as test fixtures)
#   tools/box-report.sh --keys      press each remote and pad button when asked
#                                   (needs the input group, or run with sudo)
#   tools/box-report.sh --budgets   CPU and memory of the launcher and daemon,
#                                   60 s on Home and 60 s with an app in front;
#                                   easiest over ssh, so the TV keeps the focus
#   tools/box-report.sh --all       all three, one after another
#
# Before the default run, open Firefox (one tab), LibreOffice Writer with some
# unsaved text and its "Save changes?" prompt showing, and a text editor with
# unsaved text: their windows become the xprop fixtures for the daemon tests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M)"
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"
OUT="${BOX_REPORT_DIR:-$REAL_HOME/box-report-$STAMP}"
REPORT="$OUT/report.txt"
have() { command -v "$1" >/dev/null 2>&1; }

MODES=()
for arg in "$@"; do
	case "$arg" in
		--keys) MODES+=(keys) ;;
		--budgets) MODES+=(budgets) ;;
		--all) MODES+=(report keys budgets) ;;
		-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
	esac
done
[ "${#MODES[@]}" = 0 ] && MODES=(report)

mkdir -p "$OUT/fixtures/xprop"

# One titled section of report.txt: the command, then its output.
section() {
	local title="$1"; shift
	{
		printf '\n===== %s\n$ %s\n' "$title" "$*"
		if have "$1"; then timeout 20 "$@" 2>&1 || true; else echo "(not installed: $1)"; fi
	} >> "$REPORT"
}
note() { printf '\n===== %s\n%s\n' "$1" "$2" >> "$REPORT"; }

# Default report -------------------------------------------------------------------

report() {
	echo "Writing $REPORT"
	{
		echo "Box report, $(date -Is), user $REAL_USER, repo $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
	} > "$REPORT"

	echo "  system"
	section "OS" cat /etc/os-release
	section "Kernel" uname -a
	section "CPU" lscpu
	section "Memory" free -m
	section "GPU" lspci -nnk
	section "Cinnamon" cinnamon --version
	section "Session type (want x11)" printenv XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DISPLAY
	section "Screen" xrandr --current
	section "Screen, every timing (xrandr --verbose)" xrandr --verbose
	section "Kernel display messages, this boot" sh -c 'journalctl -k -b 0 --no-pager -o short-monotonic | grep -i -E "i915|drm|hdmi|dp-|link" | tail -n 80'
	section "Kernel display messages, last boot" sh -c 'journalctl -k -b -1 --no-pager -o short-monotonic | grep -i -E "i915|drm|hdmi|dp-|link" | tail -n 80'
	section "Python (daemon needs 3)" python3 --version

	echo "  tools the launcher uses"
	for t in wmctrl xprop xkill notify-send evtest flatpak firefox spotify pidstat intel_gpu_top cinnamon-settings gio xdg-user-dir; do
		printf '%-18s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
	done > "$OUT/tools.txt"
	note "Tools" "$(cat "$OUT/tools.txt")"
	section "Firefox version" firefox --version
	section "Flatpak apps" flatpak list --app --columns=application,version,installation

	echo "  input devices (RUNBOOK: G20S keycodes, devices fixture)"
	cat /proc/bus/input/devices > "$OUT/fixtures/proc_bus_input_devices.txt" 2>/dev/null
	section "Input devices" cat /proc/bus/input/devices
	section "Input by id" ls -l /dev/input/by-id
	section "Groups (want input)" id "$REAL_USER"
	section "Pads" ls -l /dev/input/js0 /dev/input/js1

	echo "  power key and key bindings (installer steps 3 to 5)"
	section "logind drop-ins" sh -c 'cat /etc/systemd/logind.conf.d/*.conf'
	section "Cinnamon power settings" sh -c 'gsettings list-recursively | grep -i -E "power|button"'
	section "Cinnamon media keys" gsettings list-recursively org.cinnamon.desktop.keybindings.media-keys
	section "Cinnamon bindings on Home, Back, Menu, Super" sh -c 'gsettings list-recursively | grep -i -E "homepage|back|menu|<super>home"'
	section "Boot splash (tools/boot-splash.sh)" sh -c 'update-alternatives --query default.plymouth | sed -n "s/^Value: //p"; ls /usr/share/plymouth/themes; grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub'
	section "Cinnamon window effects (minimise animation)" sh -c 'gsettings list-recursively | grep -i -E "effect|animation"'
	section "Installer log (install/install.sh 2>&1 | tee ~/install.log)" cat "$REAL_HOME/install.log"

	echo "  login, session and services (installer step 6, daemon service)"
	section "LightDM" sh -c 'cat /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf'
	section "X sessions" ls /usr/share/xsessions /usr/share/wayland-sessions
	section "graphical-session.target (the daemon unit needs it)" systemctl --user status graphical-session.target --no-pager
	section "Daemon service" systemctl --user status boscamor-input.service --no-pager
	section "Daemon log" journalctl --user -u boscamor-input --no-pager -n 80
	section "User manager environment (want DISPLAY)" sh -c 'systemctl --user show-environment | grep -E "DISPLAY|XAUTHORITY|WAYLAND"'
	section "Autostart entries" ls -la "$REAL_HOME/.config/autostart"
	section "Launcher files" ls -la /opt/boscamor "$REAL_HOME/.config/boscamor" "$REAL_HOME/.config/boscamor/icons" "$REAL_HOME/.local/state/boscamor"
	section "state.json" cat "$REAL_HOME/.local/state/boscamor/state.json"

	echo "  Jellyfin TV entries (step 10)"
	section "Jellyfin desktop entries" sh -c 'grep -H -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop "$HOME"/.local/share/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop'
	section "Jellyfin entries in full" sh -c 'cat /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop'

	echo "  icons (step 8)"
	section "Flatpak icon exports" sh -c 'cd /var/lib/flatpak/exports/share/icons/hicolor 2>/dev/null && find . -name "*.png" -o -name "*.svg" | sort'
	section "Installed apps: name, class, icon" sh -c 'for f in /usr/share/applications/*.desktop /var/lib/flatpak/exports/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop; do [ -f "$f" ] && printf "%s | %s | %s | %s\n" "$(basename "$f")" "$(grep -m1 "^Name=" "$f" | cut -d= -f2-)" "$(grep -m1 "^StartupWMClass=" "$f" | cut -d= -f2-)" "$(grep -m1 "^Icon=" "$f" | cut -d= -f2-)"; done'

	echo "  network (About, Wi-Fi icon)"
	section "Addresses" ip -br addr
	section "Wireless" cat /proc/net/wireless
	section "Network devices (nmcli)" nmcli -t -f TYPE,STATE,CONNECTION device
	# Network names are left out: they are the neighbours' too.
	section "Wi-Fi networks in range, names left out" sh -c 'nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list | awk -F: "{ print \$1 \":\" \$2 \":\" \$3 \":network-\" NR }"'

	echo "  sound (Settings > Sound, D80)"
	section "Sound server" pactl info
	section "Sound cards" pactl list cards
	section "Sound outputs" pactl list short sinks
	# Godot's own log: user://logs, kept for the last few logins.
	section "Launcher logs" ls -la "$REAL_HOME/.local/share/godot/app_userdata/Launcher/logs"
	section "Launcher picture, sound and Wi-Fi lines, by login" sh -c 'cd "$1" && grep -H -E "^(picture|sound|wifi): " $(ls -tr godot*.log) | tail -n 80' sh "$REAL_HOME/.local/share/godot/app_userdata/Launcher/logs"
	section "Launcher log, this login" tail -n 120 "$REAL_HOME/.local/share/godot/app_userdata/Launcher/logs/godot.log"
	section "Hostname" cat /etc/hostname

	echo "  open windows (xprop fixtures for Return to the launcher)"
	windows

	echo "  done"
}

# The daemon tests' fixture format: root.txt, then one file per window.
windows() {
	if ! have xprop; then note "Windows" "xprop missing"; return; fi
	xprop -root _NET_CLIENT_LIST > "$OUT/fixtures/xprop/root.txt" 2>&1
	local wid
	for wid in $(grep -o '0x[0-9a-fA-F]*' "$OUT/fixtures/xprop/root.txt"); do
		xprop -id "$wid" _NET_WM_WINDOW_TYPE WM_CLASS _NET_WM_NAME WM_NAME WM_TRANSIENT_FOR \
			> "$OUT/fixtures/xprop/$(printf '0x%x' "$wid").txt" 2>&1
	done
	section "Windows (wmctrl)" wmctrl -lx
	note "Windows (xprop)" "$(for f in "$OUT"/fixtures/xprop/*.txt; do echo "--- $(basename "$f")"; cat "$f"; done)"
}

# Keys -------------------------------------------------------------------------------

# True while an app opened from the launcher runs: a live child of the
# daemon, other than the helpers it runs for a moment. A flatpak app counts
# too: systemd moves it into its own scope, which stopping the service would
# leave running and untracked, but its bwrap stays the daemon's child.
app_open() {
	local main
	main="$(systemctl --user show -p MainPID --value boscamor-input.service 2>/dev/null)"
	[ -n "$main" ] && [ "$main" != 0 ] || return 1
	ps --ppid "$main" -o stat=,comm= 2>/dev/null \
		| awk '$1 !~ /^Z/ && $2 !~ /^(wmctrl|xprop|xkill|notify-send)$/ { found = 1 } END { exit !found }'
}

keys() {
	echo
	local paused="" tries
	# The daemon reads the same buttons, and nothing grabs them: Home or Guide
	# would run Return to the launcher and close this terminal. Pause it for
	# the capture only, since --budgets needs it running. Under sudo,
	# systemctl --user would reach root's services, not the household user's.
	if [ -z "${SUDO_USER:-}" ] && systemctl --user is-active --quiet boscamor-input.service 2>/dev/null; then
		# Stopping the service ends its apps without telling the launcher, so
		# the TV stays black, and a flatpak app plays on untracked.
		if app_open; then
			echo "An app opened from the launcher is still open. Press Home on the remote to close it, then press Enter here."
			read -r _ || true
			# Home gives an app 3 s to close, then 3 s more after a kill.
			tries=8
			while [ "$tries" -gt 0 ] && app_open; do sleep 1; tries=$((tries - 1)); done
		fi
		if app_open; then
			echo "The app is still open, so the input service keeps running: Home and Guide still work during the capture."
			echo "For a clean capture, close the app and run tools/box-report.sh --keys again."
		else
			echo "Pausing the launcher's input service for the key capture; it starts again after."
			systemctl --user stop boscamor-input.service && paused=1
			trap 'systemctl --user start boscamor-input.service; exit 130' INT TERM HUP
		fi
	fi
	echo "Key capture. Press each button when asked; press Enter on a keyboard to skip one."
	python3 - "$OUT/keys.txt" <<'PY'
import glob, os, select, struct, sys, termios, time

EVENT = struct.Struct("llHHi")
NAMES = {1: "KEY_ESC", 14: "KEY_BACKSPACE", 28: "KEY_ENTER", 57: "KEY_SPACE", 102: "KEY_HOME",
         103: "KEY_UP", 105: "KEY_LEFT", 106: "KEY_RIGHT", 108: "KEY_DOWN", 113: "KEY_MUTE",
         114: "KEY_VOLUMEDOWN", 115: "KEY_VOLUMEUP", 116: "KEY_POWER", 125: "KEY_LEFTMETA",
         127: "KEY_COMPOSE", 139: "KEY_MENU", 142: "KEY_SLEEP", 158: "KEY_BACK", 164: "KEY_PLAYPAUSE",
         172: "KEY_HOMEPAGE", 217: "KEY_SEARCH", 240: "KEY_UNKNOWN", 248: "KEY_MICMUTE",
         272: "BTN_LEFT", 273: "BTN_RIGHT", 304: "BTN_SOUTH (A)", 305: "BTN_EAST (B)",
         307: "BTN_NORTH", 308: "BTN_WEST", 314: "BTN_SELECT", 315: "BTN_START", 316: "BTN_MODE (Guide)",
         352: "KEY_OK", 353: "KEY_SELECT", 582: "KEY_VOICECOMMAND"}
PROMPTS = [
    "Remote: Home", "Remote: Back", "Remote: Menu", "Remote: OK with the air mouse on", "Remote: Up", "Remote: Down",
    "Remote: Left", "Remote: Right", "Remote: Volume up", "Remote: Volume down", "Remote: Mute",
    "Remote: Voice or microphone (skip if none)", "Remote: any other button (skip if none)",
    "Remote: OK with the air mouse off (turn it off with the remote's mouse button first, and back on after)",
    "Pad: Guide (the logo button)", "Pad: A", "Pad: B", "Pad: Start", "Pad: Y",
    "Remote: Power. ONLY if the installer has run and you have rebooted, or the box may shut down. Otherwise skip",
]

names = {}
block = {}
try:
    for b in open("/proc/bus/input/devices").read().split("\n\n"):
        n = [l[9:].strip('"') for l in b.splitlines() if l.startswith("N: Name=")]
        h = [l for l in b.splitlines() if l.startswith("H: Handlers=")]
        for ev in (h[0].split() if h else []):
            if "event" in ev:
                names["/dev/input/" + ev.split("=")[-1]] = n[0] if n else "?"
except OSError:
    pass
fds = {}
denied = 0
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
    except OSError:
        denied += 1
if not fds:
    print("Can't read /dev/input (%d devices). Run the installer and log in again (input group),\n"
          "or rerun with: sudo BOX_REPORT_DIR=%s %s --keys" % (denied, os.path.dirname(sys.argv[1]), os.path.abspath(sys.argv[0]) if sys.argv[0] != "-" else "tools/box-report.sh"))
    sys.exit(1)

def drain(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select(list(fds), [], [], max(0, end - time.time()))
        for fd in r:
            try:
                os.read(fd, 4096)
            except OSError:
                pass

# The program came in on stdin (this heredoc), so the keyboard is /dev/tty.
tty = open("/dev/tty")
ENTER = (28, 96)        # KEY_ENTER, KEY_KPENTER

def flush_tty():
    # Drops a typed line nobody read, so one Enter never answers two prompts.
    try:
        termios.tcflush(tty.fileno(), termios.TCIFLUSH)
    except termios.error:
        pass

out = open(sys.argv[1], "w")
out.write("prompt | device | code | name | scancode\n")
for prompt in PROMPTS:
    drain(0.3)
    flush_tty()
    print("\n  " + prompt + " ... ", end="", flush=True)
    end = time.time() + 20
    got = None
    scan = None
    scan_only = []      # a button the kernel has no key for sends only its scancode
    while time.time() < end and not got:
        r, _, _ = select.select(list(fds) + [tty], [], [], 0.5)
        if tty in r:
            tty.readline()
            break
        for fd in r:
            try:
                data = os.read(fd, EVENT.size * 64)
            except OSError:
                continue
            pending = None
            for i in range(0, len(data) - len(data) % EVENT.size, EVENT.size):
                _, _, t, c, v = EVENT.unpack_from(data, i)
                if t == 4 and c == 4:
                    scan = v
                    pending = v
                elif t == 1:
                    pending = None
                    if v == 1 and not got:
                        got = (fds[fd], c)
                elif t == 0 and c == 0 and pending is not None:
                    scan_only.append("0x%x from %s" % (pending, names.get(fds[fd], fds[fd])))
                    pending = None
    if got and got[1] in ENTER and not prompt.startswith("Remote: OK"):
        # A keyboard's Enter reaches /dev/input before the terminal: when its
        # line follows, it was the skip, not the button.
        r, _, _ = select.select([tty], [], [], 0.3)
        if r:
            got = None
    flush_tty()
    if got:
        dev, code = got
        line = "%s | %s | %d | %s | %s" % (prompt.split(".")[0], names.get(dev, dev), code,
                                          NAMES.get(code, "?"), "0x%x" % scan if scan is not None else "-")
        print(NAMES.get(code, code), "from", names.get(dev, dev))
    else:
        line = "%s | skipped" % prompt.split(".")[0]
        print("skipped")
    if scan_only:
        # The kernel saw a button but has no key for it (a hwdb remap fixes that).
        line += " | no key, only scancode " + ", ".join(scan_only)
        print("  (no key, only scancode %s)" % ", ".join(scan_only))
    out.write(line + "\n")
    out.flush()

# Air mouse: how far the pointer drifts when the remote is only held.
for prompt in ["Hold the remote still in your hand, as if watching TV, for 5 s",
               "Press the D-pad a few times, the way you would to move along the tiles, for 5 s"]:
    print("\n  " + prompt + ". Press Enter on a keyboard to start.", end=" ", flush=True)
    flush_tty()
    tty.readline()
    drain(0.2)
    dx = dy = 0
    peak = 0
    end = time.time() + 5
    while time.time() < end:
        r, _, _ = select.select(list(fds), [], [], 0.2)
        for fd in r:
            try:
                data = os.read(fd, EVENT.size * 64)
            except OSError:
                continue
            for i in range(0, len(data) - len(data) % EVENT.size, EVENT.size):
                _, _, t, c, v = EVENT.unpack_from(data, i)
                if t == 2 and c == 0:
                    dx += v
                elif t == 2 and c == 1:
                    dy += v
                peak = max(peak, abs(dx), abs(dy))
    line = "air mouse | %s | net dx %d dy %d | furthest %d px" % (prompt.split(",")[0], dx, dy, peak)
    print("  " + line)
    out.write(line + "\n")
flush_tty()     # an Enter pressed while measuring must not answer --budgets
print("\nWritten to " + sys.argv[1])
PY
	if [ -n "$paused" ]; then
		trap - INT TERM HUP
		systemctl --user start boscamor-input.service
	fi
	[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$OUT"
}

# Budgets ------------------------------------------------------------------------------

# utime + stime of one thread. The name in (brackets) can hold spaces
# ("WorkerThread 0"), so the fields are counted from after its last ") ".
ticks() { awk '{ sub(/^.*\) /, ""); print $12 + $13 }' "$1/stat"; }

# CPU ticks (1/100 s) and voluntary wakeups per thread of one process over
# 10 s, and where each one waits (wchan; the syscall number would need root).
threads() {
	local pid="$1" t id c w
	declare -A c0 w0
	for t in /proc/"$pid"/task/*; do
		id="${t##*/}"
		c0[$id]=$(ticks "$t")
		w0[$id]=$(awk '/^voluntary_ctxt_switches/{print $2}' "$t/status")
	done
	sleep 10
	for t in /proc/"$pid"/task/*; do
		id="${t##*/}"
		[ -n "${c0[$id]:-}" ] || continue
		c=$(( $(ticks "$t") - c0[$id] ))
		w=$(( ($(awk '/^voluntary_ctxt_switches/{print $2}' "$t/status") - w0[$id]) / 10 ))
		[ "$c" -gt 0 ] || [ "$w" -gt 20 ] || continue
		printf "%-8s %-18s %5s ticks %6s/s  %s\n" "$id" "$(cat "$t/comm")" "$c" "$w" \
			"$(cat "$t/wchan" 2>/dev/null)"
	done
}

# Gives time to set up the TV after the Enter.
countdown() {
	echo "  Measuring starts in $1 s."
	sleep "$1"
}

# What the TV shows as a sample starts, so one taken with the wrong thing in
# front shows up in budgets.txt.
front() {
	local d="${DISPLAY:-:0}" active lw state
	if ! have xprop; then echo "in front: (no xprop)"; return; fi
	active="$(DISPLAY=$d xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $NF}')"
	echo "in front: $(DISPLAY=$d xprop -id "$active" WM_CLASS _NET_WM_NAME 2>/dev/null | cut -d= -f2- | tr '\n' ' ')"
	lw="$(DISPLAY=$d wmctrl -l 2>/dev/null | awk '{t=$4; for (i=5; i<=NF; i++) t=t" "$i} t=="Launcher" {print $1; exit}')"
	if [ -z "$lw" ]; then echo "launcher window: none"; return; fi
	if DISPLAY=$d xprop -id "$lw" _NET_WM_STATE 2>/dev/null | grep -q _NET_WM_STATE_HIDDEN; then state=minimised; else state=shown; fi
	echo "launcher window: $lw, $state"
}

budgets() {
	echo
	echo "Budgets (SPEC Resource use). Needs pidstat (sysstat) and the launcher and daemon running."
	local launcher daemon file="$OUT/budgets.txt"
	launcher="$(pgrep -f '^/opt/boscamor/boscamor' | head -1)"
	daemon="$(pgrep -f 'boscamor-input.py' | head -1)"
	if [ -z "$launcher" ] || [ -z "$daemon" ] || ! have pidstat; then
		echo "Need pidstat and both processes. launcher pid: ${launcher:-none}, daemon pid: ${daemon:-none}" | tee "$file"
		return
	fi
	# Enter goes to this terminal, but the TV must show the launcher or the app
	# while measuring, and an Enter on the launcher would open a tile. So each
	# step starts with Enter here, then a countdown to get the screen right.
	echo "  Each step starts when you press Enter here, then gives you time to set up the TV."
	echo "  On the box itself, come back to this terminal (Alt+Tab) for each next step."
	read -r -p "  1 of 3. Press Enter, then bring the launcher up on Home. On the box itself click it in the panel or use Alt+Tab (on the desktop the remote's Home closes this terminal). Hands off for 75 s. " _
	countdown 15
	{
		echo "===== Home, idle, shown"
		front
		pidstat -u -r -p "$launcher,$daemon" 5 12
	} | tee -a "$file"
	read -r -p "  2 of 3. Press Enter, then open an app from Home (YouTube is fine) and leave it. Hands off for 100 s. " _
	countdown 30
	{
		echo "===== Hidden behind an app"
		front
		pidstat -u -r -p "$launcher,$daemon" 5 12
		echo "===== RSS (kB)"
		ps -o pid,rss,comm -p "$launcher,$daemon"
	} | tee -a "$file"
	{
		echo "===== Launcher threads, 10 s (behind the app): CPU ticks, wakeups a second, where it waits"
		threads "$launcher"
	} | tee -a "$file"
	read -r -p "  3 of 3. Press Enter, then press Home on the remote to close the app, and leave the launcher on Home. Hands off for 25 s. " _
	countdown 15
	{
		echo "===== Launcher threads, 10 s (Home, idle)"
		front
		threads "$launcher"
	} | tee -a "$file"
	echo "  For the GPU, run this yourself while Home is idle and keep its output:"
	echo "    sudo timeout 15 intel_gpu_top -o - > $OUT/gpu-idle.txt"
}

for m in "${MODES[@]}"; do "$m"; done

tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUT.tar.gz"
echo
echo "Report: $OUT.tar.gz"
echo "Copy it back to the dev machine, for example: scp $REAL_USER@$(hostname):$OUT.tar.gz ."
