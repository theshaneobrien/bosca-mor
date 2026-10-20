# Daemon fixtures

`proc_bus_input_devices.txt` is synthetic: real field layout, with key bitmaps built from the codes each device would report. Replace it with `cat /proc/bus/input/devices` from the box once the G20S and pad are attached.

`xprop/` is synthetic too: `root.txt` is `xprop -root _NET_CLIENT_LIST`, and each `<wid>.txt` is `xprop -id <wid> _NET_WM_WINDOW_TYPE WM_CLASS _NET_WM_NAME WM_NAME WM_TRANSIENT_FOR`, written in xprop's output format. Replace them with captures from the box (a desktop with Firefox, LibreOffice Writer holding unsaved text and its save prompt, and a text editor). `applications/` holds the matching `.desktop` entries.
