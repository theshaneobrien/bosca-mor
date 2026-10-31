# The TV picture (xrandr) and sound (pactl) helpers, and the Picture keep or
# undo flow in Settings (D79, D80). Commands go to a fake runner; the box's
# own xrandr output is a fixture. On Linux, run_command itself runs printf and ls.
extends "res://tests/test_case.gd"

const Display := preload("res://scripts/display.gd")
const Sound := preload("res://scripts/sound.gd")
const Network := preload("res://scripts/network.gd")
const SystemSetup := preload("res://scripts/system_setup.gd")
const MainScene := preload("res://scenes/main.tscn")
const State := preload("res://scripts/state.gd")
const StateFile := preload("res://scripts/state_file.gd")
const Tokens := preload("res://theme/tokens.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")

const FIX := "res://tests/fixtures/"


## Answers xrandr and pactl from fixtures and records every call.
class FakeRun:
	var calls: Array = []
	var replies := {}        # argv joined with spaces -> {code, out}
	var fail := {}           # argv joined -> exit code

	func call_it(argv: Array, _limit := 0, _stderr := false) -> Dictionary:
		calls.append(argv)
		var key := " ".join(argv)
		if fail.has(key):
			return {"code": fail[key], "out": ""}
		return replies.get(key, {"code": 0, "out": ""})

	func set_out(key: String, path: String) -> void:
		replies[key] = {"code": 0, "out": FileAccess.get_file_as_string(path)}

	func ran(argv: Array) -> bool:
		return calls.has(argv)


static func _read(name: String) -> String:
	return FileAccess.get_file_as_string(FIX + name)


# Display ----------------------------------------------------------------------

func test_parse_the_box() -> void:
	var outs := Display.parse(_read("xrandr/box.txt"))
	eq(outs.size(), 5, "five outputs")
	var o := Display.pick_output(outs)
	eq(o.name, "DP-1", "the TV")
	check(o.primary, "primary")
	eq(o.current, {"w": 1920, "h": 1080, "hz": 60.0}, "current mode")
	check(Display.is_mode(o.current, "1920x1080@60"), "already 1080p60")
	eq(Display.plan(o, "1920x1080@60"), [], "nothing to do")
	eq(Display.plan(o, "1280x720@60"), [["xrandr", "--output", "DP-1", "--mode", "1280x720", "--rate", "60.00"]], "720p is in the list")
	eq(Display.plan(o, "auto"), [["xrandr", "--output", "DP-1", "--auto"]], "auto")
	var names: Array = o.modes.map(func(m): return m.name)
	check(not names.has("1920x1080i"), "interlaced modes skipped")
	eq(o.modes[0].rates[0], "60.00", "a lone + is not a rate")


func test_parse_verbose() -> void:
	var o := Display.pick_output(Display.parse(_read("xrandr/box_verbose.txt")))
	eq(o.name, "DP-1", "the TV")
	eq(o.current, {"w": 1920, "h": 1080, "hz": 60.0, "id": "0x4a"}, "current, with its id")
	var ids: Array = o.modes.map(func(m): return m.id)
	check(not ids.has("0x52"), "interlaced left out")
	var sixty: Array = o.modes.filter(func(m): return m.w == 1920 and m.rates == ["60.00"])
	eq(sixty.map(func(m): return m.id), ["0x50", "0x4a"], "two timings at 60.00 Hz, as on the box")
	eq(sixty[1].htotal, 2200, "h total")
	eq(sixty[1].vtotal, 1125, "v total")
	eq(Display.choose(o, "1920x1080@60"), {"name": "1920x1080", "rate": "60.00", "cea": true, "id": "0x4a"}, "the CEA one, not the first")
	eq(Display.plan(o, "1920x1080@60"), [], "already on it")
	eq(Display.plan(o, "1280x720@60"), [["xrandr", "--output", "DP-1", "--mode", "0x55"]], "720p by id, not 59.94")
	eq(Display.timing(o, "0x4a"), "1920x1080 0x4a 148.50 MHz 2200x1125 +HSync +VSync 60.00 Hz", "for the log")
	eq(Display.timings(o, "1920x1080@60").size(), 4, "every 1080p timing in the log")


func test_right_size_and_rate_but_the_other_timing() -> void:
	# What the third box test may have been: 1080p at 60 Hz as far as X is
	# concerned, but not the timing the TV takes (D83).
	var o := Display.pick_output(Display.parse(_read("xrandr/box_verbose_rb.txt")))
	eq(o.current.id, "0x50", "on the other 60.00 Hz timing")
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "DP-1", "--mode", "0x4a"]], "moved to the CEA one")
	eq(Display.plan(o, "1920x1080@60", false), [], "but not when the launcher comes back: it may be working after a replug")
	o = Display.pick_output(Display.parse(_read("xrandr/box_verbose_uhd.txt")))
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "DP-1", "--mode", "0x4a"]], "from 4K too")


