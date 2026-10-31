#!/usr/bin/env bash
# Takes a fresh Linux Mint Cinnamon install to a working launcher box
# (SPEC "System setup and packaging"). Safe to re-run: every step checks
# first and only changes what differs, so a second run reports no changes.
#
#   install/install.sh                   run it (as the household user, in their desktop session)
#   install/install.sh --dry-run         print what it would do; changes nothing, no sudo
#   install/install.sh --no-apps         skip the Flathub apps, Spotify and the Music Assistant bundle
#   install/install.sh --long-press-poweroff   also let a long press of Power turn the box off
#   install/install.sh --update          what the launcher's own updates run (D103): no sudo and
#                                        no apps; system changes are listed, not made, and the
#                                        exit code is 3 when there are any (0 when none)
#
# It asks for your password (sudo) for the system steps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES="$ROOT/install/files"
# BOSCAMOR_ROOT prefixes the system paths (/etc, /opt) so tests can run the
# installer into a scratch folder. Leave it unset on the box.
SYS="${BOSCAMOR_ROOT:-}"
DEST="$SYS/opt/boscamor"
SPOTIFY_KEY_URL="https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg"
MA_RELEASES="https://api.github.com/repos/music-assistant/desktop-app/releases/latest"
MA_ID="io.music_assistant.Companion"
APT_PACKAGES=(wmctrl evtest flatpak x11-utils x11-xserver-utils pulseaudio-utils network-manager libnotify-bin python3 firefox sysstat intel-gpu-tools curl x11vnc)

DRY=0
APPS=1
LONG_PRESS=0
UPDATE=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY=1 ;;
		--no-apps) APPS=0 ;;
		--long-press-poweroff) LONG_PRESS=1 ;;
		--update) UPDATE=1; APPS=0 ;;
		-h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
	esac
done

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
CHANGES=0
WARNINGS=()
NEEDS_SUDO=0

# Output and acting ---------------------------------------------------------------

ok()   { printf '  ok      %s\n' "$*"; }
todo() { printf '  %-7s %s\n' "$([ "$DRY" = 1 ] && echo would || echo change)" "$*"; CHANGES=$((CHANGES + 1)); }
warn() { printf '  warn    %s\n' "$*"; WARNINGS+=("$*"); }
step() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Runs a command, or only shows it under --dry-run. Never through a string.
run() {
	if [ "$DRY" = 1 ]; then
		printf '          $ %s\n' "$*"
	else
		"$@"
	fi
}

# An update runs from the daemon with nobody to type a password: it lists
# what needs sudo instead, for the next time someone runs this by hand.
as_root() {
	if [ "$UPDATE" = 1 ]; then
		printf '          needs sudo: %s\n' "$*"
		NEEDS_SUDO=$((NEEDS_SUDO + 1))
		return 0
	fi
	run sudo "$@"
}

# A file with the right content can still have the wrong mode, for example
# 0777 after tools/deploy.sh copied it from a Windows drive.
#   fix_mode <dest> <mode> [root]
fix_mode() {
	local dest="$1" mode="$2" root="${3:-}" have_mode
	have_mode="$(stat -c %a "$dest")"
	if [ "$have_mode" = "${mode#0}" ]; then
		ok "$dest"
		return
	fi
	todo "chmod $mode $dest (was $have_mode)"
	if [ -n "$root" ]; then as_root chmod "$mode" "$dest"; else run chmod "$mode" "$dest"; fi
}

# Installs a file from text only if the destination differs.
#   put_file <dest> <mode> <text> [root]
put_file() {
	local dest="$1" mode="$2" text="$3" root="${4:-}"
	if [ -f "$dest" ] && [ "$(cat "$dest")" = "$text" ]; then
		fix_mode "$dest" "$mode" "$root"
		return
	fi
	todo "write $dest"
	[ "$DRY" = 1 ] && return
	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "$text" > "$tmp"
	if [ -n "$root" ]; then
		as_root install -D -m "$mode" "$tmp" "$dest"
	else
		install -D -m "$mode" "$tmp" "$dest"
	fi
	rm -f "$tmp"
}

