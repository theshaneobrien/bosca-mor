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
| Template glibc guard | done | The template built on the dev container (Debian trixie, glibc 2.41) was checked: it needs glibc 2.38 at most, and the box has 2.39, so it runs there. `tools/build-godot-template.sh` now sets aside any template that needs more than 2.39 |
| Handoff to a Linux dev container | done | Rehearsed in a Debian trixie container like the new one (user 1000, 8 GB, no capabilities, no Docker): `tools/linux-dev-setup.sh` fetches Godot 4.7.2 (SHA-512 checked) and SCons without root; all 223 launcher tests (with the Linux-only no-shell test) and 143 daemon tests pass natively; the template builds natively with `pkgconf` added. Five launcher tests had relied on the Windows-only daemon stand-in and now turn it on. CLAUDE.md, SPEC's IPC table and this file updated |
| Idle CPU: patched Godot template | done | Godot's X11 event thread polled every 1 ms (about 900 wakeups a second on the box, 14% of a core). Our export template is Godot 4.7.2 with that wait raised to 16 ms, built in Docker by `tools/build-godot-template.sh` (D100). In WSL the thread's wakeups fell from about 1200 to 325 a second. Release v0.13.2 |
| Taskbar icon | done | Our own icon for the window, the menu and the taskbar (D99). The installer's piped `grep -q` checks failed under pipefail when the writer kept going (SIGPIPE), which is why it said the minimise key wasn't there; all nine now read their input to the end, with a test. 223 launcher tests, 143 daemon tests. Release v0.13.1 |
| Full review | done | Nine reviewers, three skeptics per finding: 60 of 72 findings confirmed and fixed, plus 9 smaller ones, then two rounds of reviewers on the fixes (D85 to D98). The worst: xrandr, pactl and nmcli went through a shell (Wi-Fi names could run commands), a broken apps.json plus a save wiped the app list, website tiles got an empty kiosk profile, a failed app download aborted the installer, Power over an app left it playing unseen. 223 launcher tests, 141 daemon tests. Release v0.13.0 |
| Fix: boot picture and idle CPU | done | The boot picture is set to the exact CEA 1080p60 timing by id from `xrandr --verbose`, and every login check is logged (D83); no audio driver and a 60 Hz idle loop (D84); box-report key capture fixed (it read stdin, which was the program), plus the launcher's log, `xrandr --verbose`, kernel display messages and CPU per thread. 160 launcher tests, 70 daemon tests. Release v0.12.1 |
| Fix: third box test | done | App windows wait 2 s more behind the black (D77); the daemon focuses the launcher at login (D78); picture set to 1080p60 with xrandr and a Picture choice with keep or undo (D79); HDMI sound and start volume with pactl (D80); Wi-Fi list and join with nmcli (D81); OK keys X can't see passed on as Accept (D82). 157 launcher tests, 70 daemon tests. Release v0.12.0 |

## Rebuilding the launcher

`launcher/export_presets.cfg` has one preset, "Linux" (x86_64, PCK embedded, tests/ and tools/ left out). It uses our patched release template, `build/templates/godot.linuxbsd.template_release.x86_64` (D100), which is not committed. Build it once per clone and per Godot version: with Docker running it builds in a container (about 3 minutes on Chief's PC; the source stays in the Docker volume `boscamor-godot-src`); without Docker it builds in place under `build/godot-src/` (`NATIVE=1` forces that; `JOBS` sets the parallel jobs). Either way the script refuses a template that needs a newer glibc than the box's 2.39 (Mint 22): one built on Debian trixie needs 2.38, like the Ubuntu 24.04 one. After any launcher change, export again, then release (below), deploy, or re-run the installer:

```bash
tools/build-godot-template.sh        # once, and after moving to a new Godot version
godot --headless --path launcher --export-release "Linux" ../build/boscamor
BOX=user@host tools/deploy.sh
```

## Dev setup

**Linux dev container** (Debian trixie, as user 1000, no root, no Docker inside):

- Apt packages in the image, besides git, curl, Python 3 with venv and build-essential: `pkgconf` (the template build stops without it), `libfontconfig1` (silences a harmless Godot error), `gh` (releases), `rsync` and `openssh-client` (deploy.sh, optional). For shots, also `xvfb`, `xauth` and `libgl1-mesa-dri`.
- `tools/linux-dev-setup.sh`, then `export PATH="$PWD/build/bin:$PATH"`: the Godot 4.7.2 editor and SCons, in `build/`.
- `godot --headless --path launcher --import` once per clone, then `tools/build-godot-template.sh` once (about one job per 1.5 GB of memory: 5 jobs in 8 GB; it took 85 minutes on the server, so run it in tmux). Keep `build/godot-src/`: a rebuild after a patch change only recompiles what changed.
- `gh auth login` (or `GH_TOKEN`) with push and release rights on theshaneobrien/bosca-mor, and a git remote it can push to.
- Box reports reach the dev session however Chief copies them (on the Windows PC, from a share on the home network).

**Chief's Windows PC:**

- [x] Godot 4.7.2 console build, on PATH as `godot` (`C:\Users\shane\Desktop\Godot_v4.7.2-stable_win64_console.exe`)
- [x] Docker Desktop, for the template build
- [x] WSL2 with Ubuntu, for the daemon and installer tests
- [ ] SSH key from WSL2 to the Wyse, so deploys don't prompt

## Box test rounds

Chief installs the latest release on the box (above), tests it on the TV, and sends what he saw, usually with `tools/box-report.sh --all`'s `.tar.gz` (and `~/install.log` when the installer ran). Read `report.txt` (system, screen and `xrandr --verbose`, kernel display messages, input devices, Cinnamon settings, daemon log, the launcher's Godot log with its `picture:`, `sound:` and `wifi:` lines, sound cards, network), `keys.txt` (each remote and pad button: device, code, scancode) and `budgets.txt` (pidstat for the launcher and daemon, idle and behind an app, plus CPU and wakeups per launcher thread). `fixtures/` holds xprop captures of the open windows: anonymise titles and names before committing any as test fixtures (the repo is public). Box results go under Pending on box; never estimate them.