func test_the_box_keeps_the_cea_sync() -> void:
	# The box's real list (D101): 0x5b and 0x5c have the same timing, and only
	# 0x5c (+HSync +VSync) shows a picture. At login it is already on 0x5c.
	var o := Display.pick_output(Display.parse(_read("xrandr/lg_verbose.txt")))
	eq(o.current.id, "0x5c", "on the CEA one at login")
	var sixty: Array = o.modes.filter(func(m): return m.w == 1920 and m.rates == ["60.00"])
	eq(sixty.map(func(m): return [m.id, m.sync]), [["0x5b", "-HSync -VSync"], ["0x5c", "+HSync +VSync"]], "sync read")
	eq(Display.choose(o, "1920x1080@60"), {"name": "1920x1080", "rate": "60.00", "cea": true, "id": "0x5c"}, "not the first")
	eq(Display.plan(o, "1920x1080@60"), [], "left alone at login")
	eq(Display.plan(o, "1280x720@60"), [["xrandr", "--output", "DP-1", "--mode", "0x69"]], "720p")
	var bad := _read("xrandr/lg_verbose.txt").replace(" *current", "").replace(
		"(0x5b) 148.500MHz -HSync -VSync", "(0x5b) 148.500MHz -HSync -VSync *current")
	o = Display.pick_output(Display.parse(bad))
	eq(o.current.id, "0x5b", "on the one that shows nothing")
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "DP-1", "--mode", "0x5c"]], "moved to the CEA one")
	o = Display.pick_output(Display.parse(_read("xrandr/lg_verbose_uhd.txt")))
	eq(o.current.id, "0x47", "4K after Automatic")
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "DP-1", "--mode", "0x5c"]], "from 4K")
	eq(Display.timing(o, "0x5b"), "1920x1080 0x5b 148.50 MHz 2200x1125 -HSync -VSync 60.00 Hz", "sync in the log")


func test_the_wrong_sync_loses_to_the_nearest_rate() -> void:
	# Without the CEA one, 59.94 Hz with the CEA sync beats 60.00 with the
	# other sync.
	var text := _read("xrandr/lg_verbose.txt").replace("(0x5c) 148.500MHz +HSync +VSync *current", "(0x5c) 148.500MHz +HSync -VSync")
	var o := Display.pick_output(Display.parse(text))
	eq(Display.choose(o, "1920x1080@60").get("id"), "0x5e", "59.94 Hz, +HSync +VSync")


func test_same_timing_under_another_id_is_left_alone() -> void:
	# A copy of the CEA timing (made with --newmode on an earlier login, say)
	# is the same picture: setting the other id would only blank the TV.
	var copy := "  1920x1080_60 (0x80) 148.500MHz +HSync +VSync *current\n" \
		+ "        h: width  1920 start 2008 end 2052 total 2200 skew    0 clock  67.50KHz\n" \
		+ "        v: height 1080 start 1084 end 1089 total 1125           clock  60.00Hz\n"
	var text := _read("xrandr/lg_verbose.txt").replace(" *current", "").replace("HDMI-1 disconnected", copy + "HDMI-1 disconnected")
	var o := Display.pick_output(Display.parse(text))
	eq(o.current.id, "0x80", "on the copy")
	eq(Display.plan(o, "1920x1080@60"), [], "left alone")


func test_a_tv_without_60_hz_uses_its_own_rate() -> void:
	# A 1080p TV that lists 50 Hz but not 60: its own 50 Hz, not a made-up
	# 60 Hz mode it may not show (D101). 24 Hz is too slow to count.
	var o := Display.pick_output(Display.parse(_read("xrandr/tv_1080p50.txt")))
	eq(o.name, "HDMI-1", "the TV")
	eq(Display.choose(o, "1920x1080@60"), {"name": "1920x1080", "rate": "50.00", "cea": false, "id": "0x48"}, "50 Hz")
	eq(Display.plan(o, "1920x1080@60"), [], "already on it")
	eq(Display.plan(o, "1280x720@60"), [["xrandr", "--output", "HDMI-1", "--mode", "0x4b"]], "720p at 60, not 50")
	var on_720 := _read("xrandr/tv_1080p50.txt").replace(" *current +preferred", " +preferred").replace(
		"(0x4b) 74.250MHz +HSync +VSync", "(0x4b) 74.250MHz +HSync +VSync *current")
	o = Display.pick_output(Display.parse(on_720))
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "HDMI-1", "--mode", "0x48"]], "back to 1080p50")
	var slow := _read("xrandr/tv_1080p50.txt").replace("(0x48) 148.500MHz", "(0x48) 74.250MHz").replace(
		"total 1125           clock  50.00Hz", "total 1125           clock  25.00Hz")
	o = Display.pick_output(Display.parse(slow))
	eq(Display.choose(o, "1920x1080@60"), {}, "1080p only at 25 and 24 Hz: none")