# Copies a file (binary safe) only when it differs.
put_copy() {
	local src="$1" dest="$2" mode="$3"
	if [ ! -f "$src" ]; then
		warn "$src is missing, so $dest was not written"
		return
	fi
	if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
		fix_mode "$dest" "$mode"
		return
	fi
	todo "write $dest"
	run install -D -m "$mode" "$src" "$dest"
}

# Writes a file only when it is missing: the user may have changed it since.
seed_file() {
	local dest="$1" mode="$2" src="$3"
	if [ -e "$dest" ]; then
		ok "$dest (kept as it is)"
		return
	fi
	todo "create $dest"
	run install -D -m "$mode" "$src" "$dest"
}

make_dir() {
	if [ -d "$1" ]; then
		ok "$1/"
	else
		todo "create $1/"
		run mkdir -p "$1"
	fi
}

apt_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep "install ok installed" >/dev/null; }

# The launcher export is one ELF file; a failed download is an error page.
is_elf() { [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }

# 1. Packages ----------------------------------------------------------------------

packages() {
	step "1. Packages"
	local missing=()
	for p in "${APT_PACKAGES[@]}"; do
		if have dpkg-query && apt_installed "$p"; then ok "$p"; else missing+=("$p"); fi
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		todo "apt install ${missing[*]}"
		# A broken third-party repository fails the update; the steps after
		# this one (power key, auto-login, daemon) must still run.
		as_root apt-get update \
			|| warn "apt update failed (a third-party repository?); installing from the package lists already here"
		as_root apt-get install -y "${missing[@]}" || warn "could not install ${missing[*]}"
	fi
}

# 2. The input group ---------------------------------------------------------------

input_group() {
	step "2. The input group (the daemon reads the remote)"
	if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -x input >/dev/null; then
		ok "$USER_NAME is in input"
	else
		todo "add $USER_NAME to input (takes effect at the next login)"
		as_root usermod -aG input "$USER_NAME"
	fi
}

# 3. logind: Power opens the confirm, never shuts down at once -----------------------

logind() {
	step "3. Power key (systemd-logind)"
	local text
	text="$(cat "$FILES/logind-boscamor.conf")"
	if [ "$LONG_PRESS" = 1 ]; then
		text="$text"$'\n'"HandlePowerKeyLongPress=poweroff"
	fi
	put_file "$SYS/etc/systemd/logind.conf.d/boscamor.conf" 0644 "$text" root
}

# 4 and 5. Cinnamon: power button and media keys ----------------------------------------

POWER_SCHEMA=org.cinnamon.settings-daemon.plugins.power
MEDIA_SCHEMAS=(org.cinnamon.desktop.keybindings.media-keys org.cinnamon.desktop.keybindings.wm)

cinnamon() {
	step "4. Cinnamon's power button action"
	if ! have gsettings || ! gsettings list-keys "$POWER_SCHEMA" 2>/dev/null | grep -x button-power >/dev/null; then
		warn "no $POWER_SCHEMA button-power here; find the key with: gsettings list-recursively | grep -i power"
	else
		local cur
		cur="$(gsettings get "$POWER_SCHEMA" button-power)"
		if [ "$cur" = "'nothing'" ]; then ok "button-power is nothing"; else
			todo "button-power $cur -> nothing"
			run gsettings set "$POWER_SCHEMA" button-power nothing
		fi
	fi

	step "4. Cinnamon's minimise animation (Desktop hides the launcher at once, D71)"
	if ! have gsettings || ! gsettings list-keys org.cinnamon 2>/dev/null | grep -x desktop-effects-minimize >/dev/null; then
		warn "no org.cinnamon desktop-effects-minimize here; turn the minimise effect off in Effects by hand"
	else
		local effect
		effect="$(gsettings get org.cinnamon desktop-effects-minimize)"
		if [ "$effect" = "'none'" ]; then ok "minimise effect is none"; else
			todo "minimise effect $effect -> none"
			run gsettings set org.cinnamon desktop-effects-minimize none
		fi
	fi

	step "5. Cinnamon key bindings on Home, Back, Menu, Super+Home or Power"
	if ! have gsettings; then warn "no gsettings: check the media keys by hand"; return; fi
	local schema key value cleared found=0 schemas=0
	for schema in "${MEDIA_SCHEMAS[@]}"; do
		gsettings list-keys "$schema" >/dev/null 2>&1 || continue
		schemas=$((schemas + 1))
		while read -r key; do
			value="$(gsettings get "$schema" "$key" 2>/dev/null)" || continue
			cleared="$(clear_accels "$value")"
			[ "$cleared" = "$value" ] && continue
			found=1
			todo "$schema $key: $value -> $cleared"
			run gsettings set "$schema" "$key" "$cleared"
		done < <(gsettings list-keys "$schema")
	done
	if [ "$schemas" = 0 ]; then
		warn "no Cinnamon key binding schemas here: check the media keys by hand"
	elif [ "$found" = 0 ]; then
		ok "nothing bound to them"
	fi
}

# Drops HomePage, Back, Menu, Super+Home and the power key (Cinnamon binds
# XF86PowerOff to its own shutdown dialog) from a gsettings accelerator list.
clear_accels() {
	python3 - "$1" <<'PY'
import ast, re, sys
raw = sys.argv[1].strip()
if raw.startswith("@as "):
    raw = raw[4:]
try:
    accels = ast.literal_eval(raw)
except (ValueError, SyntaxError):
    print(sys.argv[1]); sys.exit()
if not isinstance(accels, list):
    print(sys.argv[1]); sys.exit()
taken = re.compile(r"^(XF86HomePage|XF86Back|XF86PowerOff|Menu|<(Super|Mod4)>Home)$", re.I)
kept = [a for a in accels if not taken.match(a)]
if kept == accels:
    print(sys.argv[1])
else:
    print("@as []" if not kept else "[" + ", ".join("'%s'" % a for a in kept) + "]")
PY
}

# 6. LightDM: log straight in, X11 Cinnamon ---------------------------------------------

lightdm() {
	step "6. Auto-login to the X11 Cinnamon session"
	if [ ! -f /usr/share/xsessions/cinnamon.desktop ]; then
		warn "no /usr/share/xsessions/cinnamon.desktop: is this Mint Cinnamon?"
	fi
	put_file "$SYS/etc/lightdm/lightdm.conf.d/90-boscamor.conf" 0644 \
		"$(sed "s/@USER@/$USER_NAME/" "$FILES/lightdm-boscamor.conf")" root
	lightdm_overrides
	if have getent && getent group autologin >/dev/null; then
		if id -nG "$USER_NAME" | tr ' ' '\n' | grep -x autologin >/dev/null; then ok "$USER_NAME is in autologin"; else
			todo "add $USER_NAME to autologin"
			as_root usermod -aG autologin "$USER_NAME"
		fi
	fi
}

# LightDM reads lightdm.conf after lightdm.conf.d, so a key set there wins
# over 90-boscamor.conf. Mint's Login Window tool writes autologin-user there.
lightdm_overrides() {
	local conf="$SYS/etc/lightdm/lightdm.conf" found line
	[ -f "$conf" ] || return 0
	found="$(python3 - "$conf" "$USER_NAME" <<'PY'
import sys
want = {"autologin-user": sys.argv[2], "autologin-session": "cinnamon", "user-session": "cinnamon"}
section = ""
for raw in open(sys.argv[1], errors="replace"):
    line = raw.strip()
    if not line or line[0] in "#;":
        continue
    if line.startswith("["):
        section = line.strip("[]").strip()
        continue
    if section not in ("Seat:*", "Seat:seat0", "SeatDefaults"):
        continue
    key, eq, value = line.partition("=")
    key, value = key.strip(), value.strip()
    if eq and key in want and value != want[key]:
        print("%s=%s, not %s" % (key, value, want[key]))
PY
)" || return 0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		warn "$conf sets $line, and it wins over 90-boscamor.conf: remove that line or fix its value"
	done <<< "$found"
}

