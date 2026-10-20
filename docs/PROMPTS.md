# Session prompts

Start every session fresh (`/clear` or a new session). Context carries over through RUNBOOK.md and DECISIONS.md, not chat history. The prompt you type is just:

> Read CLAUDE.md, then do step N from docs/PROMPTS.md.

Normal effort is right for every step. Use extended thinking only when a step is stuck: evdev parsing, X11 window handling, or a tween bug that won't settle.

**Parallel track.** Step 5 (daemon) depends only on step 1 and the IPC tables in SPEC. Run it in its own git worktree while steps 2 to 4 happen on the launcher, then merge.

---

## Step 1: Skeleton

**Read:** SPEC "Animation and visual spec" (tokens only), "App config and launching", "Screens and navigation" (Home row).

**Build:**
- Repo layout from CLAUDE.md (keep the existing `.gitignore`), and `install/files/apps.default.json` (copy the default set from SPEC).
- A Godot project using the Compatibility renderer, 1920x1080 base, stretch `canvas_items` / `keep`, low processor mode on, vsync on.
- `theme/tokens.gd` with every token. DM Sans and DM Mono bundled, with MSDF enabled.
- A static Home built from apps.json: top bar, hero, ten tiles, hint bar. The line-glyph fallback icons.
- `tests/run_tests.gd`: a minimal runner that finds `test_*.gd`, calls `test_*` methods, prints failures, and exits with the failure count.
- `tools/shot.gd` and `tools/deploy.sh`.

**Dev checks:**
- Tests: apps.json loads, 10 tiles, order preserved, a missing optional field doesn't crash.
- Shots of home at 1920x1080, 1280x720 and 3840x2160 match `docs/design/Main.dc.html`.

**Box checks:** none.

## Step 2: Input layer

**Read:** SPEC "Input model".

**Build:**
- InputMap actions in project.godot.
- An `InputMode` autoload covering remote/keyboard, controller and pointer, with mode-switch rules and air-mouse rules.
- Gamepad repeat: 400 ms delay, then every 110 ms.
- Hint glyphs that follow the mode.
- The F12 debug overlay.
- Focus movement and launch-intent on Home. Launch only emits a signal for now.

**Dev checks:** headless tests that inject `InputEventKey`, `InputEventJoypadButton`, `InputEventJoypadMotion` and `InputEventMouseMotion`, then assert focus and mode:
- 30 px of mouse jitter over 250 ms changes nothing;
- 40 px or more enters pointer mode;
- a D-pad press snaps back to focus mode;
- hover only moves focus after a 120 ms dwell.

**Box checks:**
- Run `evtest` on the G20S dongle and record the actual keycodes in RUNBOOK.md.
- Check how the pad and mouse feel.

## Step 3: Motion

**Read:** SPEC "Animation and visual spec" (Motion, Blur, Reduce motion).

**Build:**
- Every tween in the motion table, with retargeting: kill the running tween and start from the current value.
- Carousel scroll and the end-of-carousel nudge.
- Hero crossfade.
- Reduce-motion switch, read from state for now.

**Dev checks:**
- Tests: 20 rapid presses leave at most one live tween per property, and focus lands on the right tile.
- Reduce motion halves every duration.

**Box checks:** 60 fps with no dropped frames over a 5 s held sweep on the J4105.

## Step 4: Sidebar, power confirm, desktop

**Read:** SPEC "Screens and navigation".

**Build:**
- `scripts/state.gd`, the screen state machine.
- The sidebar, with its blur captured once into a quarter-size texture.
- The power confirm (Cancel focused).
- Desktop hide.
- The Power and Home actions wired into the state machine. Calls to the daemon are stubbed behind one `DaemonClient` interface.

**Dev checks:**
- The navigation table as data: one test case per cell, all passing.
- Shots match `docs/design/Menu.dc.html` and `Power.dc.html`.

**Box checks:** none beyond feel.

## Step 5: Daemon and IPC (parallel track)

**Read:** SPEC "Companion daemon", "Architecture", "Memory watch".

**Build:**
- `daemon/boscamor-input.py`, covering:
  - evdev reading with hotplug rescan
  - token handshake over TCP 127.0.0.1
  - launch with exit tracking
  - Home closes the running app
  - one app at a time
  - power via confirm only
  - notify-send
  - memory watch