## The list as X shows it once the installer's xorg.conf.d file is in (D105):
## the start mode first, current, and marked preferred with the TV's own.
static func _started(text: String, output: String) -> String:
	var start := "  %s (0x1e1) 148.500MHz +HSync +VSync *current +preferred\n" % Display.START_MODE \
		+ "        h: width  1920 start 2008 end 2052 total 2200 skew    0 clock  67.50KHz\n" \
		+ "        v: height 1080 start 1084 end 1089 total 1125           clock  60.00Hz"
	var lines := text.replace(" *current", "").split("\n")
	for i in lines.size():
		if lines[i].begins_with(output + " connected"):
			lines.insert(i + 1, start)
			break
	return "\n".join(lines)


func test_x_starts_on_the_start_mode() -> void:
	# Fifth box report, 31 Oct: X started the LG at its own 4K, and restarts
	# came up with no signal (FIFO underruns at 4K). Now X starts on the CEA
	# 1080p60 timing under our name, and the launcher has nothing to do (D105).
	var o := Display.pick_output(Display.parse(_started(_read("xrandr/lg_verbose.txt"), "DP-1")))
	eq(o.current.id, "0x1e1", "X started on it")
	eq(o.modes[0].name, Display.START_MODE, "listed first")
	check(o.modes[0].preferred, "marked preferred")
	eq(Display.choose(o, "1920x1080@60").get("id"), "0x5c", "the TV's own CEA mode, not ours")
	eq(Display.plan(o, "1920x1080@60"), [], "the same timing: nothing to do at login")
	eq(Display.plan(o, "1920x1080@60", false), [], "nor on the way back from an app")
	eq(Display.plan(o, "1280x720@60"), [["xrandr", "--output", "DP-1", "--mode", "0x69"]], "720p")
	eq(Display.plan(o, "auto"), [["xrandr", "--output", "DP-1", "--mode", "0x47"]], "Automatic: the TV's own 4K, past ours")
	o = Display.pick_output(Display.parse(_read("xrandr/lg_verbose_uhd.txt")))
	eq(Display.plan(o, "auto"), [], "Automatic, already on the TV's own")
	o = Display.pick_output(Display.parse(_read("xrandr/lg_verbose.txt")))
	eq(Display.plan(o, "auto"), [["xrandr", "--output", "DP-1", "--mode", "0x47"]], "Automatic from 1080p")


func test_a_tv_without_60_hz_moves_off_the_start_mode() -> void:
	# The start mode is 60 Hz whatever the TV: one that lists 1080p only at
	# 50 Hz still gets its own (D101).
	var o := Display.pick_output(Display.parse(_started(_read("xrandr/tv_1080p50.txt"), "HDMI-1")))
	eq(o.current.id, "0x1e1", "X started on it")
	eq(Display.choose(o, "1920x1080@60").get("id"), "0x48", "its own 50 Hz, not our 60")
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "HDMI-1", "--mode", "0x48"]], "moved")
	eq(Display.plan(o, "auto"), [["xrandr", "--output", "HDMI-1", "--mode", "0x48"]], "Automatic: its own preferred")


func test_ensure_logs_what_it_saw() -> void:
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/box_verbose_rb.txt")
	f.set_out("xrandr --verbose --current", FIX + "xrandr/box_verbose_rb.txt")
	check(not Display.ensure("1920x1080@60", f.call_it, false).changed, "coming back: left alone")
	var r := Display.ensure("1920x1080@60", f.call_it, true)
	check(r.ok and r.changed, "changed")
	eq(r.was, "1920x1080 0x50 133.32 MHz 2000x1111 +HSync -VSync 60.00 Hz", "what it was on")
	eq(r.steps, [["xrandr", "--output", "DP-1", "--mode", "0x4a"]], "what it ran")
	check(r.modes.size() == 4, "the list it chose from")


func test_wrong_mode_at_boot() -> void:
	var o := Display.pick_output(Display.parse(_read("xrandr/uhd.txt")))
	eq(o.current.hz, 30.0, "4K at 30 Hz")
	eq(Display.plan(o, "1920x1080@60"), [["xrandr", "--output", "DP-1", "--mode", "1920x1080", "--rate", "60.00"]], "set 1080p60")


func test_no_mode_list_adds_the_cea_timing() -> void:
	var o := Display.pick_output(Display.parse(_read("xrandr/no_edid.txt")))
	eq(o.name, "DP-1", "the built-in panel is never the TV")
	var steps := Display.plan(o, "1920x1080@60")
	eq(steps.size(), 3, "newmode, addmode, output")
	eq(steps[0].slice(0, 4), ["xrandr", "--newmode", "1920x1080_60", "148.50"], "CEA 1080p60")
	eq(steps[1], ["xrandr", "--addmode", "DP-1", "1920x1080_60"], "added to the TV")
	eq(steps[2], ["xrandr", "--output", "DP-1", "--mode", "1920x1080_60"], "and set")


