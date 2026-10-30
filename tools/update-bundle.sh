#!/usr/bin/env bash
# Builds build/boscamor.tar.xz, the update the box downloads from a release
# (D103): the launcher build, the daemon and the installer's files, laid out
# as in the repo, so install/install.sh --update runs from inside it.
#   tools/update-bundle.sh            after exporting build/boscamor
# It checks the build first: the launcher must start headless and say the
# version in launcher/project.godot, which the release's tag must match.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/boscamor"
OUT="$ROOT/build/boscamor.tar.xz"
PARTS=(daemon/boscamor-input.py install launcher/assets/icon)

version="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$ROOT/launcher/project.godot")"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "no X.Y.Z version in launcher/project.godot" >&2
	exit 1
fi
if [ ! -f "$BUILD" ]; then
	echo "no build/boscamor: export the launcher first" >&2
	exit 1
fi
# Committed files only, so the update is what the release's tag has.
if [ -n "$(git -C "$ROOT" status --porcelain -- "${PARTS[@]}" launcher/project.godot)" ]; then
	echo "uncommitted changes in ${PARTS[*]} or project.godot: commit them first" >&2
	exit 1
fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
got="$("$BUILD" --headless --log-file "$stage/self-test.log" -- --self-test 2>/dev/null | grep '^self-test ok' || true)"
rm -f "$stage/self-test.log"
if [ "$got" != "self-test ok $version" ]; then
	echo "build/boscamor says '${got:-nothing}', not 'self-test ok $version': export it again" >&2
	exit 1
fi
python3 "$ROOT/daemon/boscamor-input.py" --self-test >/dev/null

mkdir -p "$stage/build"
printf '%s\n' "$version" > "$stage/version"
cp "$BUILD" "$stage/build/boscamor"
chmod 0755 "$stage/build/boscamor"
git -C "$ROOT" archive HEAD -- "${PARTS[@]}" | tar -x -C "$stage"
tar -C "$stage" --owner=0 --group=0 --numeric-owner --sort=name -cf - version build daemon install launcher \
	| xz -6 -T0 > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "$OUT: version $version, $(stat -c %s "$OUT") bytes, SHA-256 $(sha256sum "$OUT" | cut -d' ' -f1)"