- `--fake-input` dev mode.
- `BOSCAMOR_DRY_RUN`.
- The launcher-side `DaemonClient`, polled from the one always-processing node.

**Dev checks:** unittest, using `sleep 60` as a dummy app, covering:
- packed `llHHi` events parse correctly;
- a bad token gets dropped;
- launch emits `app_exited` when the process ends;
- Home sends SIGTERM to the process group and SIGKILL after 3 s;
- a second launch ends the first;
- `power` never executes without `BOSCAMOR_DRY_RUN` being honoured.

Also one integration test: a headless launcher connects, sends `launch`, and receives `app_exited`.

**Box checks:**
- Launch Plex, press Home: Plex exits and the launcher is back within 500 ms.
- The remote's power key opens the confirm and never shuts down directly.

## Step 6: Idle behaviour

**Read:** SPEC "Resource use".

**Build:**
- The hide/show cycle: minimise, pause the tree, free transient textures, raise sleep_usec, poll the socket on one timer.
- The clock timer aligned to the minute.
- Wi-Fi poll every 30 s.

**Dev checks:**
- Tests: hidden state pauses the tree and frees the blur texture, and show restores focus.
- On the dev machine, `pidstat` over 60 s as a rough sanity check, labelled as dev-machine numbers in RUNBOOK.md.

**Box checks:** every row of the budgets table, measured on the J4105.

## Step 7: Settings and on-screen keyboard

**Read:** SPEC "Screens and navigation" (Settings, On-screen keyboard), "App config", "Build order" step 7.

**Build:**
- Settings sections:
  - Apps: show/hide, reorder, Browser start page, add from `.desktop`
  - Display: UI scale, reduce motion
  - Controllers: glyph style
  - Startup
  - About: version, hostname, IP, memory, session type
- Network and Sound open Cinnamon's own panels, launched like an app.
- The D-pad on-screen keyboard.

**Dev checks:**
- Tests: reorder and hide write apps.json atomically and survive reload, and the OSK types a URL.
- Shots match `docs/design/Settings.dc.html`.

**Box checks:** changes survive a reboot.

## Step 8: Return to Bosca Mór and icons

**Read:** SPEC "Return to Bosca Mór", "Animation and visual spec" (Icons).

**Build:**
- Daemon:
  - the window listing via `xprop`, parsed from text;
  - type and class filtering;
  - `wmctrl -i -c` with a poll of up to 5 s;
  - `still_open`, `show_window` and `force_close` (`xkill -id`);
  - `--return` client mode.
- Launcher:
  - the Still open screen and the force-close confirm;
  - the icon resolver (four-step order) and `icon_style`;
  - the SVG cache in `~/.cache/boscamor/icons/`.

**Dev checks:**
- Daemon tests against recorded `xprop` fixtures: the right windows are kept and skipped, and polling stops early with a fake clock.
- Icon resolver tests with temp dirs for each fallback level.
- Shot matches `docs/design/StillOpen.dc.html`.

**Box checks:**
- With Firefox (one tab) and an editor holding unsaved text open, the shortcut closes Firefox and lists the editor.
- Show me brings the editor's save prompt forward.
- A `full` PNG and an SVG logo both look sharp on a focused tile.

## Step 9: Installer

**Read:** SPEC "System setup and packaging".

**Build:**
- `install/install.sh` with `--dry-run`. Every action checks before it writes, so a second run changes nothing.
- The files it installs: the autostart and Return shortcut `.desktop` files, the user service, the logind drop-in, and the Firefox `user.js`.
- The LightDM X11 session pin.

**Dev checks:**
- `bash -n` passes, and shellcheck passes if installed.
- `--dry-run` on the dev machine lists every action and changes nothing.

**Box checks:**
- A fresh Mint install becomes a working box in one run.
- A second run reports no changes.

## Step 10: Jellyfin TV mode (deferred to last)

Chief pastes the output of this command, run on the box:

```
grep -B2 -A3 -i tv /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop
```

Put the TV fullscreen Exec args into `apps.default.json` in place of `[TV FULLSCREEN ARGS]`. Close the item in RUNBOOK.md.

**Box checks:** the Jellyfin tile opens straight into TV fullscreen.

---

## Fix or tweak sessions

> Read CLAUDE.md. Fix: <what's wrong, where you saw it>. Touch only what's needed, add a regression test if it can be tested headless, update RUNBOOK.md, commit as `fix: <summary>`.