func test_ensure_falls_back_to_720p() -> void:
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/no_edid.txt")
	f.fail["xrandr --output DP-1 --mode 1920x1080_60"] = 1
	f.fail["xrandr --newmode 1280x720_60 " + " ".join(Display.CEA["1280x720@60"])] = 1   # made earlier: carry on
	var r := Display.ensure("1920x1080@60", f.call_it)
	check(r.ok, "720p took")
	check(r.fallback, "fell back")
	eq(r.mode, "1280x720@60", "720p")
	check(f.ran(["xrandr", "--output", "DP-1", "--mode", "1280x720_60"]), "720p set")


func test_ensure_without_a_screen() -> void:
	var f := FakeRun.new()
	f.replies["xrandr --verbose --current"] = {"code": 0, "out": "Screen 0: minimum 320 x 200\nHDMI-1 disconnected (normal)\n"}
	var r := Display.ensure("1920x1080@60", f.call_it, false)
	check(not r.ok, "nothing to set")
	eq(r.error, "no screen found", "said why")
	f.fail["xrandr --verbose"] = 127
	check(not Display.ensure("1920x1080@60", f.call_it).ok, "no xrandr")


func test_describe() -> void:
	eq(Display.describe("1920x1080@60"), "1920 x 1080 at 60 Hz", "mode")
	eq(Display.describe("auto"), "Automatic", "auto")


# Sound ------------------------------------------------------------------------

func test_parse_cards() -> void:
	var cards := Sound.parse_cards(_read("pactl/cards.txt"))
	eq(cards.size(), 1, "one card")
	var c: Dictionary = cards[0]
	eq(c.name, "alsa_card.pci-0000_00_0e.0", "name")
	eq(c.description, "Built-in Audio", "description")
	eq(c.active, "output:analog-stereo+input:analog-stereo", "active profile")
	eq(c.profiles.size(), 9, "profiles, not ports")
	eq(Sound.profile_description(c, "output:hdmi-stereo"), "Digital Stereo (HDMI) Output", "description keeps its brackets")
	check(not c.profiles[3].available, "HDMI 1 has nothing on it")
	check(not Sound.is_hdmi("output:hdmi-stereo-extra1+input:analog-stereo"), "a socket's duplex twin is not another socket")
	eq(Sound.choose_profile(c), "output:hdmi-stereo-extra1", "the one socket with a TV, though its duplex twin is live too")
	for p in c.profiles:
		if p.name == "output:hdmi-stereo-extra1":
			p.available = false
	eq(Sound.choose_profile(c), Sound.HDMI, "none say: Digital Stereo (HDMI) Output")
	eq(Sound.output_of("output:hdmi-stereo+input:analog-stereo"), "output:hdmi-stereo", "output half")


func test_sound_ensure_sets_hdmi_and_volume() -> void:
	var f := FakeRun.new()
	f.set_out("pactl list cards", FIX + "pactl/cards.txt")
	f.set_out("pactl list short sinks", FIX + "pactl/short_sinks_hdmi2.txt")
	f.set_out("pactl info", FIX + "pactl/info.txt")
	var r := Sound.ensure("hdmi", 100, f.call_it)
	check(r.ok, "ok: %s" % [r])
	check(r.changed, "changed")
	var sink := "alsa_output.pci-0000_00_0e.0.hdmi-stereo-extra1"
	check(f.ran(["pactl", "set-card-profile", "alsa_card.pci-0000_00_0e.0", "output:hdmi-stereo-extra1"]), "profile")
	check(f.ran(["pactl", "set-default-sink", sink]), "default output")
	check(f.ran(["pactl", "set-sink-volume", sink, "100%"]), "volume 100%")
	check(f.ran(["pactl", "set-sink-mute", sink, "0"]), "unmuted")
	eq(r.playing, "Digital Stereo (HDMI 2) Output, Built-in Audio", "what Settings shows")
	# Already on that socket's duplex profile: it plays through the TV, so it stays.
	f = FakeRun.new()
	f.replies["pactl list cards"] = {"code": 0, "out": _read("pactl/cards.txt").replace(
		"Active Profile: output:analog-stereo+input:analog-stereo", "Active Profile: output:hdmi-stereo-extra1+input:analog-stereo")}
	f.set_out("pactl list short sinks", FIX + "pactl/short_sinks_hdmi2.txt")
	check(Sound.ensure("hdmi", -1, f.call_it).ok, "ok")
	check(f.calls.all(func(c): return c[1] != "set-card-profile"), "profile left alone")


func test_sound_waits_for_the_hdmi_sink() -> void:
	var f := FakeRun.new()
	f.set_out("pactl list cards", FIX + "pactl/cards.txt")
	f.set_out("pactl list short sinks", FIX + "pactl/short_sinks.txt")
	var r := Sound.ensure("hdmi", -1, f.call_it)
	check(not r.ok, "no HDMI sink yet: try again later")
	f.fail["pactl list cards"] = 1
	eq(Sound.ensure("hdmi", 100, f.call_it).error, "no sound server", "no pactl")


