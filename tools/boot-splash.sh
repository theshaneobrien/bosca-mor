#!/usr/bin/env bash
# Replaces Mint's boot and shutdown splash (Plymouth) with one picture,
# centred on the launcher's background colour. It installs its own Plymouth
# theme rather than editing Mint's, so a Mint update can't undo it and
# --restore puts Mint's splash back. Run it on the box, as the household
# user; it asks for your password (sudo). The picture is never committed
# (D75): keep it on the box, for example in ~/.config/boscamor/splash.png.
#
#   tools/boot-splash.sh path/to/picture.png     install, or update the picture
#   tools/boot-splash.sh --restore               back to Mint's own splash
#   tools/boot-splash.sh --dry-run ...           show what it would do; changes nothing
#
# Use a PNG; a square one with transparent corners (a round photo) looks
# best. It is shown at up to 40% of the screen's height, never enlarged.
set -euo pipefail

THEME=boscamor-splash
# BOSCAMOR_ROOT prefixes the system paths for tests only (D53); unset on the box.
THEMES="${BOSCAMOR_ROOT:-}/usr/share/plymouth/themes"
DIR="$THEMES/$THEME"
LINK="$THEMES/default.plymouth"
# The default before ours, as "<auto|manual> <theme file>", for --restore.
SAVED="$DIR/previous-theme"
# Mint's own theme, for --restore when nothing was saved.
MINT="$THEMES/mint-logo/mint-logo.plymouth"
GRUB="${BOSCAMOR_ROOT:-}/etc/default/grub"
DRY=0
RESTORE=0
IMAGE=""
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY=1 ;;
		--restore) RESTORE=1 ;;
		-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
		*) IMAGE="$arg" ;;
	esac
done

