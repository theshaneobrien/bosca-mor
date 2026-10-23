# Renders a named screen state to PNG at any output size, scaled from the
# 1920x1080 base the same way canvas_items stretch scales the window.
# godot --path launcher -s res://tools/shot.gd -- --state=home --size=1920x1080 --out=../shots/home.png
# States: home, menu (as Menu.dc.html), power and restart (as Power.dc.html),
# settings (as Settings.dc.html; --section=N --row=N pick another), osk,
# stillopen (as StillOpen.dc.html), forceclose (its confirm), toast (D62: no design),
# picture (the keep confirm over Settings > Display, D79). Settings' Display,
# Sound and Network rows show the test fixtures' TV, sound card and networks.
# Options: --focus=N (focused tile), --item=N (sidebar item), --apps=PATH
# (apps.json to use), --hints=remote|xbox|playstation (hint key style)
extends SceneTree

const Tokens := preload("res://theme/tokens.gd")
const MainScene := preload("res://scenes/main.tscn")
const InputModeScript := preload("res://scripts/input_mode.gd")
const Motion := preload("res://scripts/motion.gd")
const STATES := ["home", "menu", "power", "restart", "settings", "osk", "stillopen", "forceclose", "loading", "toast", "picture"]
const FIX := "res://tests/fixtures/"
# What xrandr, pactl and nmcli say, from the test fixtures.
const FAKE := {
	"xrandr --query": "xrandr/box.txt", "xrandr --current": "xrandr/box.txt",
	"pactl list cards": "pactl/cards.txt", "pactl list short sinks": "pactl/short_sinks_hdmi2.txt",
	"pactl info": "pactl/info.txt",
	"nmcli -t -f TYPE,STATE,CONNECTION device": "nmcli/devices.txt",
	"nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan auto": "nmcli/wifi_list.txt",
	"nmcli -t -f NAME,TYPE connection show": "nmcli/saved.txt",
}
# The two windows in the design's Still open screen.
const STILL := [
	{"wid": "0x3a00007", "name": "LibreOffice Writer", "icon": "libreoffice-writer", "asking": true},
	{"wid": "0x4400002", "name": "Text Editor", "icon": "accessories-text-editor", "asking": false},
]
# Defaults that match the design references.
const FOCUS := {"home": 0, "menu": 2, "power": 0, "restart": 0, "settings": 0, "osk": 0, "stillopen": 0, "forceclose": 0, "toast": 2, "loading": 1, "picture": 0}


static func _fake_run(argv: Array, _limit := 0, _stderr := false) -> Dictionary:
	var key := " ".join(argv)
	return {"code": 0, "out": FileAccess.get_file_as_string(FIX + FAKE[key]) if FAKE.has(key) else ""}


func _initialize() -> void:
	_shoot.call_deferred()


func _shoot() -> void:
	var opts := {"state": "home", "size": "1920x1080", "out": "", "focus": "", "item": "1", "apps": "", "hints": "", "section": "0", "row": "6"}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1]
	if not opts.state in STATES:
		printerr("unknown state %s; have %s" % [opts.state, STATES])
		quit(2)
		return
	var wh: PackedStringArray = opts.size.split("x")
	var size := Vector2i(int(wh[0]), int(wh[1]))

	OS.low_processor_usage_mode = false
	var vp := SubViewport.new()
	vp.size = size
	vp.size_2d_override = Tokens.BASE_SIZE
	vp.size_2d_override_stretch = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var im := root.get_node_or_null("InputMode")
	if im and not opts.hints.is_empty():
		im.pad_style = "playstation" if opts.hints == "playstation" else "xbox"
		im._set_mode(InputModeScript.Mode.REMOTE if opts.hints == "remote" else InputModeScript.Mode.CONTROLLER)

	var main: Node = MainScene.instantiate()
	if not opts.apps.is_empty():
		main.apps_path = opts.apps
	vp.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	main.setup.enabled = true
	main.setup.threaded = false
	main.setup.run = _fake_run
	main.setup.check(true)
	main.home.set_focus(int(opts.focus) if opts.focus else FOCUS.get(opts.state, 0), false)
	await _frames()

	# The sidebar blur captures what was drawn last, so Home renders first.
	match opts.state:
		"menu":
			main.state.handle("back")
			main.state.set_sidebar_focus(int(opts.item))
		"power", "restart":
			main.state.ask("poweroff" if opts.state == "power" else "restart")
		"picture":
			main.state.go(main.State.Screen.SETTINGS)
			main.settings.section = 1
			main.settings._enter()
			main.settings._render()
			main.state.ask("picture")
		"settings", "osk":
			main.state.go(main.State.Screen.SETTINGS)
			var st = main.settings
			st.section = int(opts.section)
			st._enter()
			st.item = int(opts.row) if st.section == 0 else 0
			if opts.state == "osk":
				st.col = 1
				st._accept()
			st._render()
		"loading":
			# The black after launching Plex, its loading screen mid-pulse (D76).
			main.home.set_focus(1, false)
			main.home.launch()
			for t in get_processed_tweens():
				t.custom_step(10.0)
			main.loader.reveal()
			for t in get_processed_tweens():
				t.custom_step(0.6)
		"stillopen", "forceclose":
			main._on_still_open(STILL)
			if opts.state == "forceclose":
				main.state.set_still_focus(1)
				main.state.handle("accept")
		"toast":
			main.toast.push("Jellyfin took too long to open")
			main.toast.modulate.a = 1.0
			Motion.stop(main.toast, "modulate:a")
	await _frames()

	var out: String = opts.out if opts.out else "../shots/%s.png" % opts.state
	if out.is_relative_path():
		out = ProjectSettings.globalize_path("res://").path_join(out).simplify_path()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var err := vp.get_texture().get_image().save_png(out)
	if err != OK:
		printerr("could not write %s (%s)" % [out, error_string(err)])
		quit(1)
		return
	print("wrote %s" % out)
	quit(0)


func _frames() -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