# 6. v0.14.4's X start mode, taken out again (D106) -----------------------------------------

x_start_mode_gone() {
	step "6. No X start mode file (v0.14.4's left the TV with no signal, D106)"
	local conf="$SYS/etc/X11/xorg.conf.d/90-boscamor.conf"
	if [ -e "$conf" ]; then
		todo "remove $conf (takes effect at the next restart)"
		as_root rm -f "$conf"
	else
		ok "none"
	fi
}

# 7. The launcher's own files ------------------------------------------------------------

desktop_dir() {
	if have xdg-user-dir; then xdg-user-dir DESKTOP; else echo "$HOME_DIR/Desktop"; fi
}

files() {
	step "7. Launcher and daemon in $DEST"
	if [ -d "$DEST" ] && [ -w "$DEST" ]; then ok "$DEST/ (yours to deploy into)"; else
		todo "create $DEST/ owned by $USER_NAME, for tools/deploy.sh"
		as_root install -d -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$DEST"
	fi
	local daemon_before=$CHANGES
	put_file "$DEST/boscamor-input.py" 0755 "$(cat "$ROOT/daemon/boscamor-input.py")"
	if [ -f "$ROOT/build/boscamor" ]; then
		if ! is_elf "$ROOT/build/boscamor"; then
			warn "$ROOT/build/boscamor is not a Linux build (a failed download?), so it was not installed; download it again with curl -fL"
		elif [ -f "$DEST/boscamor" ] && cmp -s "$ROOT/build/boscamor" "$DEST/boscamor"; then
			fix_mode "$DEST/boscamor" 0755
		else
			todo "copy the launcher export to $DEST/boscamor"
			run install -m 0755 "$ROOT/build/boscamor" "$DEST/boscamor"
		fi
	elif [ -x "$DEST/boscamor" ]; then
		ok "$DEST/boscamor"
	else
		warn "no launcher at $DEST/boscamor: export it from Godot to build/boscamor and run this again, or deploy it with tools/deploy.sh"
	fi

	step "7. Your settings, autostart and the daemon service"
	make_dir "$HOME_DIR/.config/boscamor/icons"
	make_dir "$HOME_DIR/.local/state/boscamor"
	seed_file "$HOME_DIR/.config/boscamor/apps.json" 0644 "$FILES/apps.default.json"
	seed_file "$HOME_DIR/.config/autostart/boscamor.desktop" 0644 "$FILES/boscamor.desktop"

	local unit="$HOME_DIR/.config/systemd/user/boscamor-input.service"
	local before=$CHANGES
	put_file "$unit" 0644 "$(cat "$FILES/boscamor-input.service")"
	if [ "$CHANGES" != "$before" ]; then run systemctl --user daemon-reload; fi
	# Cinnamon never starts graphical-session.target, so the session's own
	# autostart starts the daemon (D67).
	put_file "$HOME_DIR/.config/autostart/boscamor-input.desktop" 0644 "$(cat "$FILES/boscamor-input.desktop")"
	if [ "$CHANGES" != "$daemon_before" ]; then
		if [ "$UPDATE" = 1 ]; then
			# The daemon runs this update, so a restart now would end this script
			# with it; it restarts itself once this is done.
			echo "          the daemon restarts itself after the update"
		else
			echo "          restarting the daemon so the new files take effect"
			if [ "$DRY" = 1 ]; then
				echo "          \$ systemctl --user restart boscamor-input.service"
			elif ! systemctl --user restart boscamor-input.service 2>/dev/null; then
				warn "could not start boscamor-input.service now; it starts at the next login"
			fi
		fi
	fi

	step "7. Launcher in the menu, with its icon"
	local px icons="$HOME_DIR/.local/share/icons/hicolor"
	for px in 16 24 32 48 64 128 256; do
		put_copy "$ROOT/launcher/assets/icon/launcher-$px.png" "$icons/${px}x${px}/apps/boscamor-launcher.png" 0644
	done
	put_copy "$ROOT/launcher/assets/icon/launcher.svg" "$icons/scalable/apps/boscamor-launcher.svg" 0644
	put_file "$HOME_DIR/.local/share/applications/boscamor-launcher.desktop" 0644 "$(cat "$FILES/boscamor-launcher.desktop")"

	step "7. Return shortcut, in the menu and on the desktop"
	local shortcut
	shortcut="$(cat "$FILES/boscamor-return.desktop")"
	put_file "$HOME_DIR/.local/share/applications/boscamor-return.desktop" 0644 "$shortcut"
	local on_desktop
	on_desktop="$(desktop_dir)/boscamor-return.desktop"
	put_file "$on_desktop" 0755 "$shortcut"
	if have gio && [ -f "$on_desktop" ] && gio info -a metadata::trusted "$on_desktop" 2>/dev/null | grep "trusted: true" >/dev/null; then
		ok "desktop shortcut trusted"
	else
		todo "mark the desktop shortcut trusted, so it runs on a click"
		run gio set "$on_desktop" metadata::trusted true
	fi

	step "7. Firefox kiosk profiles with DRM on"
	local profile
	while read -r profile; do
		make_dir "$profile"
		put_file "$profile/user.js" 0644 "$(cat "$FILES/user.js")"
	done < <(kiosk_profiles)
}

