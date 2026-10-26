#!/usr/bin/env bash
# Sets up a Linux dev machine (or a dev container) for this repo without root:
# the Godot 4.7.2 editor (official Linux build, checked against Godot's
# published SHA-512), and SCons in a venv when the system has none. Both go in
# build/ (gitignored), with build/bin to put on PATH:
#
#   tools/linux-dev-setup.sh
#   export PATH="$PWD/build/bin:$PATH"
#
# Then `godot` runs the editor (tests, exports) and `scons` builds the patched
# export template (tools/build-godot-template.sh). Run it again any time; it
# skips what is already there.
set -euo pipefail

VERSION="4.7.2-stable"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/bin"
GODOT_DIR="$ROOT/build/godot"
ZIP="Godot_v${VERSION}_linux.x86_64.zip"
EXE="Godot_v${VERSION}_linux.x86_64"
URL="https://github.com/godotengine/godot/releases/download/${VERSION}"
mkdir -p "$BIN" "$GODOT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)"; MISSING=1; }; }
MISSING=0
need curl "to download Godot"
need python3 "for the venv and unzipping"
need git "to fetch Godot's source for the template"
need g++ "to build the template (build-essential)"
need pkg-config "Godot's build stops without it; Debian package pkgconf"

echo "Godot editor"
if [ -x "$GODOT_DIR/$EXE" ]; then
	echo "  ok      $GODOT_DIR/$EXE"
else
	curl -fsSL -o "$GODOT_DIR/$ZIP" "$URL/$ZIP"
	curl -fsSL -o "$GODOT_DIR/SHA512-SUMS.txt" "$URL/SHA512-SUMS.txt"
	want="$(awk -v f="$ZIP" '$2 == f {print $1}' "$GODOT_DIR/SHA512-SUMS.txt")"
	got="$(sha512sum "$GODOT_DIR/$ZIP" | cut -d' ' -f1)"
	if [ -z "$want" ] || [ "$want" != "$got" ]; then
		echo "  the download does not match Godot's SHA-512; not using it" >&2
		rm -f "$GODOT_DIR/$ZIP"
		exit 1
	fi
	python3 -m zipfile -e "$GODOT_DIR/$ZIP" "$GODOT_DIR"
	chmod +x "$GODOT_DIR/$EXE"
	rm -f "$GODOT_DIR/$ZIP"
	echo "  added   $GODOT_DIR/$EXE (SHA-512 checked)"
fi
ln -sf "$GODOT_DIR/$EXE" "$BIN/godot"

echo "SCons (4.4 or newer)"
scons_ok() { "$1" --version 2>/dev/null | grep -Eo 'SCons: v[0-9]+\.[0-9]+' | awk -F'[v.]' '{exit !($2 > 4 || ($2 == 4 && $3 >= 4))}'; }
if command -v scons >/dev/null 2>&1 && scons_ok scons; then
	echo "  ok      $(command -v scons)"
elif [ -x "$ROOT/build/venv/bin/scons" ] && scons_ok "$ROOT/build/venv/bin/scons"; then
	echo "  ok      $ROOT/build/venv/bin/scons"
	ln -sf "$ROOT/build/venv/bin/scons" "$BIN/scons"
else
	python3 -m venv "$ROOT/build/venv"
	"$ROOT/build/venv/bin/pip" install --quiet "scons>=4.4"
	ln -sf "$ROOT/build/venv/bin/scons" "$BIN/scons"
	echo "  added   $ROOT/build/venv/bin/scons"
fi

echo
echo "Now: export PATH=\"$BIN:\$PATH\""
echo "Fonts and icons are imported once per clone: godot --headless --path launcher --import"
[ "$MISSING" = 0 ] || { echo "Some tools are missing (above): add them to the machine's packages."; exit 2; }
