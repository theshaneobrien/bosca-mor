# Runbook

## Step status

| Step | Status | Notes |
| --- | --- | --- |
| 1 Skeleton | not started | |
| 2 Input layer | not started | |
| 3 Motion | not started | |
| 4 Sidebar, power, desktop | not started | |
| 5 Daemon and IPC | not started | parallel track, after step 1 |
| 6 Idle behaviour | not started | |
| 7 Settings and OSK | not started | |
| 8 Return to Bosca Mór and icons | not started | |
| 9 Installer | not started | |
| 10 Jellyfin TV mode | deferred | do last, once the app is mostly built |

## Dev setup (Windows, once)

- [ ] Godot 4 stable, console build, on PATH as `godot`
- [ ] Godot Linux export templates installed, matching that version
- [ ] WSL2 with Ubuntu: `sudo apt install python3 rsync openssh-client shellcheck x11-utils wmctrl`
- [ ] SSH key from WSL2 to the Wyse, so deploys don't prompt

## Box check batches

A after step 4, B after step 6, C after step 9 (see docs/PROMPTS.md).

## Pending on box (Chief)

Hardware checks that sessions can't run. Tick them off after testing on the J4105.

- [ ] Run `evtest` on the G20S dongle and record its keycodes here (step 2).

## Deferred

- [ ] Jellyfin TV fullscreen Exec args. Run `grep -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop` on the box, then do step 10.

- [ ] Windows build of the launcher, after Linux v1 works on the box. Godot already exports for Windows; the work is mostly a Windows counterpart to the daemon:
    - global Home and Power keys through `RegisterHotKey` or a low-level keyboard hook (ctypes, still stdlib);
    - Guide via XInput;
    - polite close with `WM_CLOSE`;
    - power through `shutdown /s` and `/r`;
    - process tracking through Job Objects instead of process groups.

  Keep this cheap by leaving every OS-specific call in the daemon and `paths.gd`, never in screen code.

## Blocked

Nothing yet.

## Deploy

```bash
BOX=user@host tools/deploy.sh
```