# --profile paths in the default config, /home/USER expanded.
kiosk_profiles() {
	python3 - "$FILES/apps.default.json" "$HOME_DIR" <<'PY'
import json, sys
for app in json.load(open(sys.argv[1])):
    argv = app.get("argv", [])
    if "--profile" in argv:
        i = argv.index("--profile")
        if i + 1 < len(argv):
            print(argv[i + 1].replace("/home/USER", sys.argv[2]))
PY
}

# 7. Remote help over Tailscale (D102) ----------------------------------------------------
# SSH through Tailscale's own server, so nothing listens on the house's network,
# and share-screen to show the TV's screen to a VNC viewer only while asked.
# Tailscale itself is installed and logged in by hand (it needs a browser).

remote_help() {
	step "7. Remote help over Tailscale (SSH and the TV's screen)"
	put_file "$DEST/share-screen" 0755 "$(cat "$FILES/share-screen")"
	if ! have tailscale; then
		warn "Tailscale isn't installed, so remote help can't reach this box: install it (tailscale.com/download), log in, then run this again"
		return
	fi
	if ! tailscale ip -4 >/dev/null 2>&1; then
		warn "Tailscale isn't up (try: sudo tailscale up), so SSH over it isn't on yet; run this again after"
		return
	fi
	if tailscale debug prefs 2>/dev/null | grep '"RunSSH": true' >/dev/null; then
		ok "Tailscale SSH is on"
	else
		todo "turn on Tailscale SSH"
		as_root tailscale set --ssh || warn "could not turn on Tailscale SSH"
	fi
}

