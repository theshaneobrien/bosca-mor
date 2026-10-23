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
# WSL sees every file on the Windows drive as 0777, and -a copies modes as
# they are: go-w keeps the daemon and launcher writable by their owner only.
RSYNC=(rsync -az --chmod=go-w --info=stats1)
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1 && RSYNC+=(--dry-run --itemize-changes)

if [[ -f "$ROOT/build/boscamor" ]]; then
	# One ELF file with the PCK embedded; anything else is a broken export.
	if [[ "$(head -c 4 "$ROOT/build/boscamor" | od -An -tx1 | tr -d ' \n')" != 7f454c46 ]]; then
		echo "build/boscamor is not a Linux build; export it again (Linux preset)" >&2
		exit 1
	fi
	"${RSYNC[@]}" "$ROOT/build/boscamor" "$BOX:$DEST/boscamor"
else
	echo "no build/boscamor export; copying launcher source to $DEST/launcher"
	"${RSYNC[@]}" --delete --exclude .godot/ --exclude export/ "$ROOT/launcher/" "$BOX:$DEST/launcher/"
fi

if [[ -f "$ROOT/daemon/boscamor-input.py" ]]; then
	"${RSYNC[@]}" "$ROOT/daemon/boscamor-input.py" "$BOX:$DEST/boscamor-input.py"
fi

# Nothing is restarted here: restarting the daemon's service would also close
# the app it is running, and the launcher would keep its old code anyway.
if [[ "$DRY" == 0 ]]; then
	echo "Deployed. Log out and back in on the box (or reboot) so the new launcher and daemon run."
fi
