# Bosca Mór: agent notes

A full-screen 10-foot app launcher for thin x86 Linux boxes (Dell Wyse J4105, Linux Mint Cinnamon, X11), driven by a G20S air-mouse remote, a gamepad, or keyboard and mouse. Two processes: a Godot 4 launcher and a stdlib Python daemon. The full spec is `docs/SPEC.md`, and `docs/DECISIONS.md` records where the build departs from it; read the sections your task touches.

## How sessions work (read this first)

- **The ten build steps are done** (`docs/PROMPTS.md` is history). Work now comes from Chief: feedback from testing a release on the box, usually with a box report (`tools/box-report.sh`, a `.tar.gz` with `report.txt`, `keys.txt`, `budgets.txt` and xprop fixtures). Do what was asked; don't polish or refactor outside it.
- **Start from RUNBOOK.md:** the status table (newest rows on top), Pending on box, Deferred and Blocked.
- **Hardware checks belong to Chief.** You cannot see the TV, press the G20S, or measure the J4105. Never simulate or estimate those results; add them to RUNBOOK.md under "Pending on box".
- **Stuck after two attempts on the same problem?** Write what you tried in RUNBOOK.md under "Blocked", then stop and say so.
- **Before you finish:** run both test suites, update RUNBOOK.md (a status row, Pending on box, Deferred), add a DECISIONS.md entry for anything that departs from the spec or adds a token, keep AGENTS.md a copy of this file, and commit as `fix:`, `feat:` or `perf: <summary>`. If Chief is to test it, release it (RUNBOOK, "Releasing").
- Don't write planning docs, design notes or summaries. The plan is the spec, and progress lives in RUNBOOK.md.

## Laws (breaking one is a bug)

1. Screens read InputMap **actions**, never raw keys or buttons.
2. Nothing powers off, restarts or force-closes from one press. Every confirm dialog opens with **Cancel focused**.
3. `argv` runs directly, never through a shell. The daemon signals only processes it started. Force-closing a desktop window uses `xkill -id <wid>`, never a PID (flatpak PIDs can be sandbox-local).
4. One app runs at a time. Home closes it, unless the app has `keep_on_home`.
5. No per-frame work while idle: low processor mode stays on, and the launcher pauses its tree while hidden.
6. Daemon: Python 3 stdlib only (plus the `wmctrl`, `xprop`, `xkill` and `notify-send` binaries). Launcher: no addons or plugins unless DECISIONS.md says why. Its `xrandr`, `pactl` and `nmcli` calls go through `SystemSetup.run_command` only (D87), and its Linux build uses our patched Godot template (D100).
7. The name "Bosca Mór" never appears in the UI. A boot splash, if ever added, is the one exception.
8. Colours, sizes, fonts and timings come from the SPEC token and motion tables. New values need a DECISIONS entry.
9. `apps.json` is config and `state.json` is state. Never mix them. Write both atomically (temp file, then rename).
10. UI copy: plain words, no em-dashes.
11. Brand logos are never committed. They live in `~/.config/boscamor/icons/` on the box.
12. Never run `sudo`, `systemctl poweroff/reboot`, or anything that changes the dev machine's system config. The daemon's power and kill paths honour `BOSCAMOR_DRY_RUN=1` (log instead of act), and tests always set it.
13. Every config, state, cache, icon and profile path goes through one helper (`launcher/scripts/paths.gd`, `paths()` in the daemon) that honours `BOSCAMOR_HOME`. No other code builds these paths.

## Layout

```
launcher/            Godot 4 project (Compatibility renderer, 1920x1080 base)
  project.godot      InputMap actions live here
  scenes/ scripts/   one scene + script per screen; scripts/state.gd is the screen state machine
  theme/tokens.gd    every token from SPEC; nothing hard-coded elsewhere
  assets/fonts/      DM Sans, DM Mono (OFL), bundled
  assets/icon/       the launcher's own icon (D99); tools/icons.gd renders its PNGs
  data/              files read at runtime (user.js); export_presets.cfg includes data/*
  tests/             run_tests.gd + test_*.gd (own tiny runner, no GUT); fixtures/
  tools/shot.gd      renders a named screen state to PNG
daemon/
  boscamor-input.py  the whole daemon, one file
  tests/             unittest; fixtures/ holds recorded xprop and evdev samples
install/
  install.sh         idempotent; --dry-run prints what it would do
  files/             apps.default.json, .desktop files, user service, logind drop-in, user.js, share-screen
tools/
  box-report.sh      on the box: everything a dev session needs, as a .tar.gz
  deploy.sh          rsync build + daemon to the box (releases are the usual route)
  boot-splash.sh     optional Plymouth splash with Chief's picture (never committed)
  build-godot-template.sh, godot-template/   the patched Godot export template (D100)
  linux-dev-setup.sh Godot editor and SCons for a Linux dev machine, no root
docs/                SPEC.md, DECISIONS.md (D14 to D102), PROMPTS.md (history), design/ (reference screens)
RUNBOOK.md           status, pending on box, deferred, blocked, releasing
```