func test_sound_auto_only_sets_the_volume() -> void:
	var f := FakeRun.new()
	f.set_out("pactl list cards", FIX + "pactl/cards.txt")
	var r := Sound.ensure("auto", 75, f.call_it)
	check(r.ok, "ok")
	check(f.ran(["pactl", "set-sink-volume", "@DEFAULT_SINK@", "75%"]), "volume on whatever plays")
	for c in f.calls:
		check(c[1] != "set-card-profile" and c[1] != "set-default-sink", "output left alone: %s" % [c])


# SystemSetup ------------------------------------------------------------------

func _setup_node(f: FakeRun) -> Node:
	var s: Node = SystemSetup.new()
	s.enabled = true
	s.threaded = false
	s.run = f.call_it
	tree.root.add_child(s)
	return s


func test_login_checks_and_volume_once() -> void:
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/box_verbose_uhd.txt")
	f.set_out("pactl list cards", FIX + "pactl/cards.txt")
	f.set_out("pactl list short sinks", FIX + "pactl/short_sinks_hdmi2.txt")
	f.set_out("pactl info", FIX + "pactl/info.txt")
	var s := _setup_node(f)
	s.start()
	check(f.ran(["xrandr", "--output", "DP-1", "--mode", "0x4a"]), "the CEA 1080p60 at login")
	check(s.display.ok, "picture ok")
	eq(f.calls.filter(func(c): return c[1] == "set-sink-volume").size(), 1, "volume set")
	s._on_boot_timer()
	eq(f.calls.filter(func(c): return c[1] == "set-sink-volume").size(), 1, "volume only once, so a change on the TV remote sticks")
	check(f.calls.filter(func(c): return c == ["xrandr", "--verbose"]).size() == 2, "checked again")
	for i in Tokens.SETUP_BOOT_CHECKS + 2:
		s._on_boot_timer()
	check(s._timer.is_stopped(), "stops after the first 30 s")
	s.free()


func test_auto_keeps_the_tvs_own_mode() -> void:
	# Automatic is the TV's own preferred mode, at login too: X now starts on
	# the start mode (D105), so the check may have to move it there.
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/lg_verbose_uhd.txt")
	var s := _setup_node(f)
	s.configure({"display_mode": "auto", "sound_output": "auto", "volume": 100})
	s.check(true)
	eq(f.calls.filter(func(c): return c[0] == "xrandr" and c[1] == "--output"), [], "on the TV's own 4K: left alone")
	f.replies["xrandr --verbose"] = {"code": 0, "out": _started(_read("xrandr/lg_verbose_uhd.txt"), "DP-1")}
	s.check(true)
	check(f.ran(["xrandr", "--output", "DP-1", "--mode", "0x47"]), "from the start mode to the TV's own")
	s.free()


func test_off_the_box_nothing_runs() -> void:
	var f := FakeRun.new()
	var s := _setup_node(f)
	s.enabled = false
	s.start()
	s.check()
	eq(f.calls, [], "no commands")
	s.free()


func test_headless_runs_nothing() -> void:
	# Review: on Windows the old check passed whatever the gate said, and
	# `godot --path launcher` on a Linux desktop really ran xrandr and pactl.
	check(SystemSetup.can_run("Linux", ":0", "X11", true), "the exported build on the box")
	check(not SystemSetup.can_run("Linux", ":0", "X11", false), "godot --path on a Linux desktop, and shots")
	check(not SystemSetup.can_run("Linux", ":0", "headless", true), "headless")
	check(not SystemSetup.can_run("Linux", "", "X11", true), "no X display")
	check(not SystemSetup.can_run("Windows", ":0", "Windows", true), "not Linux")
	# Tests never run from an exported build, so no test starts a real job
	# before its fake runner, on any machine.
	var s: Node = SystemSetup.new()
	check(not s.enabled, "off in the tests")
	s.free()


func test_a_waiting_check_stays_strict() -> void:
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/box_verbose.txt")
	f.set_out("xrandr --verbose --current", FIX + "xrandr/box_verbose.txt")
	var s := _setup_node(f)
	s._thread = Thread.new()          # stands in for a Wi-Fi scan on the worker
	s.check()                         # the launcher came back
	s.check(true)                     # then a check from the first 30 s
	eq(s._queue.size(), 1, "one check waiting")
	check(s._queue[0].probe, "and it reads the TV again")
	s._thread = null
	s._next()
	check(f.ran(["xrandr", "--verbose"]), "strict")
	check(not f.ran(["xrandr", "--verbose", "--current"]), "not only what X knows")
	s.free()


# run_command --------------------------------------------------------------------

## Every line printed while it is added.
class Lines extends Logger:
	var lines: Array[String] = []
	var _mutex := Mutex.new()

	func _log_message(message: String, _error: bool) -> void:
		_mutex.lock()
		lines.append(message)
		_mutex.unlock()

	func text() -> String:
		_mutex.lock()
		var t := "".join(lines)
		_mutex.unlock()
		return t


static func _set_dry_run(value: String) -> String:
	var old := OS.get_environment("BOSCAMOR_DRY_RUN")
	if value.is_empty():
		OS.unset_environment("BOSCAMOR_DRY_RUN")
	else:
		OS.set_environment("BOSCAMOR_DRY_RUN", value)
	return old


