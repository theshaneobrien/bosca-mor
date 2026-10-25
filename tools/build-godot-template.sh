#!/usr/bin/env bash
# Builds Godot's Linux release export template with our patches
# (tools/godot-template/*.patch) inside a Docker container, so nothing is
# installed on the dev machine (Law 12). The template lands in
# build/templates/, where launcher/export_presets.cfg looks for it (D100).
#
#   tools/build-godot-template.sh            # Godot 4.7.2-stable
#   tools/build-godot-template.sh 4.8-stable # after moving to a new Godot
#
# The Godot source and its build cache stay in the Docker volume
# boscamor-godot-src, so a rebuild is quick. Ubuntu 24.04 is the base Mint 22
# uses, so the template's glibc matches the box.
set -euo pipefail

TAG="${1:-4.7.2-stable}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/templates"
NAME="godot.linuxbsd.template_release.x86_64"
mkdir -p "$OUT"

# Docker Desktop on Windows wants Windows paths for mounts.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

MSYS_NO_PATHCONV=1 docker run --rm \
	-v boscamor-godot-src:/src \
	-v "$(win "$ROOT/tools/godot-template"):/patches:ro" \
	-v "$(win "$OUT"):/out" \
	-e TAG="$TAG" -e NAME="$NAME" \
	ubuntu:24.04 bash -euo pipefail -c '
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq build-essential scons pkg-config git ca-certificates python3 patch \
			libx11-dev libxcursor-dev libxinerama-dev libgl1-mesa-dev libglu1-mesa-dev libasound2-dev \
			libpulse-dev libudev-dev libxi-dev libxrandr-dev libwayland-dev >/dev/null
		cd /src
		[ -d "godot-$TAG" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/godotengine/godot.git "godot-$TAG"
		cd "godot-$TAG"
		git checkout -q -- .            # start from the release each time
		for p in /patches/*.patch; do echo "applying $(basename "$p")"; patch -p1 --forward < "$p"; done
		scons platform=linuxbsd target=template_release arch=x86_64 production=yes lto=none accesskit=no -j"$(nproc)"
		cp bin/godot.linuxbsd.template_release.x86_64 "/out/$NAME"
	'
echo "built $OUT/$NAME"
