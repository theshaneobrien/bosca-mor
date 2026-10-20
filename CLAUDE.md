# Bosca Mór: agent notes

A full-screen 10-foot app launcher for thin x86 Linux boxes (Dell Wyse J4105, Linux Mint Cinnamon, X11), driven by a G20S air-mouse remote, a gamepad, or keyboard and mouse. Two processes: a Godot 4 launcher and a stdlib Python daemon. The full spec is `docs/SPEC.md`; read only the sections your step names.

## How sessions work (read this first)

- **One step per session.** The steps are in `docs/PROMPTS.md`. Do that step, nothing else.
- **Stop when the step's dev checks pass.** Do not start the next step, polish, or refactor outside the step.
- **Hardware checks belong to Chief.** You cannot see the TV, press the G20S, or measure the J4105. Never simulate or estimate those results; add them to RUNBOOK.md under "Pending on box".
- **Stuck after two attempts on the same problem?** Write what you tried in RUNBOOK.md under "Blocked", then stop and say so.
- **Before you finish:** update RUNBOOK.md (step status, pending on box, deferred). Add a DECISIONS.md entry for anything that departs from the spec. Commit as `step N: <summary>`.
- Don't write planning docs, design notes or summaries. The plan is the spec, and progress lives in RUNBOOK.md.

## Laws (breaking one is a bug)

1. Screens read InputMap **actions**, never raw keys or buttons.
2. Nothing powers off, restarts or force-closes from one press. Every confirm dialog opens with **Cancel focused**.
3. `argv` runs directly, never through a shell. The daemon signals only processes it started. Force-closing a desktop window uses `xkill -id <wid>`, never a PID (flatpak PIDs can be sandbox-local).
4. One app runs at a time. Home closes it, unless the app has `keep_on_home`.
5. No per-frame work while idle: low processor mode stays on, and the launcher pauses its tree while hidden.
6. Daemon: Python 3 stdlib only (plus the `wmctrl`, `xprop`, `xkill` and `notify-send` binaries). Launcher: no addons or plugins unless DECISIONS.md says why.
7. The name "Bosca Mór" never appears in the UI. A boot splash, if ever added, is the one exception.
8. Colours, sizes, fonts and timings come from the SPEC token and motion tables. New values need a DECISIONS entry.
9. `apps.json` is config and `state.json` is state. Never mix them. Write both atomically (temp file, then rename).
10. UI copy: plain words, no em-dashes.
11. Brand logos are never committed. They live in `~/.config/boscamor/icons/` on the box.
12. Never run `sudo`, `systemctl poweroff/reboot`, or anything that changes the dev machine's system config. The daemon's power and kill paths honour `BOSCAMOR_DRY_RUN=1` (log instead of act), and tests always set it.

## Layout

```
launcher/            Godot 4 project (Compatibility renderer, 1920x1080 base)
  project.godot      InputMap actions live here
  scenes/ scripts/   one scene + script per screen; scripts/state.gd is the screen state machine
  theme/tokens.gd    every token from SPEC; nothing hard-coded elsewhere
  assets/fonts/      DM Sans, DM Mono (OFL), bundled
  tests/             run_tests.gd + test_*.gd (own tiny runner, no GUT)
  tools/shot.gd      renders a named screen state to PNG
daemon/
  boscamor-input.py  the whole daemon, one file
  tests/             unittest; fixtures/ holds recorded xprop and evdev samples
install/
  install.sh         idempotent; --dry-run prints what it would do
  files/             apps.default.json, .desktop files, user service, logind drop-in, user.js
docs/                SPEC.md, DECISIONS.md, PROMPTS.md, design/ (reference screens)
RUNBOOK.md           status, pending on box, deferred, blocked
```

## Commands

```bash
godot --path launcher                                         # run the launcher
godot --headless --path launcher -s res://tests/run_tests.gd  # launcher tests, exit code = failures
godot --path launcher -s res://tools/shot.gd -- --state=home --size=1920x1080 --out=../shots/home.png
python3 -m unittest discover -s daemon/tests                  # daemon tests
BOSCAMOR_DRY_RUN=1 python3 daemon/boscamor-input.py --fake-input   # dev daemon: type home/power/guide on stdin
bash -n install/install.sh && install/install.sh --dry-run
BOX=user@host tools/deploy.sh                                 # rsync build + daemon to the box
tools/box-report.sh --all                                     # on the box: collect what dev sessions need (.tar.gz)
```

`shots/` is gitignored. Compare screenshots against `docs/design/*.dc.html`. Those files are reference markup: tokens and layout are in their inline styles, and computed styles are in the `renderVals()` script at the bottom. They are not code to port.

## Pitfalls

Add one line here only when something cost real time. Keep this file under 120 lines.

- Fresh clone: run `godot --headless --path launcher --import` once before tests or shots, or fonts won't load. New fonts need `multichannel_signed_distance_field=true` in their `.import`, then import again.
- Never use a variable font with MSDF: overlapping contours render with artifacts (D15).
- The dev machine is Windows; the daemon and its tests need Linux. Run them in WSL: `wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/shane/dev/bosca-mor && BOSCAMOR_GODOT=/mnt/c/Users/shane/Desktop/Godot_v4.7.2-stable_win64_console.exe python3 -m unittest discover -s daemon/tests'`. The Windows Godot reaches the WSL daemon over localhost.
