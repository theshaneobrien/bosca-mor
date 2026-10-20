# Renders a named screen state to PNG at any output size, scaled from the
# 1920x1080 base the same way canvas_items stretch scales the window.
# godot --path launcher -s res://tools/shot.gd -- --state=home --size=1920x1080 --out=../shots/home.png
# States: home, menu (as Menu.dc.html), power and restart (as Power.dc.html).
# Options: --focus=N (focused tile), --item=N (sidebar item), --apps=PATH
# (apps.json to use), --hints=remote|xbox|playstation (hint key style)
extends SceneTree

const Tokens := preload("res://theme/tokens.gd")
const MainScene := preload("res://scenes/main.tscn")
const InputModeScript := preload("res://scripts/input_mode.gd")
const STATES := ["home", "menu", "power", "restart"]
# Defaults that match the design references.
const FOCUS := {"home": 0, "menu": 2, "power": 0, "restart": 0}


func _initialize() -> void:
	_shoot.call_deferred()


func _shoot() -> void:
	var opts := {"state": "home", "size": "1920x1080", "out": "", "focus": "", "item": "1", "apps": "", "hints": ""}
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
	main.home.set_focus(int(opts.focus) if opts.focus else FOCUS[opts.state], false)
	await _frames()

	# The sidebar blur captures what was drawn last, so Home renders first.
	match opts.state:
		"menu":
			main.state.handle("back")
			main.state.set_sidebar_focus(int(opts.item))
		"power", "restart":
			main.state.ask("poweroff" if opts.state == "power" else "restart")
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
