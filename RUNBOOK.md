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
| Spec gaps | done | Last tile in state.json (D61), keep_screen_on off, toasts (D62), 15 s launch timeout with the daemon's `app_window` and `launch_timeout` events (D63). 106 launcher tests, 51 daemon tests (WSL) including the round trip. Not in a release yet |
| Fix: first box test | done | Full screen by default; Settings from the sidebar closes it; no daemon on Linux shows a toast; launch waits black for the app window, Desktop fades first (D65 to D68); installer starts the daemon from autostart and adds a menu entry. 121 launcher tests, 59 daemon tests |
| Fix: second box test | done | No splash; hover selects tiles; the launcher stays black behind apps and the daemon hands them the focus (D69); Return waits for save prompts (D70); minimise effect off (D71); Add app is Flatpaks and websites (D72); Remove (D73). 129 launcher tests, 65 daemon tests |
| Loading screen | done | "Opening <name>" with the tile and pulsing dots on the black while an app starts, from 0.5 s, at up to 30 fps (D76). 132 launcher tests |

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
curl -L -o build/boscamor https://github.com/theshaneobrien/bosca-mor/releases/latest/download/boscamor
chmod +x build/boscamor
install/install.sh
```

Reboot after the installer. For a later release: `git pull`, run the same `curl` (it always fetches the latest release), and run `install/install.sh` again.

## Boot splash (optional)

Your own picture while the box starts and shuts down (D75). Copy the PNG to the box (it never goes in the repo), then:

```bash
tools/boot-splash.sh ~/.config/boscamor/splash.png
```

It rebuilds the boot image (a minute), then reboot. `tools/boot-splash.sh --restore` puts Mint's splash back.

## Pending on box (Chief)

Hardware checks that sessions can't run. Tick them off after testing on the J4105.

**First, collect data for the dev sessions.** On the box, after the installer has run and you have rebooted:

```bash
tools/box-report.sh --all
```

Before it starts, open Firefox (one tab), LibreOffice Writer with unsaved text and its "Save changes?" prompt showing, and a text editor with unsaved text. It asks you to press each remote and pad button (Enter on a keyboard skips one), measures the launcher and daemon for the budgets, and writes `~/box-report-<date>.tar.gz`. Copy that back to the dev machine. It answers the G20S keycodes, the input devices and xprop fixtures, the Cinnamon power and key settings, the session type, whether the daemon service started, the Jellyfin TV entries, installed icons and the budgets. The key capture is untested here (no input devices in WSL), so tell the next session if it misbehaves.

- [ ] Run `tools/box-report.sh --all` and copy the `.tar.gz` back (all steps).

**First box test, 21 Oct 2026 (v0.11.0).** The installer hadn't run (no `/opt/boscamor`, autostart, service, input group or logind drop-in), so the launcher ran windowed with no daemon. Fixed since: full screen by default, Settings from the sidebar, a toast when the daemon is missing, and a smoother hand-off to apps. To do on the box with the next release:

What the first box report confirmed: Mint 22.3, X11, Python 3.12, 1920x1080 at 60 Hz on DP-2, wired network only (the Wi-Fi icon hides), `DISPLAY` in the systemd user environment, and Jellyfin's TV [Fullscreen] entry is exactly `--fullscreen --tv` (step 10's args). Installed icons exist for YouTube, Jellyfin, Moonlight and RetroArch (SVG) and Plex and Music Assistant (256 px PNG). Not in it: the G20S and any pad were not plugged in (only an 8BitDo keyboard receiver and a Logitech G305), so no remote keycodes yet; no key capture, budgets, launcher window class or save-prompt fixtures.

- [ ] Plug in the G20S (and any pad) before the next `tools/box-report.sh --all`, after the installer and a reboot, so the key capture records the remote.
**Second box test, 21 Oct 2026 (v0.11.1).** The installer ran and the daemon worked (launch, first window, Home closing the browser, Return). Box captures of the launcher's own window (class `Godot_Engine`/`Launcher`), Nemo, Xed and a terminal are now test fixtures in `daemon/tests/fixtures/xprop-box/`. Fixed since, to check with the next release:

- [ ] No Godot splash at start (D74).
- [ ] With the mouse, resting on a tile selects it after a moment; clicking a tile opens it.
- [ ] Launch an app: no minimise animation and no desktop in between; the keyboard works in the app at once, with no click needed (D69). Closing the app brings the launcher straight back.
- [ ] Desktop hides the launcher with no animation (D71).
- [ ] Return to the launcher with an unsaved editor: the save prompt stays in front until you answer it; the launcher comes back once the editor closes (D70).
- [ ] Open a slow app (Jellyfin, Spotify, RetroArch): after the fade the loading screen shows its tile, "Opening <name>" and pulsing dots, until the app appears. Plex may open before it shows at all (D76).
- [ ] If you install the boot splash: the picture shows centred on dark blue at start and at shut down. The Plymouth script couldn't be run on the dev machine, so if the screen stays plain dark blue or shows text, run `--restore` and tell the next session (D75).
- [ ] Settings > Apps > Add app lists only Flatpaks, plus "A website"; add one website (name with a space, then its address) and open it; then remove it with Remove (D72, D73).

- [ ] Run the installer and keep its output: `install/install.sh 2>&1 | tee ~/install.log`. If it stops, the log says where; the next box report includes it.
- [ ] After the reboot the launcher opens full screen on its own, "Launcher" is in the menu, and `systemctl --user status boscamor-input` is active (started by the autostart entry, D67).
- [ ] Launching an app: the screen goes black and the app appears with no desktop or minimise animation in between (D65). If the minimise still shows, the box report's "Cinnamon window effects" section has what's needed to turn it off.
- [ ] Settings from the sidebar opens straight away and one Back from the section list returns Home.

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
- [ ] The Jellyfin tile opens straight into TV fullscreen (step 10). The args are confirmed: the box's TV [Fullscreen] entry is `--fullscreen --tv`.
- [ ] Check the mouse: hover dwell, click to launch, wheel one tile per notch, cursor hides after 3 s (step 2).
- [ ] The exported `/opt/boscamor/boscamor` starts full screen on X11 after login and renders with the Compatibility renderer on the J4105's GPU (step 9 fix).
- [ ] Focus Spotify on Home, wait 3 s, reboot: Home comes back with Spotify focused. Launch Plex, press Home, reboot: Plex focused (spec gaps, D61).
- [ ] Set Cinnamon's screen blanking to 1 minute and leave the launcher on Home: the screen blanks on time. Put it back afterwards (spec gaps).
- [ ] Every default app shows its window within 15 s from cold on the J4105: `journalctl --user -u boscamor-input` has "<id> showed window" for each, and none says "showed no window". Firefox kiosk and Jellyfin first runs are the likeliest to be slow; if one misses, say which and how long it took (spec gaps, D63).
- [ ] Add a test tile to apps.json with `"argv": ["sleep", "60"]`, launch it: after 15 s Home returns with "<name> took too long to open" and `pgrep -x sleep` is empty. Remove the tile after (spec gaps, D63).
- [ ] A tile whose argv names a program that doesn't exist brings Home back at once with "Couldn't open <name>" (spec gaps).
- [ ] The toast reads well on the TV: size, place at the top centre, the 4 s hold, and it never steals a key press from Home (spec gaps, D62).
- [ ] The journal's "showed window" line names the app's own window, not a notification or the launcher; replace the synthetic fixtures `0x6000003.txt` and `0x6200001.txt` with real captures if the box report has them (spec gaps, D63).

## Deferred

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