func test_dry_run_logs_changes_and_hides_passwords() -> void:
	var old := _set_dry_run("1")
	var log_lines := Lines.new()
	OS.add_logger(log_lines)
	var r := SystemSetup.run_command(["nmcli", "--wait", "40", "device", "wifi", "connect", "Cafe", "password", "hunter22$"],
		Tokens.WIFI_CONNECT_TIMEOUT, true)
	SystemSetup.run_command(["nmcli", "connection", "modify", "id", "Old Flat", "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", "newpass1"])
	SystemSetup.run_command(["xrandr", "--output", "DP-1", "--mode", "0x4a"])
	var p := SystemSetup.run_command(["printf", "ran"])
	OS.remove_logger(log_lines)
	_set_dry_run(old)
	eq(r, {"code": 0, "out": ""}, "logged, not run")
	eq(p.out, "", "nothing unknown runs either")
	var text := log_lines.text()
	check(text.contains("dry run: nmcli --wait 40 device wifi connect Cafe password (hidden)"), "says what it would run: %s" % text)
	check(text.contains("dry run: xrandr --output DP-1 --mode 0x4a"), "picture changes too")
	check(not text.contains("hunter22") and not text.contains("newpass1"), "never the password")
	for argv in [["xrandr", "--verbose"], ["xrandr", "--verbose", "--current"], ["pactl", "list", "cards"],
			["pactl", "list", "short", "sinks"], ["pactl", "info"],
			["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"],
			["nmcli", "-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi", "list", "--rescan", "yes"],
			["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"]]:
		check(SystemSetup.reads_only(argv), "a dry run still reads: %s" % [argv])
	for argv in [["xrandr", "--output", "DP-1", "--auto"], ["xrandr", "--newmode", "x"], ["pactl", "set-sink-volume", "@DEFAULT_SINK@", "100%"],
			["nmcli", "--wait", "40", "connection", "up", "id", "show"], ["nmcli", "--wait", "40", "device", "wifi", "connect", "list"]]:
		check(not SystemSetup.reads_only(argv), "a change, whatever the network is called: %s" % [argv])


func test_run_command_has_no_shell() -> void:
	if OS.get_name() != "Linux":
		return             # xrandr, pactl and nmcli only run on Linux
	var old := _set_dry_run("")
	var log_lines := Lines.new()
	OS.add_logger(log_lines)
	var odd := "a\"b $HOME `echo X` back\\slash \"; echo INJECTED; \" 'q' $(echo Y) hunter22"
	var r := SystemSetup.run_command(["printf", "[%s]", odd])
	var e := SystemSetup.run_command(["ls", "/boscamor-no-such-file"], Tokens.SETUP_CMD_TIMEOUT, true)
	var quiet := SystemSetup.run_command(["ls", "/boscamor-no-such-file"])
	var missing := SystemSetup.run_command(["boscamor-no-such-command"])
	OS.remove_logger(log_lines)
	_set_dry_run(old)
	eq(r.code, 0, "ran")
	eq(r.out, "[" + odd + "]", "every byte as given: no shell")
	check(e.code != 0 and e.out.contains("No such file"), "stderr when asked: %s" % [e])
	eq(quiet.out, "", "and not otherwise")
	eq(missing.code, 127, "not found")
	check(not log_lines.text().contains("hunter22"), "nothing logged it")


# Settings: Picture, keep or undo ------------------------------------------------

var main: Control
var dir: String
var fake: FakeRun