## Commands

```bash
godot --path launcher                                         # run the launcher
godot --headless --path launcher -s res://tests/run_tests.gd  # launcher tests, exit code = failures
godot --path launcher -s res://tools/shot.gd -- --state=home --size=1920x1080 --out=../shots/home.png
BOSCAMOR_DRY_RUN=1 python3 -m unittest discover -s daemon/tests   # daemon and installer tests (Linux)
BOSCAMOR_DRY_RUN=1 python3 daemon/boscamor-input.py --fake-input   # dev daemon: type home/power/guide on stdin
bash -n install/install.sh && install/install.sh --dry-run
godot --headless --path launcher --export-release "Linux" ../build/boscamor   # the Linux build
tools/build-godot-template.sh                                 # patched export template, once per Godot version (D100)
tools/linux-dev-setup.sh && export PATH="$PWD/build/bin:$PATH"   # Linux dev machine: godot + scons, no root
BOX=user@host tools/deploy.sh                                 # rsync build + daemon to the box
tools/box-report.sh --all                                     # on the box: collect what dev sessions need (.tar.gz)
```

## Dev machines

The Wyse is only a test target. Development happens on either of these.

**Linux dev container** (Debian trixie, no root, no Docker): `tools/linux-dev-setup.sh` puts the official Godot 4.7.2 editor (SHA-512 checked) and SCons in `build/`, linked from `build/bin`. Each shell starts fresh, so the image puts it on PATH (`ENV PATH="/workspace/bosca-mor/build/bin:$PATH"` in its Dockerfile); otherwise prefix commands with `PATH="$PWD/build/bin:$PATH"` from the repo root. Everything runs natively: launcher tests, daemon and installer tests, the export, and the template build (`tools/build-godot-template.sh` builds without Docker here, about one job per 1.5 GB of memory). It needs `pkgconf` from apt for the template build (Godot's build stops without `pkg-config`), and `libfontconfig1` silences a harmless "Unable to load fontconfig" error. Shots need a display: `xvfb` and Mesa (`xvfb-run -a godot --path launcher -s res://tools/shot.gd ...`); without them, skip shots. Releases need `gh` signed in to the repo.

**Windows plus WSL2** (Chief's PC):

- **Launcher:** run Godot natively on Windows. `godot` on PATH is the console build.
- **Daemon:** Linux-only (evdev, process groups, X11 tools), so run it and its tests in WSL2. Prefix those commands with `wsl`, for example `wsl python3 -m unittest discover -s daemon/tests`.
- **Dev paths:** set `BOSCAMOR_HOME=dev-home` (gitignored, in the repo) so config, state and cache land there instead of `~/.config`.
- **Windows launcher to WSL2 daemon:** start the daemon with `wsl python3 daemon/boscamor-input.py --fake-input --dev-port 47800`. It prints its token. Then run the launcher with `BOSCAMOR_IPC=47800:<token>`. WSL2 forwards localhost.
- **Shipping to the box:** export, then release it on GitHub (RUNBOOK, "Releasing"); `wsl env BOX=user@host tools/deploy.sh` also works on the home network.
- **Template build:** with Docker Desktop running, `tools/build-godot-template.sh` builds in an Ubuntu 24.04 container.
- **Linux-only behaviour** (`xprop`, `wmctrl`, `xkill`, `/proc`, evdev, `run_command`) is tested against recorded fixtures on Linux or under WSL2. The real thing runs on the box.

`shots/` and `dev-home/` are gitignored. Compare screenshots against `docs/design/*.dc.html`. Those files are reference markup: tokens and layout are in their inline styles, and computed styles are in the `renderVals()` script at the bottom. They are not code to port.

## Pitfalls

Add one line here only when something cost real time. Keep this file under 120 lines.

- Fresh clone: run `godot --headless --path launcher --import` once before tests or shots, or fonts won't load. New fonts need `multichannel_signed_distance_field=true` in their `.import`, then import again.
- Exports use our patched template in `build/templates/` (D100). On a fresh clone run `tools/build-godot-template.sh` (Docker running) before exporting, or the export fails.
- Never use a variable font with MSDF: overlapping contours render with artifacts (D15).
- The daemon tests need Linux. On Windows run them in WSL: `wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/shane/dev/bosca-mor && BOSCAMOR_DRY_RUN=1 BOSCAMOR_GODOT=/mnt/c/Users/shane/Desktop/Godot_v4.7.2-stable_win64_console.exe python3 -m unittest discover -s daemon/tests'`. `BOSCAMOR_GODOT` (any Godot editor) enables the launcher round trip test.
- On Linux the launcher has no stand-in for a missing daemon: a launch fails at once (D66). Launcher tests that launch apps set `main.daemon.stand_in = true` in their setup.
- Bash scripts here use `set -o pipefail`: never pipe into `grep -q` (it stops reading, the writer gets SIGPIPE, the pipeline fails); use `grep ... >/dev/null`.