# 8. Apps --------------------------------------------------------------------------------
# Last, and each step warns and moves on when it fails: a download or a third-party
# repository that is down must never stop the power key, auto-login and daemon steps.

# Flathub ids from the default config: "flatpak run <id>", minus the bundle.
flathub_ids() {
	python3 - "$FILES/apps.default.json" "$MA_ID" <<'PY'
import json, sys
for app in json.load(open(sys.argv[1])):
    argv = app.get("argv", [])
    if argv[:2] == ["flatpak", "run"]:
        ids = [a for a in argv[2:] if not a.startswith("-")]
        if ids and ids[0] != sys.argv[2]:
            print(ids[0])
PY
}

flatpak_has() { have flatpak && flatpak info "$1" >/dev/null 2>&1; }

apps() {
	step "8. Apps"
	if [ "$APPS" = 0 ]; then ok "skipped (--no-apps)"; return; fi
	if have flatpak && flatpak remotes --columns=name 2>/dev/null | grep -x flathub >/dev/null; then
		ok "Flathub remote"
	else
		todo "add the Flathub remote"
		as_root flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
			|| warn "could not add the Flathub remote"
	fi
	local id
	while read -r id; do
		if flatpak_has "$id"; then ok "$id"; else
			todo "flatpak install $id"
			as_root flatpak install -y --noninteractive flathub "$id" || warn "could not install $id from Flathub"
		fi
	done < <(flathub_ids)
	music_assistant
	spotify_app
}

music_assistant() {
	if flatpak_has "$MA_ID"; then ok "$MA_ID (Music Assistant Companion)"; return; fi
	todo "install $MA_ID from the latest GitHub release bundle"
	[ "$DRY" = 1 ] && return
	local url="" tmp
	if ! url="$(curl -fsSL "$MA_RELEASES" | python3 -c 'import json,sys; print(next((a["browser_download_url"] for a in json.load(sys.stdin).get("assets", []) if a["name"].endswith(".flatpak")), ""))' 2>/dev/null)"; then
		warn "could not read the latest Music Assistant release; install $MA_ID by hand"
	elif [ -z "$url" ]; then
		warn "no .flatpak asset in the latest Music Assistant release; install $MA_ID by hand"
	else
		tmp="$(mktemp --suffix=.flatpak)"
		if ! { curl -fsSL -o "$tmp" "$url" && sudo flatpak install -y --noninteractive --bundle "$tmp"; }; then
			warn "could not install $MA_ID from $url"
		fi
		rm -f "$tmp"
	fi
}