## Releasing

1. Bump `config/version` in `launcher/project.godot` (patch for fixes, minor for features).
2. Both test suites pass; `bash -n` on any script you touched.
3. Export: `godot --headless --path launcher --export-release "Linux" ../build/boscamor` (needs the template, above).
4. Commit and push to main.
5. Release notes in plain words, a few bullets, the build's SHA-256 and the "Update the box" commands (see an earlier release), then: `gh release create vX.Y.Z build/boscamor --title vX.Y.Z --notes-file notes.md --target main`.
6. Check that `https://github.com/theshaneobrien/bosca-mor/releases/latest/download/boscamor` has the same SHA-256 as `build/boscamor`: that is the URL the box fetches.

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

**Patched template, 25 Oct 2026 (v0.13.2).** To check on the box:

- [ ] `tools/box-report.sh --budgets`: the launcher's busiest thread (poll, about 900 wakeups a second before) should be well under 400 a second on Home and lower behind an app, and the launcher's CPU well under the 19% and 8% measured on 25 Oct (D100).
- [ ] Remote, pad, mouse and keyboard feel as quick as before: no lag on held directions or clicks (D100).

**Fourth box report, 25 Oct 2026 (v0.13.0).** The key capture worked. G20S: Home `KEY_HOMEPAGE`, Back `KEY_BACK`, Menu `KEY_COMPOSE` (Menu in X), OK `BTN_LEFT` on the mouse interface with the air mouse on and `KEY_SELECT` on the keyboard interface with it off (D92 and D82 cover both), arrows, volume, mute, voice `KEY_VOICECOMMAND`, play/pause `KEY_PLAYPAUSE`, Power `KEY_POWER`. Idle CPU fell to 19% on Home and 8% behind an app, still far over budget: one launcher thread waits in poll about 900 times a second (14% of a core) even behind an app, in WSL too, so it looks like an engine thread (likely Godot's X11 event thread); see Deferred. The installer warned that the minimise key was missing (fixed in v0.13.1). To check with v0.13.1:

- [ ] After the installer and a log out and in, the taskbar, the Alt+Tab list and the menu show the new icon (three tiles, the middle one ringed), not Godot's (D99).
- [ ] The installer no longer warns about the minimise effect.

**Full review, 23 Oct 2026 (v0.13.0).** To check on the box:

- [ ] Power with the cursor resting where Power off appears, then OK with the air mouse on: Cancel runs (D92).
- [ ] With the air mouse on, the D-pad plus OK in Settings (Display > Reduce motion) and on the Wi-Fi keyboard: the highlighted row or key acts, not what the hidden pointer is over (D92).
- [ ] Power while an app plays: the app ends and the confirm shows; Cancel, then Home works as usual (D85).
- [ ] After keys have scrolled Home, rest the pointer on the cut-off tile at the left edge: focus does not move (D93).
- [ ] Join a Wi-Fi network whose password has a capital and a symbol, using Shift and the "!#?" page; the password shows as dots (D96). If a USB keyboard is handy, also try a password with $ and a double quote (D87).
- [ ] With the TV on the Wyse's other DP or HDMI socket, sound plays through the TV (D88).
- [ ] With `BOSCAMOR_DRY_RUN=1` for the daemon, Power off goes to "Shutting down" and back to Home (D89).
- [ ] `tools/box-report.sh --keys` with no app open: the daemon pauses and starts again. Then with YouTube open: it asks you to press Home first (D98).
- [ ] The Launcher menu entry with the launcher running brings it to the front instead of starting a second one (D98).

**Third box report, 23 Oct 2026 (v0.12.0).** At boot the TV flickered at a wrong-looking mode until the cable was replugged. The report was taken after the replug, so it shows the good state only: DP-1 at 1920x1080, the second of two 60.00 Hz timings. The launcher used 25% of a core idle on Home and 15% behind an app (budgets 1% and 0.5%). The key capture skipped every button by itself (fixed). HDMI sound was right: `output:hdmi-stereo+input:analog-stereo` on Built-in Audio, LG TV on `hdmi-output-0`. The minimise effect is now `none`; still no `~/install.log`. To check with v0.12.1:

- [ ] Cold boot: does the picture come up right with no replug? Either way, run `tools/box-report.sh --all` afterwards: the "Launcher picture, sound and Wi-Fi lines" section now has what the screen was on at login and what the launcher did, even after a replug (D83).
- [ ] If it still flickers: before replugging, from another machine run `ssh tv@<box> 'DISPLAY=:0 xrandr --verbose' > bad-screen.txt` and send that with the report.
- [ ] The key capture asks for each button and records it (it skipped everything before). Press OK with the air mouse on, then off, when asked.
- [ ] Budgets: the launcher idle on Home and behind an app, and the new per-thread lines (D84).

**Third box test, 23 Oct 2026 (v0.11.3).** The daemon worked; the remote mostly did. The report showed Cinnamon's minimise effect still `traditional` and no `~/install.log`, so the installer may not have finished. Fixed since, to check with v0.12.0:

- [ ] Re-run the installer with its log: `install/install.sh 2>&1 | tee ~/install.log`, then reboot.
- [ ] Cold boot through the active DP to HDMI adapter: the picture is 1920 x 1080 at 60 Hz with no replugging. Settings > Display > Screen shows the output and mode. If not, the next box report's "Launcher picture, sound and Wi-Fi log" says what xrandr did (D79).
- [ ] Settings > Display > Picture: pick 1280 x 720, wait 15 s without pressing anything: it goes back by itself. Pick it again and Keep; then back to 1920 x 1080. Automatic may choose 4K, which the adapter may not carry: if the screen goes black, wait 15 s (D79).
- [ ] After boot, sound plays through the TV at 100%, and Settings > Sound > Playing through shows "Digital Stereo (HDMI) Output, Built-in Audio" (or HDMI 2 or 3). If it chose the wrong HDMI number, say which one works (D80).
- [ ] Volume at startup 75%, reboot: the volume is 75%; the remote's volume keys still work after (D80).
- [ ] After boot, the remote works at once with no click (D78).
- [ ] Launching apps: no desktop blip; the loading screen stays about 2 s longer before the app shows (D77).
- [ ] OK with the air mouse off selects the highlighted item. If it still does nothing, run `tools/box-report.sh --keys` and press OK with the mouse on and then off when asked (D82).
- [ ] If the box has Wi-Fi: Settings > Network lists networks; join one by typing its password; a wrong password says so (D81).

- [ ] Run the installer and keep its output: `install/install.sh 2>&1 | tee ~/install.log`. If it stops, the log says where; the next box report includes it.
- [ ] After the reboot the launcher opens full screen on its own, "Launcher" is in the menu, and `systemctl --user status boscamor-input` is active (started by the autostart entry, D67).
- [ ] Launching an app: the screen goes black and the app appears with no desktop or minimise animation in between (D65). If the minimise still shows, the box report's "Cinnamon window effects" section has what's needed to turn it off.
- [ ] Settings from the sidebar opens straight away and one Back from the section list returns Home.

- [x] Record the G20S keycodes (step 2): done in the fourth box report, 25 Oct 2026, above.
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

- [ ] Idle CPU after D100: measure on the box with `tools/box-report.sh --budgets`. If Home idle is still well over 1%, the remaining cost is the launcher's own 60 Hz loop and its X traffic (about five event-thread wakeups a frame in WSL); options are a slower idle loop while nothing moves, or SPEC's fallback of quitting the launcher on launch and starting it again on Home.
- [ ] Offer the X11 event-wait change to Godot upstream (a longer timeout, or a wake pipe so the thread blocks), so the patched template can go.

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
