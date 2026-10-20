# Decisions

One line of context per entry. Add new ones at the bottom with the next number, and never renumber.

| # | Decision | Why |
| --- | --- | --- |
| D1 | Godot 4, Compatibility (OpenGL) renderer | Frame-timed tweens and shaders for premium motion; low processor mode gives near-zero idle cost on a J4105 |
| D2 | Daemon is one stdlib Python file | It must see global keys while another app has focus; no pip dependencies on the box |
| D3 | IPC is newline JSON over TCP 127.0.0.1 with a token | Godot 4 has no Unix-socket API; the token stops other local processes driving it |
| D4 | X11 only, with LightDM pinned to the Cinnamon X11 session | Window raising, closing and xprop listing all rely on X11; About warns if the session isn't x11 |
| D5 | Home closes the running app; one app at a time; `keep_on_home` opts out | Saves power and memory, and the apps remember where the viewer was |
| D6 | Return to Bosca Mór closes windows politely and does not log out | The launcher lives in the same session; a logout restarts everything and is slow on the J4105 |
| D7 | Force-close desktop windows with `xkill -id`, never by PID | Flatpak windows can report a sandbox-local PID |
| D8 | The name "Bosca Mór" never appears in the UI | Chief's call; a small, understated boot splash is the only exception |
| D9 | Spotify and Alaris Music (Music Assistant Companion) are mouse-driven and accepted for v1 | No better HTPC clients known yet |
| D10 | Firefox tiles each get `--new-instance` and their own `--profile` | Otherwise Firefox hands the URL to a running instance and the launched PID exits at once |
| D11 | The G20S voice button does nothing | Chief's call |
| D12 | Brand logos are never committed | Trademarks; they go in `~/.config/boscamor/icons/` on the box |
| D13 | Jellyfin uses the flatpak's TV fullscreen entry; args deferred to step 10 | The four start-menu entries exist, but their Exec lines haven't been read yet |
| D14 | Home layout values not in the SPEC tables (paddings, gaps, top bar and hint sizes, `#d6d6e0` status text, `#2a2a3c` key pill) are tokens taken from `Main.dc.html` | The SPEC tables cover the main tokens only; the design canvas holds the rest |
| D15 | DM Sans ships as the static 24pt and 40pt optical-size cuts (googlefonts/dm-fonts), not the variable font; sizes 32 px and up use 40pt | MSDF draws the variable font's overlapping contours with visible artifacts |
| D16 | Pointer mode needs a straight-line move of 40 px from any point the pointer was at in the last 250 ms; the wheel never changes mode; a left click launches only the tile under the pointer | SPEC says "a move of 40 px within 250 ms"; displacement, not path length, ignores gyro jitter that wobbles back and forth |
| D17 | Reduce motion snaps movement (scale, position, rise, nudge) to its end value and plays only fades and colour changes, at half duration | SPEC says "crossfades only, all durations halved" |
| D18 | `launch_requested` fires as the launch zoom starts, `launch_faded` when it ends; Home ignores input until `play_return()` | The daemon can start the app during the fade; a second press must not launch twice |
| D19 | The end-of-carousel nudge moves the whole row 12 px in the pressed direction and back | SPEC names the nudge but not what moves |
| D20 | Held arrow keys repeat on the launcher's own timer (400 ms, then 110 ms), like pads; OS key echo for nav keys is dropped | Chief found OS key repeat too fast on Home; X11 repeats at 25 a second and the G20S sends arrow keys. SPEC said keyboard echo covers keys |
| D21 | The power confirm hides the sidebar, as in `Power.dc.html`; Back or Cancel brings the sidebar back with the blur captured when it first opened. The focused confirm button is filled, the other outlined, as the Still open buttons are. After the action, a black "Shutting down" or "Restarting" screen (the design's off view) ignores all input | The design shows these states; SPEC gives only the navigation |
| D22 | The sidebar blur is a 5x5 Gaussian over the quarter-size capture, radius 3 texels (about 12 px at full size) | SPEC asks for a blur but sets no strength |
| D23 | While on Desktop, the launcher window regaining focus also brings Home back | On the dev machine there is no daemon to send Home; on the box the daemon does it |
| D24 | In pointer mode, hovering a sidebar item or confirm button highlights it at once, without the 120 ms dwell | The dwell guards the tile carousel against air-mouse drift; menus and dialogs only appear after a deliberate press |
