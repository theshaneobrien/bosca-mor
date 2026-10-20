# Bosca Mór: 10-foot launcher spec

Oct 20, 2026 · @Shane O'Brien

## Overview

Bosca Mór (Irish for "big box") is a full-screen 10-foot app launcher for thin x86 Linux clients. You drive it with a TV remote, a controller, or a keyboard and mouse. Large app tiles sit in a left-to-right carousel. Back opens a sidebar with Settings, Desktop, Restart and Power off. The visual guide is SteamOS Big Picture, kept simpler. The name never appears in the UI; the one exception is a boot splash, if one is needed, where it stays small and understated. The screens are mocked up in the design screens in `docs/design/` (also on the [TV Launcher design canvas](https://claude.ai/artifact/LjukuFmaJpT1S4m84R5RKt)).

**Goals**

- A non-technical family member can use it with only the G20S remote.
- Motion feels premium: 60 fps focus and carousel animation on an Intel J4105.
- CPU and GPU use is close to zero when idle or when another app has focus.
- One input model covers remote, controller, keyboard and mouse.
- The app list lives in a config file, so adding an app needs no code change.

**Non-goals for v1**

- It is not a media player or app store. It only launches other apps.
- No content rows (continue watching, recent photos).
- No user accounts or config sync.
- No voice control. The G20S microphone is ignored.
- No compositor of its own. It runs inside the existing desktop session.

## Target hardware, OS and session

The v1 target is a Dell Wyse thin client running Linux Mint Cinnamon on X11, plugged into a 1080p TV.

| Item | Target |
| --- | --- |
| Reference box | Dell Wyse, Intel J4105, 8 GB RAM, Intel UHD 600 |
| Display | 1920×1080 over HDMI or DP. The UI is authored at 1080p and scales to any 16:9 output |
| OS and session | Linux Mint Cinnamon, X11, auto-login into one household user |
| Dev machine | CachyOS with KDE. It must run there for development; Wayland is not a v1 target |
| Remote | G20S air mouse on its 2.4G USB dongle (Bluetooth not supported in v1) |
| Controllers | Anything Godot's gamepad mapping supports: Xbox, DualSense, 8BitDo |
| Keyboard and mouse | Any USB or Bluetooth HID |

The G20S dongle shows up as an ordinary USB keyboard plus mouse plus microphone, so no CEC or IR handling is needed. Prefer the dongle over Bluetooth: it responds instantly after idle, while Bluetooth HID often drops the first press while reconnecting.

## Screens and navigation

There are five screens: Home, the sidebar, the power confirm dialog, Settings, and "desktop" (launcher hidden). The design screens in `docs/design/` have the layout of each; build to it.

| Screen | What it shows |
| --- | --- |
| Home | Top bar with "Home", Wi-Fi state, date and clock. A hero with the focused app's kind, name and one-line description. The tile carousel. A hint bar along the bottom |
| Sidebar | A 560 px panel from the left over a dimmed Home. Clock and date, then Home, Settings, Desktop. Below a divider: Restart, Power off. Hint bar at the foot |
| Power confirm | A modal reading "Power off this device?" or "Restart this device?" with Cancel and the action. **Cancel has focus by default** |
| Settings | A section list on the left (Apps, Display, Network, Sound, Controllers, Startup, About) and the selected section on the right |
| Desktop | The launcher window is hidden and the desktop shows. A desktop notification says how to bring it back |

**Navigation by action and screen**

| Action | Home | Sidebar | Power confirm | Settings |
| --- | --- | --- | --- | --- |
| Left / Right | Move focus one tile, stop at the ends with a small bump | No-op | Move between the two buttons | Left from content goes to the section list; Right goes into content |
| Up / Down | No-op in v1 (one row) | Move through items, skipping the divider | No-op | Move through items |
| Accept | Launch the focused app | Run the item | Run the focused button | Toggle or open the item |
| Back | Open the sidebar | Close it | Return to the sidebar | Up one level; at the top, return to Home |
| Menu | Open the sidebar | Close it | No-op | No-op |
| Home | No-op | Close it | Close everything, show Home | Return to Home |
| Power key | Open the power confirm | Open the power confirm | No-op | Open the power confirm |

**Behaviour rules**

- Holding a direction repeats after 400 ms, then every 110 ms. Implement repeat yourself for gamepads; keyboard echo covers keys.
- Home remembers the last focused tile across launches and reboots (persist it in the state file).
- Launching: the focused tile zooms and the screen fades to black, then the window hides. If the app shows no window within 15 s, return to Home with an error toast naming the app.
- When an app exits, the launcher comes back with the same tile focused.
- Desktop: hide the launcher and send a notification: "Launcher closed. Press Home on the remote, the Guide button, or Super + Home to bring it back."
- Restart and Power off always go through the confirm dialog. Nothing powers off from a single press.

**On-screen keyboard.** Settings fields (the Browser start page in v1) must be editable without a physical keyboard. Build a simple D-pad grid: letters, digits, `.` `/` `:` `-` `_`, a `.com` key, backspace and Done. A physical keyboard types straight into the field when present. Pages inside Firefox kiosk can't use it, so sign in to Netflix and Prime Video once with a real keyboard.

## Return to Bosca Mór

Return to Bosca Mór leaves the desktop the way SteamOS's Return to Gaming Mode does. It asks every desktop app to close, lets each one ask about unsaved work, and only then shows Home. Nothing is force-closed unless the viewer confirms it. Unlike SteamOS, it does not log out: the launcher lives in the same session, and a logout would restart everything, which is slow on the J4105.

**Triggers**

- A "Return to Bosca Mór" shortcut on the desktop and in the Cinnamon menu. It runs `boscamor-input --return`, which sends `{"cmd":"return"}` to the running daemon and exits.
- Home, Guide or Super + Home while the desktop is showing (after Desktop was chosen in the sidebar).

**Flow**

1. The daemon lists top-level windows from `_NET_CLIENT_LIST` (`xprop -root`), then reads each window's `_NET_WM_WINDOW_TYPE`, `WM_CLASS` and `_NET_WM_NAME`.
2. It closes only `NORMAL` windows. It skips the launcher, Cinnamon's own windows (`WM_CLASS` Cinnamon, Nemo-desktop), and anything typed DESKTOP, DOCK, NOTIFICATION, SPLASH, TOOLBAR or MENU. Dialogs are left alone, since each belongs to a parent window.
3. It sends each one a polite close with `wmctrl -i -c <window id>`, the same as clicking its X. Each app then decides: close at once, or show its own save prompt.
4. It polls every 250 ms for up to 5 s, stopping early once nothing is left.
5. Nothing left: the launcher shows Home with the return fade.
6. Something left: the launcher shows the Still open screen.

**Still open screen** (see the design canvas)

- Title: "2 apps are still open". Body: "They may be asking to save your work." Then each app's icon and name, taken from its `.desktop` entry where one matches `WM_CLASS`, else the window title.
- **Show me** has focus by default. It hides the launcher and raises the first remaining window (`wmctrl -i -a`), so its save prompt is in front of the viewer. The next Home starts the flow again from step 1.
- **Close anyway** opens a confirm: "Close 2 apps? Unsaved work will be lost." Cancel has focus. On confirm, the daemon calls `xkill -id <window id>` for each window. It does not signal a PID: flatpak windows can report a PID from inside their sandbox, which may not be the real one.
- **Back to desktop** hides the launcher and closes nothing.

**IPC additions**

| Direction | Message | Meaning |
| --- | --- | --- |
| Shortcut or launcher to daemon | `{"cmd":"return"}` | Start the flow |
| Daemon to launcher | `{"evt":"still_open","apps":[{"wid":"0x3a00007","name":"LibreOffice Writer","icon":"…"}]}` | Show the Still open screen |
| Launcher to daemon | `{"cmd":"show_window","wid":"0x3a00007"}` | Show me |
| Launcher to daemon | `{"cmd":"force_close","wids":[…]}` | Close anyway, after the confirm |

**Limits.** Apps sitting in the tray with no open window get no close request and keep running. The daemon never signals processes it didn't start. X11 only, which matches the pinned session.

## Architecture

Two processes: a Godot launcher that owns the screen while shown, and a small stdlib Python daemon that keeps listening while an app has focus.

```
 Input devices ──X11──▶ Launcher (Godot) ──read/write──▶ apps.json
 (G20S, pad, kbm)          ▲                              ~/.config/boscamor
       │                   │ JSON lines on 127.0.0.1
       │ evdev, read only  ▼
       └──────────────▶ boscamor-input daemon ──spawn, watch exit──▶ Apps (flatpaks, kiosks)
                         (Python stdlib, user unit)
                           │
                           └──poweroff, reboot──▶ systemd-logind
```

The launcher reads `apps.json` and hands the chosen app's `argv` to the daemon, which spawns it and reports when it exits. Only the daemon sees the remote while another app is in front, which is why Home, Guide and Power go through it.

## Input model

Every device feeds the same set of actions through Godot's InputMap; screens only ever read actions, never raw keys.

| Action | Keyboard | G20S remote | Controller | Mouse |
| --- | --- | --- | --- | --- |
| `nav_left/right/up/down` | Arrow keys | D-pad (sends arrows) | D-pad, left stick (deadzone 0.5) | Wheel scrolls the carousel one tile per notch |
| `accept` | Enter, keypad Enter, Space | OK (sends Enter) | A / south button | Left click |
| `back` | Esc, Backspace | Back (`KEY_BACK`, Esc on some units) | B / east button | Right click, mouse back button |
| `menu` | none | Menu (`KEY_MENU` or `KEY_COMPOSE`, both arrive as Menu under X11) | Start | none |
| `home` | Home key | Home (`KEY_HOMEPAGE`) | Guide | none |
| `power` | none | Power (`KEY_POWER`), via the daemon only | none | none |
| Volume, mute | Media keys | Volume, mute | none | none |

Volume and mute are left to PipeWire and the desktop; the launcher does not bind them. The G20S keycodes vary between firmware batches, so the first job on real hardware is `evtest` on the dongle and a check against this table. Bind both variants where they differ.

**Input modes**

The launcher is in one of three modes, set by the last device used. The mode changes the hint glyphs and whether the cursor shows.

| Mode | Entered by | Cursor | Hint labels |
| --- | --- | --- | --- |
| Remote / keyboard | Any key press | Hidden | "OK" and "Back" (works for both, since the launcher can't tell the G20S from a keyboard) |
| Controller | Any gamepad button or stick past deadzone | Hidden | Glyphs by pad type: Xbox letters by default, PlayStation shapes when the pad name contains DualSense, DualShock or PS |
| Pointer | A mouse click, or a move of 40 px or more within 250 ms | Shown, auto-hides after 3 s still | Same as the previous mode |

**Air mouse rules.** The G20S gyro moves the pointer whenever the remote moves, even when the user is only pressing the D-pad. So:

- Small motion never enters pointer mode and never moves focus.
- In remote or controller mode, hover is ignored entirely.
- Any directional input snaps back to focus mode and hides the cursor at once.
- In pointer mode, hover moves focus only after a 120 ms dwell on a tile; a click launches.
- Clicking the dimmed area beside the sidebar closes it.

Add a debug overlay (F12) showing the last event, its device, its mapped action and the current mode. It is how the G20S mapping gets checked on real hardware.

## Animation and visual spec

Build in Godot 4 (current stable) with the Compatibility renderer, vsync on, at 60 fps on the UHD 600.

**Tokens** (match the design canvas)

| Token | Value |
| --- | --- |
| Background | `#0c0c14` |
| Panel surface / border | `#13131e` / `#262638` |
| Text / muted / dim label | `#f2f2f7` / `#a3a3b8` / `#8e8ea6` |
| Focus ring | `#f2f2f7`, 6 px gap then a 5 px ring |
| Accents | coral `#ff7a6b`, yellow `#ffc94d`, cyan `#5fdcea`, teal `#3cc4a8` |
| Fonts | DM Sans 400/500/700, DM Mono 400/500, bundled (OFL), rendered as MSDF so they stay crisp when scaled |
| Base canvas | 1920×1080, stretch mode `canvas_items`, aspect `keep` |
| Tile | 260 px square, radius 30, 40 px gap, focused scale 1.12 |
| Type | Hero name 120 px bold, description 38 px, tile label 30 px, hints 28 px |

**Motion**

| Element | Motion | Duration | Easing |
| --- | --- | --- | --- |
| Tile focus | Scale 1.0 to 1.12 from the bottom centre, ring fades in; old tile reverses | 160 ms | Back out, slight overshoot |
| Carousel scroll | Shifts once focus passes the fourth tile, keeping focus in view | 220 ms | Quint out |
| Hero text | Crossfade with a 12 px rise; kind label colour tweens to the new accent | 180 ms | Cubic out |
| Sidebar open | Panel slides in from −560 px, dim fades to 74%, Home scales to 0.96 behind a blur | 240 ms | Quint out |
| Sidebar close | Reverse of open | 180 ms | Cubic in |
| Power confirm | Fade in, scale 0.96 to 1 | 200 ms | Cubic out |
| Launch | Focused tile scales to 1.3 while the screen fades to black | 350 ms | Cubic in |
| Return from app | Fade in from black, focus restored | 250 ms | Cubic out |
| End of carousel | 12 px nudge and back | 160 ms | Sine in-out |

Every tween must retarget smoothly: on new input, kill the running tween and start from the current value, never from the end state. Fast repeated presses should glide, not stutter.

**Blur.** Never blur live every frame. When the sidebar opens, capture Home once into a quarter-size texture, blur it in a shader, and show that behind the panel. Free the texture when the sidebar closes.

**Icons.** Real high-resolution logos are supported. For each app the launcher takes the first icon it finds, in this order:

1. The `icon` path in `apps.json`.
2. A drop-in file, `~/.config/boscamor/icons/<id>.svg` or `<id>.png`. Swapping a logo needs no JSON edit.
3. The icon the app installed. For a flatpak, its export under `/var/lib/flatpak/exports/share/icons/hicolor/` (scalable SVG first, then the largest PNG). For a native app, the theme icon named in its `.desktop` file.
4. The built-in line glyph in the app's accent colour, as in the mockups.

The `icon_style` field in `apps.json` sets how the icon is drawn:

- `inset` (default): the logo is centred on the app's `tint` at 60% of the tile. Use it for plain logos with no background.
- `full`: the image fills the whole tile, clipped to the 30 px radius, and `tint` is ignored. Use it for brand logos that carry their own background, such as Netflix or Plex.

A focused tile is about 290 px at 1080p and about 580 px at 4K, so supply SVG, or PNG at 600 px or more. Rasterise SVGs at runtime with `Image.load_svg_from_buffer` at the current display scale, and cache the result under `~/.cache/boscamor/icons/`. Redo it when the source file or the scale changes. Godot's SVG renderer skips some features, such as filters and blurs; use a PNG for logos that rely on them. Settings › Apps shows where each icon came from.

Brand logos are trademarks. Never commit them to the repo; the drop-in folder keeps them local.

**Reduce motion** (Settings › Display): crossfades only, all durations halved.

## Resource use

The launcher redraws only while something is animating, and does almost nothing while hidden behind an app.

**While shown**

- Low processor mode stays on (`application/run/low_processor_mode`). A static Home costs no redraws.
- The clock updates once a minute, from a timer aligned to the minute boundary. No per-frame `_process` work on idle screens.
- Wi-Fi state is polled every 30 s, not every frame.

**While hidden (an app is running, or Desktop was chosen)**

1. Finish the launch fade, then minimize the window.
2. Pause the scene tree. Stop any tweens and free the blur texture and other transient textures.
3. Raise `low_processor_mode_sleep_usec` to 100 000 (about 10 wakeups a second).
4. Keep exactly one node on `PROCESS_MODE_ALWAYS`: a timer that polls the daemon socket every 100 ms.
5. On a `show` event, reverse all of this, restore the window, take focus, and play the return fade.

If measured idle use while hidden misses the budget below, switch to quitting the launcher on launch and letting the daemon start it again on Home. That needs a cold start under 1.5 s.

**Budgets on the J4105**

| State | CPU | Memory | Frames |
| --- | --- | --- | --- |
| Home, idle, shown | Under 1% of one core over 60 s | Launcher under 150 MB RSS | No redraws when nothing moves |
| Animating | Not budgeted | Same | 60 fps, no dropped frames over a 5 s carousel sweep |
| Hidden behind an app | Under 0.5% of one core | Same | No redraws |
| Daemon, any state | Under 0.5% of one core | Under 20 MB RSS | n/a |

These are targets. Check them with `pidstat -p <pid> 5` for CPU and `intel_gpu_top` for GPU, plus Godot's frame-time monitor during animation.

**Memory watch.** Home closing apps keeps one app running at most, which is the main protection. The daemon also reads `/proc/meminfo` and the running app's process-group RSS (summed `VmRSS` from `/proc/<pid>/status`) every 10 s, which costs next to nothing.

- It logs both to the journal each minute.
- If `MemAvailable` stays under 512 MB for 30 s, it logs a warning naming the app. The launcher shows that as a toast the next time it appears.
- It never kills an app for memory; the kernel OOM killer is the last resort.
- Settings › About shows current memory use and the last warning.

## Companion daemon: boscamor-input

`boscamor-input` is a single-file Python 3 script, stdlib only, run as a systemd user service. It does the jobs the launcher can't do while hidden.

**Responsibilities**

1. **Global keys.** Read `/dev/input/event*` without grabbing, and act only on Home (`KEY_HOMEPAGE`), gamepad Guide (`BTN_MODE`), Super + Home, and Power (`KEY_POWER`).
2. **App lifecycle.** Spawn apps for the launcher, track each process, and report when it exits.
3. **Power.** Run `systemctl poweroff` or `systemctl reboot`, but only after the launcher's confirm dialog asks for it.
4. **Notifications.** Send the "Launcher closed" message with `notify-send` when Desktop is chosen.

**Key handling rules**

- Home, Guide or Super + Home while the launcher is **hidden**: send `show`. If an app the launcher started is running, close it first (see Home closes the app). If the desktop is showing, run Return to Bosca Mór instead.
- Home or Guide while the launcher is **shown**: ignore it. The launcher already sees these keys itself, and acting twice would double-trigger.
- Power, in any state: send `power_confirm` (which also shows the launcher). Never act on Power directly.
- Ignore key repeats (value 2); act on press (value 1) only.

**Home closes the app.** When Home arrives while an app is running, the daemon ends it: SIGTERM to the app's process group, up to 3 s grace, SIGKILL if it is still alive, then `show`. This saves power and memory, and the apps resume where the viewer left off. An app with `keep_on_home` set keeps running instead. **One app at a time:** launching an app while another is still running ends the first the same way.

**Reading evdev.** Each event is a `struct input_event`, 24 bytes on x86\_64: format `llHHi` (seconds, microseconds, type, code, value). `EV_KEY` is type 1. Select the devices whose capabilities in `/proc/bus/input/devices` include the keys above. Rescan `/dev/input` every 3 s for hotplug, so a replugged dongle or a newly paired pad gets picked up. The household user must be in the `input` group. That group can read every keystroke, which is acceptable on a single-purpose box.

**Spawning apps.** Use `subprocess.Popen` with `start_new_session=True`, so apps survive a daemon restart and don't receive its signals. Watch for exit with a non-blocking `waitpid` in the main loop. Browser apps need a separate browser profile each (see App config), otherwise the browser hands the URL to an existing process and the PID exits at once.

**IPC.** Godot 4 has no Unix-socket API, so the two talk over TCP on `127.0.0.1`. On start the daemon binds a random port and writes the port and a random 32-byte token to `$XDG_RUNTIME_DIR/boscamor/` (directory mode 0700). The launcher reads both. The first line on every connection must be the token; anything else is dropped. Messages are newline-delimited JSON.

**Dev override.** On the Windows dev machine the launcher can't read the WSL2 daemon's runtime dir. In that case, `boscamor-input --dev-port <port>` binds that fixed port on 127.0.0.1 and prints its token. The launcher reads `BOSCAMOR_IPC=<port>:<token>` from the environment in preference to the runtime files. Neither is used on the box.

| Direction | Message | Meaning |
| --- | --- | --- |
| Launcher to daemon | `{"cmd":"state","visible":true}` | Sent on every show or hide, so the daemon knows whether to act on Home |
| Launcher to daemon | `{"cmd":"launch","id":"plex","argv":[…]}` | Start an app; the argv comes from the launcher's config |
| Launcher to daemon | `{"cmd":"power","action":"poweroff"}` | Confirmed power action; `reboot` also allowed |
| Launcher to daemon | `{"cmd":"desktop"}` | Desktop chosen: send the notification |
| Daemon to launcher | `{"evt":"show"}` | Bring the launcher back |
| Daemon to launcher | `{"evt":"power_confirm"}` | Show the launcher and open the power dialog |
| Daemon to launcher | `{"evt":"app_exited","id":"plex","code":0}` | The app's process ended |
| Daemon to launcher | `{"evt":"launch_failed","id":"plex","error":"…"}` | The spawn failed |

**Raising the window.** On `show`, the launcher restores and focuses its own window. Cinnamon's focus-stealing prevention may refuse that. If so, the daemon falls back to `wmctrl -a boscamor` (apt package `wmctrl`, the one non-stdlib dependency).

## App config and launching

The app list is `~/.config/boscamor/apps.json`. Carousel order is array order. Settings › Apps edits this file; it is also fine to hand-edit. Last-focused app and similar state go in a separate `~/.local/state/boscamor/state.json`, never in the config. Every path here (config, state, cache, icons, browser profiles) resolves through one helper. When `BOSCAMOR_HOME` is set, they all sit under it instead, which is how the Windows dev machine keeps them inside the repo's `dev-home/`.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | Stable slug, unique |
| `name` | string | yes | Tile label and hero title |
| `kind` | string | yes | Video, Music, Games, Web or Other (hero label) |
| `description` | string | yes | One line under the hero title |
| `icon` | path | no | SVG, or PNG at 600 px or more; see Icons for the fallback order and icon\_style |
| `glyph` | string | no | Built-in glyph name used when there is no icon |
| `tint` / `accent` | hex | yes | Tile background / glyph and hero label colour |
| `argv` | array | yes | Command to run, no shell. A `{url}` element is replaced with `url` |
| `url` | string | no | Start page for browser tiles |
| `url_editable` | bool | no | Settings › Apps lets the user change `url` |
| `keep_on_home` | bool | no | Home leaves this app running instead of closing it (default false) |
| `hidden` | bool | no | Kept in config but not shown on Home |

The default set below has ten apps, in carousel order. Most are flatpaks. Netflix, Prime Video and Browser are Firefox in kiosk mode, each with **its own profile directory**, so each runs as its own process and keeps its own sign-in.

```json
[
  {"id":"youtube","name":"YouTube","kind":"Video","description":"Videos and channels","tint":"#2d1719","accent":"#ff7a6b",
   "argv":["flatpak","run","rocks.shy.VacuumTube"]},
  {"id":"plex","name":"Plex","kind":"Video","description":"Movies, shows and live TV","tint":"#2b2513","accent":"#ffc94d",
   "argv":["flatpak","run","tv.plex.PlexHTPC"]},
  {"id":"jellyfin","name":"Jellyfin","kind":"Video","description":"Your media library","tint":"#10262b","accent":"#5fdcea",
   "argv":["flatpak","run","org.jellyfin.JellyfinDesktop","[TV FULLSCREEN ARGS]"]},
  {"id":"netflix","name":"Netflix","kind":"Video","description":"Films and series","tint":"#0f2622","accent":"#3cc4a8",
   "url":"https://www.netflix.com",
   "argv":["firefox","--kiosk","--new-instance","--profile","/home/USER/.local/share/boscamor/profiles/netflix","{url}"]},
  {"id":"prime","name":"Prime Video","kind":"Video","description":"Films and series","tint":"#2b2513","accent":"#ffc94d",
   "url":"https://www.primevideo.com",
   "argv":["firefox","--kiosk","--new-instance","--profile","/home/USER/.local/share/boscamor/profiles/prime","{url}"]},
  {"id":"browser","name":"Browser","kind":"Web","description":"Search and browse the web","tint":"#10262b","accent":"#5fdcea",
   "url":"https://www.google.com","url_editable":true,
   "argv":["firefox","--kiosk","--new-instance","--profile","/home/USER/.local/share/boscamor/profiles/browser","{url}"]},
  {"id":"spotify","name":"Spotify","kind":"Music","description":"Music and podcasts","tint":"#0f2622","accent":"#3cc4a8",
   "argv":["spotify"]},
  {"id":"alarismusic","name":"Alaris Music","kind":"Music","description":"Play music on any speaker in the house","tint":"#2d1719","accent":"#ff7a6b",
   "argv":["flatpak","run","io.music_assistant.Companion"]},
  {"id":"moonlight","name":"Moonlight","kind":"Games","description":"Stream games from your PC","tint":"#2b2513","accent":"#ffc94d",
   "argv":["flatpak","run","com.moonlight_stream.Moonlight"]},
  {"id":"retroarch","name":"RetroArch","kind":"Games","description":"Classic games","tint":"#10262b","accent":"#5fdcea",
   "argv":["flatpak","run","org.libretro.RetroArch"]}
]
```

**Notes for each app**

- **YouTube:** VacuumTube ([Flathub](https://flathub.org/apps/rocks.shy.VacuumTube)) wraps YouTube's TV interface, so no user-agent workaround is needed.
- **Plex:** `tv.plex.PlexHTPC` is Plex's TV-style client ([Flathub](https://flathub.org/apps/tv.plex.PlexHTPC)), not the desktop app.
- **Jellyfin:** Jellyfin Media Player was renamed Jellyfin Desktop ([Linuxiac, Jan 2026](https://linuxiac.com/jellyfin-marks-7-years-with-major-desktop-app-changes/)). The flatpak adds four start-menu entries: Desktop fullscreen, Desktop windowed, TV fullscreen and TV windowed. Use the **TV fullscreen** entry's Exec line as `argv`; `[TV FULLSCREEN ARGS]` above is a placeholder until then.
  - Read it on the box: `grep -B2 -A3 -i 'tv' /var/lib/flatpak/exports/share/applications/org.jellyfin.JellyfinDesktop*.desktop` (for a user install, the same path under `~/.local/share/flatpak/`). The four entries are either separate `.desktop` files or `[Desktop Action]` blocks in one file.
  - Write the real args into the default config and into `RUNBOOK.md`.
- **Netflix, Prime Video, Browser:** `--new-instance` with a per-tile `--profile` keeps each one a separate process. Without them, Firefox hands the URL to any running instance and the launched PID exits at once.
  - Both streaming services need DRM. The installer seeds each profile's `user.js` with `media.eme.enabled` and `media.gmp-widevinecdm.enabled` set to true.
  - Desktop browsers on Linux often get less than 1080p from these services; check quality on the box.
  - Kiosk mode has no address bar and no way out, so Home is the exit.
- **Spotify:** the native package, not a flatpak. The `%U` in its desktop entry is a field code for file arguments, so `argv` is just `["spotify"]`. It is mouse-driven, which is accepted for v1.
- **Alaris Music:** the Music Assistant Companion app, ID `io.music_assistant.Companion`. It is not on Flathub; it ships as a `.flatpak` bundle on its [GitHub releases](https://github.com/music-assistant/desktop-app). The installer downloads the latest bundle, and updates won't come through Flathub. Also mouse-driven, accepted for v1.
- Expand `USER` in paths at load time; JSON has no `~`.
- `argv` runs directly, never through a shell.

## System setup and packaging

One `install.sh` (bash) takes a fresh Mint Cinnamon install to a working box, and is safe to re-run. Deploy with rsync or scp; there is no package.

| What | Where |
| --- | --- |
| Launcher | `/opt/boscamor/boscamor`, one Godot export for Linux x86\_64 with the PCK embedded |
| Daemon | `/opt/boscamor/boscamor-input.py` |
| Launcher autostart | `~/.config/autostart/boscamor.desktop`, full screen on login |
| Daemon service | `~/.config/systemd/user/boscamor-input.service`, `Restart=on-failure`, `WantedBy=graphical-session.target` |
| Config / state | `~/.config/boscamor/apps.json` / `~/.local/state/boscamor/state.json` |
| Browser profiles | `~/.local/share/boscamor/profiles/<id>/` |

**What install.sh does**

1. Installs `wmctrl`, `evtest`, `flatpak` plus the Flathub apps in the default config, Firefox, Spotify, and the Music Assistant Companion bundle from its GitHub releases.
2. Adds the household user to the `input` group.
3. Writes `/etc/systemd/logind.conf.d/boscamor.conf` with `HandlePowerKey=ignore`, so the remote's power button no longer shuts the box down instantly. Optionally adds `HandlePowerKeyLongPress=poweroff` as an emergency path.
4. Turns off Cinnamon's own power-button action (the power plugin's `button-power` setting, set to `nothing`). Check the exact schema key on the target with `gsettings list-recursively | grep -i power`.
5. Checks Cinnamon's media-key bindings for anything on the HomePage, Back or Menu keys and clears it.
6. Enables LightDM auto-login for the household user, pinned to the X11 Cinnamon session (autologin-session=cinnamon, not cinnamon-wayland). After login, the launcher logs XDG\_SESSION\_TYPE and shows a warning in Settings › About if it isn't x11.
7. Copies the files above, enables the user service, and seeds `apps.json` if it doesn't exist. Creates each Firefox kiosk profile with a user.js that turns DRM on. Adds the Return to Bosca Mór shortcut (a .desktop file that runs boscamor-input --return) to the desktop and the Cinnamon menu, and creates the empty \~/.config/boscamor/icons/ folder.

Leave screen blanking to the desktop's settings. The launcher must not inhibit blanking while it sits on Home.

## Build order and acceptance

Build in this order; each step is done when its check passes on the J4105 box, not only on the dev machine.

1. **Skeleton.** Godot project, tokens, bundled fonts, canvas scaling, static Home rendered from `apps.json`.
   - Check: Home matches the design canvas at 1080p, and scales cleanly to 720p and 4K.
2. **Input layer.** InputMap, the three input modes, gamepad repeat, the F12 debug overlay.
   - Check: keyboard, G20S, an Xbox-style pad and a mouse can all move focus and launch. Waving the G20S without clicking never changes focus.
3. **Motion.** Every tween in the motion table, with retargeting.
   - Check: 60 fps with no dropped frames over a 5 s held-direction sweep, per Godot's frame-time monitor.
4. **Sidebar, power confirm, desktop.** Navigation exactly as in the navigation table.
   - Check: every cell of that table behaves as written. Power confirm opens with Cancel focused.
5. **Daemon and IPC.** Token handshake, launch, exit tracking, global Home, Guide and Power.
   - Check: launch Plex, press Home on the remote, Plex exits and the launcher is back within 500 ms. The remote's power button opens the confirm dialog and never shuts down directly.
6. **Idle behaviour.** The hide and show cycle from Resource use.
   - Check: every row of the budgets table, measured on the box.
7. **Settings.** v1 sections: Apps (show or hide, reorder, edit the Browser start page, add from installed `.desktop` entries), Display (UI scale, reduce motion), Controllers (glyph style: auto, Xbox, PlayStation), Startup (start at login), About (version, hostname, IP). Network and Sound open Cinnamon's own settings panels, launched like an app.
   - Check: changes persist to `apps.json` and survive a reboot.
8. **Return to Bosca Mór and icons.** The return flow and Still open screen; the icon lookup order, `icon_style` and the SVG cache.
   - Check: with Firefox (one tab) and a text editor holding unsaved text open, the shortcut closes Firefox, then shows Still open listing the editor. Show me brings its save prompt forward. A `full`-style PNG and an SVG logo both look sharp on a focused tile at 1080p.
9. **Installer.** `install.sh` as in System setup.
   - Check: a fresh Mint install becomes a working box in one run, and a second run changes nothing.
10. **Jellyfin TV mode (deferred to last).** Read the TV fullscreen entry's Exec line on the box and replace `[TV FULLSCREEN ARGS]` in the default config.
    - Check: the Jellyfin tile opens straight into TV fullscreen.

Keep a `RUNBOOK.md` in the repo. Whenever work is deferred, write down what's left to finish there.

## Decisions

| Question | Decision |
| --- | --- |
| Name | Bosca Mór. Never shown in the UI except, if needed, small and understated on a boot splash |
| Should Home close apps? | Yes, all of them, to save power and memory; the apps remember where the viewer was. `keep_on_home` is the opt-out |
| Spotify and Alaris Music are mouse-driven | Accepted for v1, unless a better HTPC client turns up |
| Jellyfin TV mode | Use the flatpak's TV fullscreen entry; read its Exec line on the box |
| Full Cinnamon or a lighter session? | Keep Cinnamon. One app at a time plus the memory watch covers it |
| Wayland | Box runs the latest Cinnamon; pin the X11 session and warn if it isn't x11 |
| G20S voice button | Does nothing |

- [ ] Read the Jellyfin TV fullscreen Exec line on the box and put it in the default config. Deferred to the end, once the app is mostly built; list it in RUNBOOK.md as outstanding until it's done.
