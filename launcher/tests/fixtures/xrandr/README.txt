box.txt is the box's xrandr --current (report 2026-10-23). The box_verbose*.txt files are synthetic: the box's mode list in xrandr --verbose form, with made-up timings for its two 1920x1080 60.00 modes.

lg_verbose_uhd.txt is the box's real xrandr --verbose (report 2026-10-30, Picture on Automatic), with the output properties and EDID left out. Its two 1920x1080 60.00 Hz modes have the same timing and differ only in sync: 0x5b (-HSync -VSync) shows nothing on the TV, 0x5c (+HSync +VSync, the CEA one) works. lg_verbose.txt is the same list on 0x5c, where the box is at login.

tv_1080p50.txt is synthetic: a 1080p TV that lists 1920x1080 at 50 Hz but not at 60.
