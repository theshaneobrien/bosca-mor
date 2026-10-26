#!/usr/bin/env bash
# Builds Godot's Linux release export template with our patches
# (tools/godot-template/*.patch) into build/templates/, where
# launcher/export_presets.cfg looks for it (D100).
#
#   tools/build-godot-template.sh             # Godot 4.7.2-stable
#   tools/build-godot-template.sh 4.8-stable  # after moving to a new Godot
#
# With Docker (the Windows dev machine) it builds in an Ubuntu 24.04
# container, the base Mint 22 uses, so nothing is installed on the dev
# machine (Law 12); the source and build cache stay in the Docker volume
# boscamor-godot-src. Without Docker (a Linux dev machine or dev container)
# it builds here, in build/godot-src/, and needs g++, git, pkg-config and
# SCons 4.4 or newer: tools/linux-dev-setup.sh gets SCons without root.
# NATIVE=1 forces a build here. JOBS sets the parallel jobs (default: the
# cores, capped at one per 1.5 GB of memory, because the build is
# memory-hungry and a dev container may have a limit).
set -euo pipefail

TAG="${1:-4.7.2-stable}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/templates"
NAME="godot.linuxbsd.template_release.x86_64"
FLAGS="platform=linuxbsd target=template_release arch=x86_64 production=yes lto=none accesskit=no"
mkdir -p "$OUT"

if [ "${NATIVE:-0}" != 1 ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	# Docker Desktop on Windows wants Windows paths for mounts.
	win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
	MSYS_NO_PATHCONV=1 docker run --rm \
		-v boscamor-godot-src:/src \
		-v "$(win "$ROOT/tools/godot-template"):/patches:ro" \
		-v "$(win "$OUT"):/out" \
		-e TAG="$TAG" -e NAME="$NAME" -e FLAGS="$FLAGS" -e JOBS="${JOBS:-}" \
		ubuntu:24.04 bash -euo pipefail -c '
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq
			apt-get install -y -qq build-essential scons pkg-config git ca-certificates python3 >/dev/null
			cd /src
			[ -d "godot-$TAG" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/godotengine/godot.git "godot-$TAG"
			cd "godot-$TAG"
			git config --global --add safe.directory "*"
			git checkout -q -- .            # start from the release each time
			for p in /patches/*.patch; do echo "applying $(basename "$p")"; git apply "$p"; done
			scons $FLAGS -j"${JOBS:-$(nproc)}"
			cp "bin/$NAME" "/out/$NAME"
		'
else
	for tool in g++ git pkg-config scons; do
		command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool (see tools/linux-dev-setup.sh)" >&2; exit 1; }
	done
	if [ -z "${JOBS:-}" ]; then
		JOBS="$(nproc)"
		limit="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
		[ "$limit" = max ] && limit="$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)"
		by_memory=$(( limit / (1536 * 1024 * 1024) ))
		[ "$by_memory" -lt 1 ] && by_memory=1
		[ "$by_memory" -lt "$JOBS" ] && JOBS="$by_memory"
	fi
	SRC="$ROOT/build/godot-src/godot-$TAG"
	mkdir -p "$(dirname "$SRC")"
	[ -d "$SRC" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/godotengine/godot.git "$SRC"
	git -C "$SRC" checkout -q -- .
	for p in "$ROOT"/tools/godot-template/*.patch; do echo "applying $(basename "$p")"; git -C "$SRC" apply "$p"; done
	echo "building with $JOBS jobs"
	(cd "$SRC" && scons $FLAGS -j"$JOBS")
	cp "$SRC/bin/$NAME" "$OUT/$NAME"
fi

# The box runs Mint 22 (Ubuntu 24.04 base, glibc 2.39). A template linked
# against a newer glibc will not start there, so set it aside where the
# export can't find it.
BOX_GLIBC="2.39"
need="$(LC_ALL=C grep -a -o -E 'GLIBC_2\.[0-9]+' "$OUT/$NAME" | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)"
if [ -n "$need" ] && [ "$(printf '%s\n%s\n' "$need" "$BOX_GLIBC" | sort -V | tail -1)" != "$BOX_GLIBC" ]; then
	mv "$OUT/$NAME" "$OUT/$NAME.too-new"
	echo "This template needs glibc $need, newer than the box's $BOX_GLIBC: moved to $OUT/$NAME.too-new." >&2
	echo "Build it on Ubuntu 24.04 or older (the Docker route does), or copy one built there." >&2
	exit 1
fi
echo "built $OUT/$NAME (needs glibc $need; the box has $BOX_GLIBC)"
