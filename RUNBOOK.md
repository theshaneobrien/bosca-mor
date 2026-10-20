# Runbook

## Step status

| Step | Status | Notes |
| --- | --- | --- |
| 1 Skeleton | done | Godot 4.7.2. 11 launcher tests pass; home shots at 1080p, 720p and 4K checked against Main.dc.html |
| 2 Input layer | done | 27 launcher tests pass (16 new input tests); hint styles checked in shots |
| 3 Motion | done | 36 launcher tests pass. Home tweens built; sidebar, confirm and blur tweens are defined in motion.gd and get wired in step 4 |
| 4 Sidebar, power, desktop | done | 48 launcher tests pass; every Home, Sidebar and Power confirm cell of the navigation table is a test case. Menu and power shots checked against the design |
| 5 Daemon and IPC | not started | parallel track, after step 1 |
| 6 Idle behaviour | not started | |
| 7 Settings and OSK | not started | |
| 8 Return to Bosca Mór and icons | not started | |
| 9 Installer | not started | |
| 10 Jellyfin TV mode | deferred | do last, once the app is mostly built |

## Pending on box (Chief)

Hardware checks that sessions can't run. Tick them off after testing on the J4105.

- [ ] Run `evtest` on the G20S dongle and record its keycodes here (step 2). Bound now: arrows, Enter, Esc, Backspace, `KEY_BACK`, `KEY_MENU`, Home, `KEY_HOMEPAGE`. Godot has no `KEY_COMPOSE`; SPEC says X11 delivers it as Menu, so check that with F12.
- [ ] Press every G20S button with the F12 overlay open and check the action shown matches SPEC "Input model" (step 2).
- [ ] Wave the G20S around without clicking: focus must never change and the cursor must stay hidden. Then a deliberate sweep should show the cursor (step 2).
- [ ] Check how an Xbox-style pad feels: D-pad and left stick, held-direction repeat (400 ms, then 110 ms) (step 2).
- [ ] Hold a direction for 5 s on Home with Godot's frame-time monitor open: 60 fps, no dropped frames (step 3).
- [ ] Recheck the held-direction sweep speed now that keys use the 110 ms repeat (D20). Chief found OS key repeat too fast on the dev machine. Tune `REPEAT_RATE` in tokens.gd if it's now too slow.
- [ ] Check the motion feel on the TV: tile focus overshoot, carousel glide, hero rise, end nudge, launch fade (step 3). Felt good on the dev machine.
- [ ] Open and close the sidebar a few times: the slide, the blur and the Home scale should hold 60 fps on the UHD 600 (step 4).
- [ ] Power key on the remote, then Power off in the confirm: with `BOSCAMOR_DRY_RUN=1` the daemon logs and the launcher comes back to Home (step 4, needs step 5).
- [ ] Check the mouse: hover dwell, click to launch, wheel one tile per notch, cursor hides after 3 s (step 2).

## Deferred

- [ ] The Settings column of the navigation table, and the sidebar's Settings item (it only emits `settings_requested` for now). Both come with the Settings screen in step 7.

- [ ] Jellyfin TV fullscreen Exec args. Run `grep -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop` on the box, then do step 10.

## Blocked

Nothing yet.

## Deploy

```bash
BOX=user@host tools/deploy.sh
```
