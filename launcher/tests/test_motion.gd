extends "res://tests/test_case.gd"

const HomeScene := preload("res://scenes/home.tscn")
const Apps := preload("res://scripts/apps.gd")
const Motion := preload("res://scripts/motion.gd")
const Tokens := preload("res://theme/tokens.gd")

var home: Control
var faded := 0


func _setup(state := "res://tests/fixtures/nope.json") -> void:
	home = HomeScene.instantiate()
	home.apps_path = Apps.DEFAULT_PATH
	home.state_path = state
	tree.root.add_child(home)
	home.launch_faded.connect(func(): faded += 1)
	await tree.process_frame


func _teardown() -> void:
	home.free()
	Motion.reduce = false


func _press(k: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = true
	tree.root.push_input(e, true)


# Every running tween must be one Motion tracks, one per object and property.
func _check_tweens(when: String) -> void:
	var running := tree.get_processed_tweens().filter(func(t): return t.is_valid() and t.is_running())
	var live := Motion.live()
	eq(running.size(), live.size(), "%s: running tweens are all tracked" % when)
	for t in running:
		check(t in live.values(), "%s: untracked tween" % when)


func _finish() -> void:
	for t in tree.get_processed_tweens():
		if t.is_valid():
			t.custom_step(10.0)


func _strip_x_for(i: int) -> float:
	return Tokens.PAD_X - maxi(0, i - Tokens.CAROUSEL_LEAD) * (Tokens.TILE + Tokens.TILE_GAP)


func _check_settled(want: int) -> void:
	eq(home.focus, want, "focus")
	eq(home._strip.position.x, _strip_x_for(want), "carousel at rest")
	for i in home.tiles.size():
		var tile: Control = home._tile(i)
		var on: bool = i == want
		check(tile.scale.is_equal_approx(Vector2.ONE * (Tokens.TILE_FOCUS_SCALE if on else 1.0)), "tile %d scale %s" % [i, tile.scale])
		eq(tile.get_node("Focus").modulate.a, 1.0 if on else 0.0, "tile %d ring" % i)
	eq(home._name.text, home.apps[want].name, "hero name")
	eq(home._pages[home._page].modulate.a, 1.0, "hero page in")
	eq(home._pages[1 - home._page].modulate.a, 0.0, "hero page out")
	eq(home._pages[home._page].position.y, 0.0, "hero risen")
	eq(home._kind.get_theme_color("font_color"), home.apps[want].accent, "kind accent")


func test_twenty_presses_in_one_frame() -> void:
	await _setup()
	for i in 20:
		_press(KEY_RIGHT)
	_check_tweens("after 20 presses")
	_finish()
	_check_settled(9)
	_teardown()


func test_twenty_presses_across_frames() -> void:
	await _setup()
	for i in 20:
		_press(KEY_RIGHT if i < 14 else KEY_LEFT)
		await tree.process_frame
		_check_tweens("press %d" % i)
	_finish()
	_check_settled(3)
	_teardown()


func test_retarget_starts_from_current_value() -> void:
	await _setup()
	_press(KEY_RIGHT)
	for t in tree.get_processed_tweens():
		t.custom_step(Tokens.T_TILE_FOCUS / 2.0)
	var mid: Vector2 = home._tile(1).scale
	check(mid.x > 1.0 and mid.x < Tokens.TILE_FOCUS_SCALE + 0.1, "tile 1 mid-tween: %s" % mid)
	_press(KEY_LEFT)
	eq(home._tile(1).scale, mid, "reversing tile keeps its current scale")
	_finish()
	_check_settled(0)
	_teardown()


func test_carousel_scrolls_after_fourth_tile() -> void:
	await _setup()
	for i in 3:
		_press(KEY_RIGHT)
	eq(Motion.live().has("%d:position:x" % home._strip.get_instance_id()), false, "no scroll up to the fourth tile")
	_press(KEY_RIGHT)
	check(Motion.live().has("%d:position:x" % home._strip.get_instance_id()), "scrolls past the fourth tile")
	_finish()
	_check_settled(4)
	_teardown()


func test_end_nudge_returns() -> void:
	await _setup()
	_press(KEY_LEFT)
	check(Motion.live().has("%d:position:x" % home._strip.get_instance_id()), "nudge at the left end")
	for t in tree.get_processed_tweens():
		t.custom_step(Tokens.T_BUMP / 2.0)
	eq(home._strip.position.x, _strip_x_for(0) - Tokens.BUMP, "nudged 12 px")
	_finish()
	_check_settled(0)
	_teardown()


func test_launch_and_return() -> void:
	await _setup()
	faded = 0
	_press(KEY_ENTER)
	check(home.is_launching(), "launching")
	_press(KEY_RIGHT)
	eq(home.focus, 0, "input ignored while launching")
	_finish()
	eq(faded, 1, "launch_faded")
	eq(home._fade.color.a, 1.0, "black")
	check(home._tile(0).scale.is_equal_approx(Vector2.ONE * Tokens.LAUNCH_SCALE), "tile zoomed")
	home.play_return()
	_finish()
	eq(home._fade.visible, false, "fade gone")
	_check_settled(0)
	_press(KEY_RIGHT)
	eq(home.focus, 1, "input back")
	_teardown()


func test_reduce_motion_halves_every_duration() -> void:
	for spec in Motion.SPECS:
		Motion.reduce = false
		var full := Motion.duration(spec)
		Motion.reduce = true
		eq(Motion.duration(spec), full / 2.0, spec)
	Motion.reduce = false


func test_reduce_motion_fades_only() -> void:
	await _setup("res://tests/fixtures/state_reduce.json")
	check(Motion.reduce, "read from state.json")
	_press(KEY_RIGHT)
	check(home._tile(1).scale.is_equal_approx(Vector2.ONE * Tokens.TILE_FOCUS_SCALE), "scale snaps")
	eq(home._pages[home._page].position.y, 0.0, "no rise")
	check(Motion.live().has("%d:modulate:a" % home._pages[home._page].get_instance_id()), "hero still fades")
	for i in 3:
		_press(KEY_RIGHT)
	eq(home._strip.position.x, _strip_x_for(4), "carousel snaps")
	home.set_focus(9, false)
	_press(KEY_RIGHT)
	eq(home._strip.position.x, _strip_x_for(9), "no nudge")
	_finish()
	_check_settled(9)
	_teardown()
