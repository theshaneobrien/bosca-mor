# Runbook

## Step status

| Step | Status | Notes |
| --- | --- | --- |
| 1 Skeleton | done | Godot 4.7.2. 11 launcher tests pass; home shots at 1080p, 720p and 4K checked against Main.dc.html |
| 2 Input layer | done | 27 launcher tests pass (16 new input tests); hint styles checked in shots |
| 3 Motion | done | 36 launcher tests pass. Home tweens built; sidebar, confirm and blur tweens are defined in motion.gd and get wired in step 4 |
| 4 Sidebar, power, desktop | done | 48 launcher tests pass; every Home, Sidebar and Power confirm cell of the navigation table is a test case. Menu and power shots checked against the design |
| 5 Daemon and IPC | done | 29 daemon tests (run in WSL on the dev machine) including the launcher round trip; 55 launcher tests |
| 6 Idle behaviour | done | 63 launcher tests pass. Dev-machine numbers below; the J4105 budgets are still to measure |
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
- [ ] Launch Plex, press Home on the remote: Plex exits and the launcher is back within 500 ms (step 5).
- [ ] Press the remote's power key with an app open and with the launcher showing: the confirm opens and nothing shuts down (step 5).
- [ ] With the daemon running, `journalctl --user -u boscamor-input` lists the G20S, the pad and the Power Button under "watching". If the G20S Home key is not `KEY_HOMEPAGE` (172), add its code to `WATCHED_KEYS` in the daemon (step 5).
- [ ] Replace `daemon/tests/fixtures/proc_bus_input_devices.txt` with `cat /proc/bus/input/devices` from the box (step 5).
- [ ] Check `xprop` on the launcher window: its title must be exactly "Launcher" for the daemon's `wmctrl -F -a` raise fallback (step 5).
- [ ] Launch Netflix (Firefox kiosk), press Home: every Firefox process of that profile ends, `pgrep -f profiles/netflix` is empty (step 5).
- [ ] Measure every row of SPEC "Budgets on the J4105" (step 6): `pidstat -p <launcher pid> 5` for 60 s on idle Home (under 1% of a core, RSS under 150 MB) and with an app in front (under 0.5%); the daemon's pid the same way (under 0.5%, under 20 MB RSS); `intel_gpu_top` shows no GPU work while idle. If hidden misses 0.5%, SPEC says switch to quitting the launcher on launch.
- [ ] Check the Wi-Fi icon on the box: shown when connected, struck through when not, gone if the box has no wireless interface (step 6).
- [ ] Check the mouse: hover dwell, click to launch, wheel one tile per notch, cursor hides after 3 s (step 2).

## Deferred

- [ ] Home with the desktop showing should run Return to Bosca Mór; the daemon only sends `show` for now (`return_from_desktop`). Step 8.
- [ ] Toasts: launch failed, no window within 15 s, and the memory warning. The daemon events arrive (`launch_failed`, `memory_warning`) but the launcher only logs them; there is no toast UI yet, and no step names it.

- [ ] The Settings column of the navigation table, and the sidebar's Settings item (it only emits `settings_requested` for now). Both come with the Settings screen in step 7.

- [ ] Jellyfin TV fullscreen Exec args. Run `grep -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop` on the box, then do step 10.

## Blocked

Nothing yet.

## Dev-machine numbers (not the box)

Step 6, 20 Oct 2026: Windows 11 desktop, Godot 4.7.2, launcher in a window, CPU from PowerShell `TotalProcessorTime` (no pidstat on Windows). These say nothing about the J4105 budgets.

| State | CPU (one core) | Working set | Frames drawn / loop iterations in 10 s |
| --- | --- | --- | --- |
| Home, idle, shown, 55 s | 2.6% | 207 MB | 1 / 1450 |
| Hidden (Desktop), 60 s | 1.5% | 207 MB | 0 / 100 |

No redraws while idle and 10 wakeups a second while hidden, as designed. The CPU is Godot's per-iteration cost on Windows (most likely the main loop polling input devices), not launcher work.

## Deploy

```bash
BOX=user@host tools/deploy.sh
```