# Spotify's key signs only Spotify's repository (signed-by), not every
# repository as a key in trusted.gpg.d would. The files take the $SYS prefix
# like every other system path (D53); the signed-by path is the one apt reads.
SPOTIFY_KEYRING=/etc/apt/keyrings/spotify.gpg
SPOTIFY_OLD_KEY=/etc/apt/trusted.gpg.d/spotify.gpg
SPOTIFY_LIST=/etc/apt/sources.list.d/spotify.list
SPOTIFY_SOURCE="deb [signed-by=$SPOTIFY_KEYRING] https://repository.spotify.com stable non-free"

spotify_app() {
	if [ -f "$SYS$SPOTIFY_OLD_KEY" ]; then
		# An earlier installer put the key in trusted.gpg.d. Keyring first, then
		# the source that names it, then the old key, so apt always has a key.
		todo "trust Spotify's key for Spotify's repository only ($SPOTIFY_KEYRING)"
		as_root install -D -m 0644 "$SYS$SPOTIFY_OLD_KEY" "$SYS$SPOTIFY_KEYRING"
		put_file "$SYS$SPOTIFY_LIST" 0644 "$SPOTIFY_SOURCE" root
		as_root rm -f "$SYS$SPOTIFY_OLD_KEY"
	fi
	if have spotify; then ok "spotify"; return; fi
	todo "install Spotify from its apt repository"
	[ "$DRY" = 1 ] && return
	if [ ! -f "$SYS$SPOTIFY_KEYRING" ] && ! spotify_key; then
		warn "could not fetch Spotify's key from $SPOTIFY_KEY_URL; install Spotify by hand"
		return
	fi
	put_file "$SYS$SPOTIFY_LIST" 0644 "$SPOTIFY_SOURCE" root
	if ! sudo apt-get update; then
		# Left in place, a rejected source makes every later apt update fail.
		sudo rm -f "$SYS$SPOTIFY_LIST" "$SYS$SPOTIFY_KEYRING"
		warn "apt update failed with Spotify's repository added, so it was taken out again; if apt rejected Spotify's key, update SPOTIFY_KEY_URL from Spotify's Linux download page"
	elif ! sudo apt-get install -y spotify-client; then
		warn "could not install spotify-client"
	fi
}

# Fetches Spotify's key, dearmors it as the household user, then installs it.
spotify_key() {
	local asc bin rc=0
	asc="$(mktemp)"
	bin="$(mktemp)"
	curl -fsSL -o "$asc" "$SPOTIFY_KEY_URL" \
		&& gpg --batch --yes --dearmor -o "$bin" "$asc" \
		&& sudo install -D -m 0644 "$bin" "$SYS$SPOTIFY_KEYRING" || rc=1
	rm -f "$asc" "$bin"
	return "$rc"
}

# ----------------------------------------------------------------------------------------

main() {
	if [ "$(id -u)" = 0 ]; then
		echo "Run this as the household user, not root; it uses sudo for the system steps." >&2
		exit 1
	fi
	have python3 || { echo "python3 is needed (it ships with Mint)." >&2; exit 1; }
	echo "Installing the launcher for $USER_NAME$([ "$DRY" = 1 ] && echo ' (dry run: nothing changes)')$([ "$UPDATE" = 1 ] && echo ' (update: no sudo, no apps)')"
	packages
	input_group
	logind
	cinnamon
	lightdm
	x_start_mode_gone
	files
	remote_help
	apps
	echo
	for w in "${WARNINGS[@]}"; do echo "warning: $w"; done
	if [ "$UPDATE" = 1 ]; then
		echo "$((CHANGES - NEEDS_SUDO)) changes made."
		if [ "$NEEDS_SUDO" -gt 0 ]; then
			echo "$NEEDS_SUDO system changes need sudo: run install/install.sh on the box by hand."
			exit 3
		fi
	elif [ "$CHANGES" = 0 ]; then
		echo "No changes: everything is already in place."
	elif [ "$DRY" = 1 ]; then
		echo "$CHANGES changes would be made. Run without --dry-run to make them."
	else
		echo "$CHANGES changes made. Reboot so the power key, input group and auto-login take effect."
	fi
}

main
