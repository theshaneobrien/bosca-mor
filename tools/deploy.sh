#!/usr/bin/env bash
# Copy the launcher and daemon to the box over rsync.
#   BOX=user@host tools/deploy.sh [--dry-run]
# Ships build/boscamor (a Linux export) when it exists, otherwise the launcher
# project source, which runs on the box with `godot --path`.
# DEST defaults to /opt/boscamor; it must already exist and be writable by the
# ssh user (install.sh sets that up).
set -euo pipefail

: "${BOX:?set BOX=user@host}"
DEST="${DEST:-/opt/boscamor}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RSYNC=(rsync -az --info=stats1)
[[ "${1:-}" == "--dry-run" ]] && RSYNC+=(--dry-run --itemize-changes)

if [[ -f "$ROOT/build/boscamor" ]]; then
	"${RSYNC[@]}" "$ROOT/build/boscamor" "$BOX:$DEST/boscamor"
else
	echo "no build/boscamor export; copying launcher source to $DEST/launcher"
	"${RSYNC[@]}" --delete --exclude .godot/ --exclude export/ "$ROOT/launcher/" "$BOX:$DEST/launcher/"
fi

if [[ -f "$ROOT/daemon/boscamor-input.py" ]]; then
	"${RSYNC[@]}" "$ROOT/daemon/boscamor-input.py" "$BOX:$DEST/boscamor-input.py"
fi