CHANGED=0
say()  { printf '  %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf '  $ %s\n' "$*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# Writes a root-owned file only if it differs.
put() {
	local dest="$1" src="$2"
	if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
		say "ok      $dest"
		return
	fi
	say "write   $dest"
	CHANGED=1
	run sudo install -D -m 0644 "$src" "$dest"
}

query() {
	update-alternatives --query default.plymouth 2>/dev/null | sed -n "s/^$1: //p"
}
current_theme() { query Value; }
is_theme() { update-alternatives --list default.plymouth 2>/dev/null | grep -qxF "$1"; }

rebuild() {
	if [ "$CHANGED" = 0 ]; then
		echo "No changes."
		return
	fi
	echo "Rebuilding the boot image (update-initramfs); this takes a minute."
	run sudo update-initramfs -u
	echo "Done. Reboot to see it."
}

if [ "$(id -u)" = 0 ]; then
	echo "Run this as yourself, not root; it uses sudo where it needs to." >&2
	exit 1
fi
if ! have update-alternatives || ! [ -d "$THEMES" ]; then
	echo "No Plymouth here ($THEMES is missing)." >&2
	exit 1
fi

# Back to Mint ---------------------------------------------------------------------

if [ "$RESTORE" = 1 ]; then
	echo "Restoring Mint's boot splash$([ "$DRY" = 1 ] && echo ' (dry run)')"
	saved_mode="" saved=""
	if [ -r "$SAVED" ]; then read -r saved_mode saved < "$SAVED" || true; fi
	was_default=0
	[ "$(current_theme)" = "$DIR/$THEME.plymouth" ] && was_default=1
	if is_theme "$DIR/$THEME.plymouth"; then
		say "remove  $THEME from the Plymouth themes"
		CHANGED=1
		run sudo update-alternatives --remove default.plymouth "$DIR/$THEME.plymouth"
	else
		say "ok      $THEME is not installed"
	fi
	# Removing ours picks the highest priority theme left, which need not be
	# the one chosen before: choose that one again.
	if [ "$saved_mode" = manual ] && [ -n "$saved" ] \
		&& { [ "$saved" != "$(current_theme)" ] || [ "$(query Status)" != manual ]; }; then
		if is_theme "$saved"; then
			say "set     $saved as the default again"
			CHANGED=1
			run sudo update-alternatives --set default.plymouth "$saved"
		else
			say "warn    $saved, the default before, is gone; the highest priority theme is used"
		fi
	elif [ -z "$saved_mode" ] && [ "$was_default" = 1 ]; then
		# Ours was the default but nothing says what came before: an older
		# version of this script kept no record. Choose Mint's own theme, not
		# whatever ranks highest (bgrt outranks it on Ubuntu bases).
		if ! is_theme "$MINT"; then
			say "warn    no Mint theme ($MINT); the highest priority theme is used"
		elif [ "$(current_theme)" != "$MINT" ]; then
			say "set     $MINT as the default"
			CHANGED=1
			run sudo update-alternatives --set default.plymouth "$MINT"
		fi
	fi
	if [ -d "$DIR" ]; then
		say "delete  $DIR"
		CHANGED=1
		run sudo rm -r -- "$DIR"
	fi
	say "default theme: $(current_theme)"
	rebuild
	exit 0
fi

# Install ---------------------------------------------------------------------------

if [ -z "$IMAGE" ]; then
	echo "Give the picture: tools/boot-splash.sh path/to/picture.png (or --restore)." >&2
	exit 2
fi
if ! [ -r "$IMAGE" ] || [ "$(head -c 8 "$IMAGE" | od -An -tx1 | tr -d ' \n')" != "89504e470d0a1a0a" ]; then
	echo "$IMAGE is not a readable PNG." >&2
	exit 2
fi

echo "Installing the boot splash from $IMAGE$([ "$DRY" = 1 ] && echo ' (dry run)')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/$THEME.plymouth" <<EOF
[Plymouth Theme]
Name=Launcher boot splash
Description=One picture, centred, while the box starts and shuts down
ModuleName=script

[script]
ImageDir=$DIR
ScriptFile=$DIR/$THEME.script
EOF

# Plymouth's own script language. #0c0c14 is the launcher's background (BG).
cat > "$TMP/$THEME.script" <<'EOF'
# Written by tools/boot-splash.sh.
Window.SetBackgroundTopColor(0.047, 0.047, 0.078);
Window.SetBackgroundBottomColor(0.047, 0.047, 0.078);

picture = Image("splash.png");
size = Math.Min(Window.GetHeight() * 0.4, picture.GetHeight());
shown = picture.Scale(size * picture.GetWidth() / picture.GetHeight(), size);
splash = Sprite(shown);
splash.SetX(Window.GetX() + (Window.GetWidth() - shown.GetWidth()) / 2);
splash.SetY(Window.GetY() + (Window.GetHeight() - shown.GetHeight()) / 2);
splash.SetZ(10);

# A disk password prompt, if the box ever has one: the prompt and a dot per
# character, under the picture.
fun show_password(prompt, bullets) {
	text = prompt + "  ";
	i = 0;
	while (i < bullets) {
		text = text + "*";
		i = i + 1;
	}
	global.password = Sprite(Image.Text(text, 0.95, 0.95, 0.97));
	global.password.SetX(Window.GetX() + (Window.GetWidth() - global.password.GetImage().GetWidth()) / 2);
	global.password.SetY(Window.GetY() + Window.GetHeight() * 0.8);
	global.password.SetZ(20);
}
Plymouth.SetDisplayPasswordFunction(show_password);

fun show_normal() {
	if (global.password)
		global.password.SetOpacity(0);
}
Plymouth.SetDisplayNormalFunction(show_normal);
EOF

put "$DIR/splash.png" "$IMAGE"
put "$DIR/$THEME.plymouth" "$TMP/$THEME.plymouth"
put "$DIR/$THEME.script" "$TMP/$THEME.script"

# Read before --install: in auto mode, installing ours can make it the default.
BEFORE="$(current_theme)" || BEFORE=""
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$DIR/$THEME.plymouth" ]; then
	printf '%s %s\n' "$(query Status)" "$BEFORE" > "$TMP/previous-theme"
	put "$SAVED" "$TMP/previous-theme"
fi

if is_theme "$DIR/$THEME.plymouth"; then
	say "ok      $THEME is a Plymouth theme"
else
	say "add     $THEME to the Plymouth themes"
	CHANGED=1
	run sudo update-alternatives --install "$LINK" default.plymouth "$DIR/$THEME.plymouth" 100
fi
if [ "$(current_theme)" = "$DIR/$THEME.plymouth" ]; then
	say "ok      $THEME is the default"
else
	say "set     $THEME as the default (was $(current_theme))"
	CHANGED=1
	run sudo update-alternatives --set default.plymouth "$DIR/$THEME.plymouth"
fi

if [ -r "$GRUB" ] && ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*splash' "$GRUB"; then
	say "warn    /etc/default/grub has no \"splash\" on GRUB_CMDLINE_LINUX_DEFAULT, so no splash shows at all."
	say "        Add it (Mint's default is \"quiet splash\"), then run: sudo update-grub"
fi

rebuild
