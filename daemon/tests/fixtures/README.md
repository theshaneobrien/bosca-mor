# Daemon fixtures

`proc_bus_input_devices.txt` is synthetic: real field layout, with key bitmaps built from the codes each device would report. Replace it with `cat /proc/bus/input/devices` from the box once the G20S and pad are attached.

`xprop/` is synthetic too: `root.txt` is `xprop -root _NET_CLIENT_LIST`, and each `<wid>.txt` is `xprop -id <wid> _NET_WM_WINDOW_TYPE WM_CLASS _NET_WM_NAME WM_NAME WM_TRANSIENT_FOR`, written in xprop's output format. Replace them with captures from the box (a desktop with Firefox, LibreOffice Writer holding unsaved text and its save prompt, and a text editor). `applications/` holds the matching `.desktop` entries.

`xprop/0x6000003.txt` (a Plex window) and `xprop/0x6200001.txt` (a RetroArch splash) are synthetic app windows that appear after a launch, for the first-window watch (D62). `xprop/0x6000004.txt` is a synthetic Plex dialog, transient for the Plex window.

`xprop/0x6400004.txt` and `xprop/0x6400005.txt` are synthetic Qt frameless windows: Qt lists `_KDE_NET_WM_WINDOW_TYPE_OVERRIDE` before the EWMH type, and Muffin skips it. The first is a main window (then NORMAL), the second a utility window (UTILITY first).
