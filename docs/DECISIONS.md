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
| D14 | Dev on Windows (native Godot) plus WSL2 (daemon, installer); the Wyse only runs box checks, in three batches | Chief's Linux machines are low-power; Godot cross-exports Linux builds from Windows |
| D15 | `BOSCAMOR_HOME` and `BOSCAMOR_IPC` / `--dev-port` dev overrides | Keep dev files inside the repo, and let the Windows launcher reach the WSL2 daemon |
| D16 | A Windows build comes after Linux v1 works; OS-specific calls stay in the daemon and `paths.gd` | Chief wants one eventually; keeping screens OS-agnostic makes the port a daemon job, not a rewrite |