func _start() -> void:
	dir = ProjectSettings.globalize_path("user://test-system-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	main = MainScene.instantiate()
	main.apps_path = "res://tests/fixtures/apps_minimal.json"
	main.state_path = dir.path_join("state.json")
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	main.daemon.stand_in = true     # the no-daemon stand-in on every OS (D66 keeps it off Linux)
	fake = FakeRun.new()
	fake.set_out("xrandr --verbose", FIX + "xrandr/box_verbose.txt")
	main.setup.enabled = true
	main.setup.threaded = false
	main.setup.run = fake.call_it
	main.setup.check(true)
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		im._set_mode(InputModeScript.Mode.REMOTE)
		im.release_all()
	await tree.process_frame
	main.state.go(State.Screen.SETTINGS)
	_act("nav_down")         # Display
	_act("nav_right")


func _end() -> void:
	main.free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _act(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	tree.root.push_input(a, true)


const TO_720 := ["xrandr", "--output", "DP-1", "--mode", "0x55"]


func test_picture_change_asks_to_keep() -> void:
	await _start()
	var st: Control = main.settings
	eq(st._current().key, "display_mode", "Picture row")
	eq(st._current().value, "1920 x 1080 at 60 Hz", "1080p by default")
	eq(st._items[1].label, "Screen", "what the TV is on")
	eq(st._items[1].value, "DP-1, 1920 x 1080 at 60 Hz", "from xrandr")
	_act("accept")
	check(fake.ran(TO_720), "720p tried")
	eq(main.state.screen, State.Screen.CONFIRM, "asks to keep it")
	eq(main.state.confirm_kind, "picture", "picture confirm")
	eq(main.state.confirm_focus, 0, "Cancel focused (Law 2)")
	eq(main.confirm._title.text, "Keep this picture?", "title")
	eq(main.confirm._body.text, "It goes back to the last one in %d seconds." % int(Tokens.PICTURE_KEEP), "body")
	eq(main.setup.display_mode, "1280x720@60", "checks hold the new one while it is tried")
	_act("nav_right")
	_act("accept")
	eq(main.state.screen, State.Screen.SETTINGS, "back in Settings")
	eq(st.level, "content", "where it was")
	eq(StateFile.load_file(main.state_path).get("display_mode"), "1280x720@60", "kept and saved")
	eq(st._current().value, "1280 x 720 at 60 Hz", "row shows it")
	_end()


func test_picture_cancel_goes_back() -> void:
	await _start()
	_act("accept")
	fake.calls.clear()
	fake.replies["xrandr --verbose"] = {"code": 0, "out": _read("xrandr/box_verbose.txt").replace(" *current", "").replace(
		"(0x55) 74.250MHz +HSync +VSync", "(0x55) 74.250MHz +HSync +VSync *current")}
	_act("accept")             # Cancel
	eq(main.state.screen, State.Screen.SETTINGS, "back in Settings")
	check(fake.ran(["xrandr", "--output", "DP-1", "--mode", "0x4a"]), "old picture back")
	eq(main.setup.display_mode, "1920x1080@60", "checks hold the old one")
	eq(StateFile.load_file(main.state_path).get("display_mode", "unset"), "unset", "nothing saved")
	_end()


func test_picture_goes_back_on_its_own() -> void:
	await _start()
	_act("accept")
	eq(main.state.screen, State.Screen.CONFIRM, "asking")
	check(not main._picture_timer.is_stopped(), "timer running")
	eq(main._picture_timer.wait_time, Tokens.PICTURE_KEEP, "15 s")
	main._picture_timer.timeout.emit()
	eq(main.state.screen, State.Screen.SETTINGS, "gave up waiting")
	eq(main.setup.display_mode, "1920x1080@60", "old picture")
	eq(main._picture_old, "", "trial over")
	_end()


func test_picture_home_goes_back() -> void:
	await _start()
	_act("accept")
	_act("home")
	eq(main.state.screen, State.Screen.HOME, "Home")
	eq(main.setup.display_mode, "1920x1080@60", "old picture")
	_end()


func test_picture_failure_toasts() -> void:
	await _start()
	fake.fail[" ".join(TO_720)] = 1
	_act("accept")
	eq(main.state.screen, State.Screen.SETTINGS, "no confirm")
	eq(main.toast.text, "Couldn't change the picture", "toast")
	eq(main.setup.display_mode, "1920x1080@60", "unchanged")
	_end()


func test_threaded_job_finishes() -> void:
	var f := FakeRun.new()
	f.set_out("xrandr --verbose", FIX + "xrandr/box_verbose.txt")
	var s := _setup_node(f)
	s.threaded = true
	s.check(true)
	s.wifi_scan()
	for i in 200:
		if not s.busy():
			break
		await tree.process_frame
	check(not s.busy(), "both jobs done")
	check(s.display.get("ok", false), "picture checked on the worker")
	check(s.wifi.has("ok"), "then the scan")
	s.free()


# Wi-Fi --------------------------------------------------------------------------

func test_nmcli_parse() -> void:
	eq(Network.split_terse("a\\:b:c"), ["a:b", "c"] as Array[String], "escaped colon")
	var saved := Network.parse_saved(_read("nmcli/saved.txt"))
	eq(saved, ["HomeNet", "Old Flat"], "Wi-Fi profiles only")
	var nets := Network.parse_list(_read("nmcli/wifi_list.txt"), saved)
	eq(nets.map(func(n): return n.ssid), ["HomeNet", "Upstairs:5G", "Old Flat", "Cafe Free", "Work"], "connected first, one each, hidden left out")
	check(nets[0].in_use and nets[0].known, "HomeNet connected and saved")
	eq(nets[0].signal, 82, "strongest of its two")
	check(not nets[3].secure, "Cafe Free is open")
	check(nets[4].enterprise, "Work needs a sign-in")
	eq(Network.words(nets[0]), "Connected", "connected")
	eq(Network.words(nets[1]), "Good", "secured, not saved")
	eq(Network.words(nets[2]), "Saved, good", "saved")
	eq(Network.words(nets[3]), "Open, good", "open")
	var dev := Network.parse_devices(_read("nmcli/devices.txt"))
	eq(dev, {"has_wifi": true, "wifi": "HomeNet", "wired": false}, "devices")


func _nmcli(f: FakeRun) -> void:
	f.set_out("nmcli -t -f TYPE,STATE,CONNECTION device", FIX + "nmcli/devices.txt")
	f.set_out("nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan auto", FIX + "nmcli/wifi_list.txt")
	f.set_out("nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan yes", FIX + "nmcli/wifi_list.txt")
	f.set_out("nmcli -t -f NAME,TYPE connection show", FIX + "nmcli/saved.txt")


func test_scan_and_join() -> void:
	var f := FakeRun.new()
	_nmcli(f)
	var w := Network.scan(f.call_it)
	check(w.ok, "ok")
	eq(w.connected, "HomeNet", "connected to")
	eq(w.networks.size(), 5, "networks")
	var wait := str(Tokens.WIFI_CONNECT_TIMEOUT - 5)
	var r := Network.join("Upstairs:5G", "hunter22", false, f.call_it)
	check(r.ok, "joined")
	check(f.ran(["nmcli", "--wait", wait, "device", "wifi", "connect", "Upstairs:5G", "password", "hunter22"]), "new network")
	f.replies["nmcli --wait %s connection up id Old Flat" % wait] = {"code": 4,
		"out": "Error: Connection activation failed: Secrets were required, but not provided.
"}
	r = Network.join("Old Flat", "", true, f.call_it)
	check(not r.ok, "saved password stopped working")
	eq(r.error, "password", "said so")
	check(not r.tried_password, "so it asks for one")
	f.calls.clear()
	Network.join("Old Flat", "newpass1", true, f.call_it)
	eq(f.calls[0], ["nmcli", "connection", "modify", "id", "Old Flat", "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", "newpass1"], "new password saved")
	eq(f.calls[1], ["nmcli", "--wait", wait, "connection", "up", "id", "Old Flat"], "then up")
	f.fail["nmcli -t -f TYPE,STATE,CONNECTION device"] = 8
	check(not Network.scan(f.call_it).ok, "no NetworkManager")


func _to_network() -> void:
	main.state.go(State.Screen.HOME)
	main.state.go(State.Screen.SETTINGS)
	for i in 2:
		_act("nav_down")
	_act("nav_right")


func test_settings_wifi_rows() -> void:
	await _start()
	_nmcli(fake)
	_to_network()
	var st: Control = main.settings
	eq(st.section_id(), "network", "Network")
	eq(st._items[0].value, "HomeNet", "connected to")
	eq(st._items.map(func(it): return it.label), ["Connected to", "HomeNet", "Upstairs:5G", "Old Flat", "Cafe Free", "Work", "Search again", "Open network settings"], "rows")
	_act("nav_down")
	eq(st.hint_words(), ["Back"], "nothing to do on the connected one")
	_act("nav_down")
	_act("accept")
	check(st.osk().visible, "keyboard for the password")
	eq(st.osk()._title.text, "Password for Upstairs:5G", "names the network")
	st.osk().close()
	st._on_osk_done("hunter22")
	check(fake.ran(["nmcli", "--wait", str(Tokens.WIFI_CONNECT_TIMEOUT - 5), "device", "wifi", "connect", "Upstairs:5G", "password", "hunter22"]), "joined")
	eq(main.toast.text, "Connected to Upstairs:5G", "toast")
	eq(st._current().label, "Upstairs:5G", "focus stays on the row after the list reloads")
	_end()


func test_settings_wifi_saved_password_fails() -> void:
	await _start()
	_nmcli(fake)
	fake.replies["nmcli --wait %s connection up id Old Flat" % str(Tokens.WIFI_CONNECT_TIMEOUT - 5)] = {"code": 4,
		"out": "Error: Connection activation failed: Secrets were required, but not provided.
"}
	_to_network()
	var st: Control = main.settings
	for i in 3:
		_act("nav_down")
	eq(st._current().label, "Old Flat", "a saved network")
	_act("accept")
	check(st.osk().visible, "asks for the password again")
	eq(st.osk()._title.text, "Password for Old Flat", "names it")
	_end()


func test_settings_wifi_enterprise_and_open() -> void:
	await _start()
	_nmcli(fake)
	_to_network()
	var st: Control = main.settings
	for i in 5:
		_act("nav_down")
	eq(st._current().label, "Work", "work network")
	_act("accept")
	eq(main.toast.text, "Open network settings to join Work", "can't do 802.1X here")
	_act("nav_up")
	_act("accept")
	check(not st.osk().visible, "an open network needs no password")
	check(fake.ran(["nmcli", "--wait", str(Tokens.WIFI_CONNECT_TIMEOUT - 5), "device", "wifi", "connect", "Cafe Free"]), "joined")
	_end()


func test_daemon_ok_key_is_accept() -> void:
	await _start()
	main.state.go(State.Screen.HOME)
	main.state.handle("back")
	main.state.set_sidebar_focus(1)          # Settings
	main.daemon._dispatch({"evt": "accept"})
	for i in 3:
		await tree.process_frame
	eq(main.state.screen, State.Screen.SETTINGS, "OK passed on by the daemon ran the item (D82)")
	check(not Input.is_action_pressed("accept"), "and let go")
	_end()
