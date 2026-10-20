# Renders a named screen state to PNG at any output size, scaled from the
# 1920x1080 base the same way canvas_items stretch scales the window.
# godot --path launcher -s res://tools/shot.gd -- --state=home --size=1920x1080 --out=../shots/home.png
# Options: --focus=N (focused tile), --apps=PATH (apps.json to use),
# --hints=remote|xbox|playstation (hint key style)
extends SceneTree

const Tokens := preload("res://theme/tokens.gd")
const STATES := {
	"home": "res://scenes/home.tscn",
}


func _initialize() -> void:
	_shoot.call_deferred()


func _shoot() -> void:
	var opts := {"state": "home", "size": "1920x1080", "out": "../shots/home.png", "focus": "", "apps": "", "hints": ""}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1]
	if not STATES.has(opts.state):
		printerr("unknown state %s; have %s" % [opts.state, STATES.keys()])
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

	var screen: Node = load(STATES[opts.state]).instantiate()
	if not opts.apps.is_empty():
		screen.apps_path = opts.apps
	vp.add_child(screen)
	if not opts.focus.is_empty():
		screen.set_focus(int(opts.focus))
	if not opts.hints.is_empty():
		screen._set_hint_style(opts.hints)

	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw

	var out: String = opts.out
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
