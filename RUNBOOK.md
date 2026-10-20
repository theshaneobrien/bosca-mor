# Runbook

## Step status

| Step | Status | Notes |
| --- | --- | --- |
| 1 Skeleton | done | Godot 4.7.2. 11 launcher tests pass; home shots at 1080p, 720p and 4K checked against Main.dc.html |
| 2 Input layer | not started | |
| 3 Motion | not started | |
| 4 Sidebar, power, desktop | not started | |
| 5 Daemon and IPC | not started | parallel track, after step 1 |
| 6 Idle behaviour | not started | |
| 7 Settings and OSK | not started | |
| 8 Return to Bosca Mór and icons | not started | |
| 9 Installer | not started | |
| 10 Jellyfin TV mode | deferred | do last, once the app is mostly built |

## Pending on box (Chief)

Hardware checks that sessions can't run. Tick them off after testing on the J4105.

- [ ] Run `evtest` on the G20S dongle and record its keycodes here (step 2).

## Deferred

- [ ] Jellyfin TV fullscreen Exec args. Run `grep -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop` on the box, then do step 10.

## Blocked

Nothing yet.

## Deploy

```bash
BOX=user@host tools/deploy.sh
```
