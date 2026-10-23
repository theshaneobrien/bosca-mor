#!/usr/bin/env bash
# Takes a fresh Linux Mint Cinnamon install to a working launcher box
# (SPEC "System setup and packaging"). Safe to re-run: every step checks
# first and only changes what differs, so a second run reports no changes.
#
#   install/install.sh                   run it (as the household user, in their desktop session)
#   install/install.sh --dry-run         print what it would do; changes nothing, no sudo
#   install/install.sh --no-apps         skip the Flathub apps, Spotify and the Music Assistant bundle
#   install/install.sh --long-press-poweroff   also let a long press of Power turn the box off
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
APT_PACKAGES=(wmctrl evtest flatpak x11-utils x11-xserver-utils pulseaudio-utils network-manager libnotify-bin python3 firefox sysstat intel-gpu-tools curl)

DRY=0
APPS=1
LONG_PRESS=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY=1 ;;
		--no-apps) APPS=0 ;;
		--long-press-poweroff) LONG_PRESS=1 ;;
		-h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
	esac
done

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
CHANGES=0
WARNINGS=()

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

as_root() { run sudo "$@"; }

# Installs a file from text only if the destination differs.
#   put_file <dest> <mode> <text> [root]
put_file() {
	local dest="$1" mode="$2" text="$3" root="${4:-}"
	if [ -f "$dest" ] && [ "$(cat "$dest")" = "$text" ]; then
		ok "$dest"
		return
	fi
	todo "write $dest"
	[ "$DRY" = 1 ] && return
	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "$text" > "$tmp"
	if [ -n "$root" ]; then
		sudo install -D -m "$mode" "$tmp" "$dest"
	else
		install -D -m "$mode" "$tmp" "$dest"
	fi
	rm -f "$tmp"
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

apt_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# 1. Packages and apps ---------------------------------------------------------------

packages() {
	step "1. Packages"
	local missing=()
	for p in "${APT_PACKAGES[@]}"; do
		if have dpkg-query && apt_installed "$p"; then ok "$p"; else missing+=("$p"); fi
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		todo "apt install ${missing[*]}"
		as_root apt-get update
		as_root apt-get install -y "${missing[@]}"
	fi
}

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
	step "1. Apps"
	if [ "$APPS" = 0 ]; then ok "skipped (--no-apps)"; return; fi
	if have flatpak && flatpak remotes --columns=name 2>/dev/null | grep -qx flathub; then
		ok "Flathub remote"
	else
		todo "add the Flathub remote"
		as_root flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	fi
	local id
	while read -r id; do
		if flatpak_has "$id"; then ok "$id"; else
			todo "flatpak install $id"
			as_root flatpak install -y --noninteractive flathub "$id"
		fi
	done < <(flathub_ids)

	if flatpak_has "$MA_ID"; then ok "$MA_ID (Music Assistant Companion)"; else
		todo "install $MA_ID from the latest GitHub release bundle"
		if [ "$DRY" = 0 ]; then
			local url tmp
			url="$(curl -fsSL "$MA_RELEASES" | python3 -c 'import json,sys; print(next((a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".flatpak")), ""))')"
			if [ -z "$url" ]; then
				warn "no .flatpak asset in the latest Music Assistant release; install $MA_ID by hand"
			else
				tmp="$(mktemp --suffix=.flatpak)"
				curl -fsSL -o "$tmp" "$url"
				sudo flatpak install -y --noninteractive --bundle "$tmp"
				rm -f "$tmp"
			fi
		fi
	fi

	if have spotify; then ok "spotify"; else
		todo "install Spotify from its apt repository"
		if [ "$DRY" = 0 ]; then
			curl -fsSL "$SPOTIFY_KEY_URL" | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
			echo "deb https://repository.spotify.com stable non-free" | sudo tee /etc/apt/sources.list.d/spotify.list >/dev/null
			sudo apt-get update
			sudo apt-get install -y spotify-client
		fi
	fi
}

# 2. The input group ---------------------------------------------------------------

input_group() {
	step "2. The input group (the daemon reads the remote)"
	if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx input; then
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
	if ! have gsettings || ! gsettings list-keys "$POWER_SCHEMA" 2>/dev/null | grep -qx button-power; then
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
	if ! have gsettings || ! gsettings list-keys org.cinnamon 2>/dev/null | grep -qx desktop-effects-minimize; then
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
	if have getent && getent group autologin >/dev/null; then
		if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx autologin; then ok "$USER_NAME is in autologin"; else
			todo "add $USER_NAME to autologin"
			as_root usermod -aG autologin "$USER_NAME"
		fi
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
		if [ -f "$DEST/boscamor" ] && cmp -s "$ROOT/build/boscamor" "$DEST/boscamor"; then ok "$DEST/boscamor"; else
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
		echo "          restarting the daemon so the new files take effect"
		if [ "$DRY" = 1 ]; then
			echo "          \$ systemctl --user restart boscamor-input.service"
		elif ! systemctl --user restart boscamor-input.service 2>/dev/null; then
			warn "could not start boscamor-input.service now; it starts at the next login"
		fi
	fi

	step "7. Launcher in the menu"
	put_file "$HOME_DIR/.local/share/applications/boscamor-launcher.desktop" 0644 "$(cat "$FILES/boscamor-launcher.desktop")"

	step "7. Return shortcut, in the menu and on the desktop"
	local shortcut
	shortcut="$(cat "$FILES/boscamor-return.desktop")"
	put_file "$HOME_DIR/.local/share/applications/boscamor-return.desktop" 0644 "$shortcut"
	local on_desktop
	on_desktop="$(desktop_dir)/boscamor-return.desktop"
	put_file "$on_desktop" 0755 "$shortcut"
	if have gio && [ -f "$on_desktop" ] && gio info -a metadata::trusted "$on_desktop" 2>/dev/null | grep -q "trusted: true"; then
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

# ----------------------------------------------------------------------------------------

main() {
	if [ "$(id -u)" = 0 ]; then
		echo "Run this as the household user, not root; it uses sudo for the system steps." >&2
		exit 1
	fi
	have python3 || { echo "python3 is needed (it ships with Mint)." >&2; exit 1; }
	echo "Installing the launcher for $USER_NAME$([ "$DRY" = 1 ] && echo ' (dry run: nothing changes)')"
	packages
	apps
	input_group
	logind
	cinnamon
	lightdm
	files
	echo
	for w in "${WARNINGS[@]}"; do echo "warning: $w"; done
	if [ "$CHANGES" = 0 ]; then
		echo "No changes: everything is already in place."
	elif [ "$DRY" = 1 ]; then
		echo "$CHANGES changes would be made. Run without --dry-run to make them."
	else
		echo "$CHANGES changes made. Reboot so the power key, input group and auto-login take effect."
	fi
}

main
