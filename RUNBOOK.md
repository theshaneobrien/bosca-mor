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
| 7 Settings and OSK | done | 76 launcher tests pass; Settings shot checked against Settings.dc.html |
| 8 Return to Bosca Mór and icons | done | 88 launcher tests, 39 daemon tests (WSL). Still open shot checked against the design; inset SVG and full PNG checked in a dev shot with test logos |
| 9 Installer | done | bash -n passes (no shellcheck on the dev machine); --dry-run lists every action and changed nothing; two runs into a scratch root in WSL with stand-in system tools: the second reported no changes. Linux export preset added (step 9 fix): `build/boscamor` is an x86_64 ELF with the PCK embedded and starts headless in WSL without script errors |
| 10 Jellyfin TV mode | done | Args from the upstream desktop file Flathub builds (D59), not yet read on the box; 90 launcher tests. Release v0.10.0 carries the Linux build |
| 1 fix: paths helper and dev IPC | done | `launcher/scripts/paths.gd` and the daemon's `paths()` build every path and honour `BOSCAMOR_HOME` (layout in D60); `--dev-port` and `BOSCAMOR_IPC` added, and the launcher round trip now uses them. 99 launcher tests, 47 daemon tests (WSL). `BOSCAMOR_HOME=dev-home` seeds `dev-home/config/apps.json` on first run |

## Rebuilding the launcher

`launcher/export_presets.cfg` has one preset, "Linux" (x86_64, PCK embedded, tests/ and tools/ left out). It needs Godot 4.7.2's export templates in `%APPDATA%/Godot/export_templates/4.7.2.stable`. After any launcher change, export again, then deploy or re-run the installer:

```bash
godot --headless --path launcher --export-release "Linux" ../build/boscamor
BOX=user@host tools/deploy.sh
```

## Dev setup (Windows, once)

- [ ] Godot 4 stable, console build, on PATH as `godot`
- [x] Godot Linux export templates installed, matching that version (4.7.2)
- [ ] WSL2 with Ubuntu: `sudo apt install python3 rsync openssh-client shellcheck x11-utils wmctrl`
- [ ] SSH key from WSL2 to the Wyse, so deploys don't prompt

## Box check batches

A after step 4, B after step 6, C after step 9 (see docs/PROMPTS.md).

## Getting it onto the box

Each release on GitHub carries the Linux build. On the box (curl and git ship with Mint; install git with `sudo apt install git` if it's missing):

```bash
git clone https://github.com/theshaneobrien/bosca-mor.git
cd bosca-mor
mkdir -p build
curl -L -o build/boscamor https://github.com/theshaneobrien/bosca-mor/releases/download/v0.10.0/boscamor
chmod +x build/boscamor
install/install.sh
```

Reboot after the installer. For a later release: `git pull`, download that release's `boscamor` the same way, and run `install/install.sh` again.

## Pending on box (Chief)

Hardware checks that sessions can't run. Tick them off after testing on the J4105.

**First, collect data for the dev sessions.** On the box, after the installer has run and you have rebooted:

```bash
tools/box-report.sh --all
```

Before it starts, open Firefox (one tab), LibreOffice Writer with unsaved text and its "Save changes?" prompt showing, and a text editor with unsaved text. It asks you to press each remote and pad button (Enter on a keyboard skips one), measures the launcher and daemon for the budgets, and writes `~/box-report-<date>.tar.gz`. Copy that back to the dev machine. It answers the G20S keycodes, the input devices and xprop fixtures, the Cinnamon power and key settings, the session type, whether the daemon service started, the Jellyfin TV entries, installed icons and the budgets. The key capture is untested here (no input devices in WSL), so tell the next session if it misbehaves.

- [ ] Run `tools/box-report.sh --all` and copy the `.tar.gz` back (all steps).

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
- [ ] Settings changes survive a reboot: hide an app, move one, change the Browser start page, add an app from the list, set Screen size and Reduce motion; reboot; all still there (step 7).
- [ ] Settings > Network and Sound open Cinnamon's panels (`cinnamon-settings network`, `cinnamon-settings sound`) and the launcher comes back when they close (step 7).
- [ ] Settings > Startup: turning it off stops the launcher opening at the next login (Cinnamon honours `X-GNOME-Autostart-enabled=false`). Needs the installer's autostart entry (step 7, after step 9).
- [ ] Settings > About on the box: device name, the box's IP address, memory, and Session reads x11 (step 7).
- [ ] If the TV crops the edges, Display > Screen size 95% or 90% brings everything inside (step 7).
- [ ] Return to Bosca Mór: with Firefox (one tab) and a text editor holding unsaved text open, run the shortcut. Firefox closes; Still open lists the editor (step 8).
- [ ] On Still open, Show me brings the editor's save prompt forward; the next Home runs Return again (step 8).
- [ ] Close anyway asks first (Cancel focused) and then closes the editor with `xkill -id` (step 8).
- [ ] Put a `full`-style PNG (600 px or more) and an SVG logo in `~/.config/boscamor/icons/`; both look sharp on a focused tile at 1080p, and Settings > Apps says "Drop-in icon" (step 8).
- [ ] Replace the synthetic `daemon/tests/fixtures/xprop/` files with real `xprop` captures from the box, including the launcher's own window, so the skip list is checked against real WM_CLASS values (step 8).
- [ ] On a fresh Mint install, `install/install.sh` makes a working box in one run; reboot, and the launcher opens full screen on login (step 9).
- [ ] A second `install/install.sh` reports "No changes" (step 9).
- [ ] After the reboot, `systemctl --user status boscamor-input` is active. If Cinnamon never starts `graphical-session.target`, the unit's `WantedBy` must change; the box report shows both (step 9).
- [ ] The installer's Spotify step: the key at `SPOTIFY_KEY_URL` in install.sh changes from time to time; if apt rejects the repository, update the URL from Spotify's Linux download page (step 9).
- [ ] The Music Assistant Companion bundle installs from its latest GitHub release (step 9).
- [ ] The installer found Cinnamon's `button-power` key and set it to `nothing`; pressing Power on the box (not the remote) does nothing on its own (step 9).
- [ ] The "Return to the launcher" shortcut is on the desktop and in the menu, and runs on one click (step 9).
- [ ] The Jellyfin tile opens straight into TV fullscreen. The box report's "Jellyfin desktop entries" section should show `Exec=... jellyfin-desktop --fullscreen --tv` under "TV [Fullscreen]"; if it differs, fix both `apps.default.json` copies (step 10).
- [ ] Check the mouse: hover dwell, click to launch, wheel one tile per notch, cursor hides after 3 s (step 2).
- [ ] The exported `/opt/boscamor/boscamor` starts full screen on X11 after login and renders with the Compatibility renderer on the J4105's GPU (step 9 fix).

## Deferred

- [ ] Toasts: launch failed, no window within 15 s, and the memory warning. The daemon events arrive (`launch_failed`, `memory_warning`) but the launcher only logs them; there is no toast UI yet, and no step names it.



- [ ] Windows build of the launcher, after Linux v1 works on the box. Godot already exports for Windows; the work is mostly a Windows counterpart to the daemon:
    - global Home and Power keys through `RegisterHotKey` or a low-level keyboard hook (ctypes, still stdlib);
    - Guide via XInput;
    - polite close with `WM_CLOSE`;
    - power through `shutdown /s` and `/r`;
    - process tracking through Job Objects instead of process groups.

  Keep this cheap by leaving every OS-specific call in the daemon and `paths.gd`, never in screen code.

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
