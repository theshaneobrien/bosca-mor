extends "res://tests/test_case.gd"

const HomeScene := preload("res://scenes/home.tscn")
const Apps := preload("res://scripts/apps.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const Mode := InputModeScript.Mode

var home: Control
var im: Node
var launched: Array = []


func _setup() -> void:
	im = tree.root.get_node_or_null("InputMode")
	if im == null:
		im = InputModeScript.new()
		im.name = "InputMode"
		tree.root.add_child(im)
	im.fake_now_ms = 1000
	im._set_mode(Mode.REMOTE)
	im._motion.clear()
	im.release_all()
	home = HomeScene.instantiate()
	home.apps_path = Apps.DEFAULT_PATH
	home.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(home)
	home.launch_requested.connect(func(app): launched.append(app.id))
	await tree.process_frame
	await tree.process_frame


func _teardown() -> void:
	home.free()
	im.fake_now_ms = -1


func _push(ev: InputEvent) -> void:
	tree.root.push_input(ev, true)


func _key(k: Key, pressed := true, echo := false) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = pressed
	e.echo = echo
	_push(e)


func _button(b: JoyButton, pressed := true) -> void:
	var e := InputEventJoypadButton.new()
	e.button_index = b
	e.pressed = pressed
	_push(e)


func _stick(value: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = JOY_AXIS_LEFT_X
	e.axis_value = value
	_push(e)


func _mouse_to(pos: Vector2, at_ms: int) -> void:
	im.fake_now_ms = at_ms
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	_push(e)


func _click(pos: Vector2, b := MOUSE_BUTTON_LEFT) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = b
		e.position = pos
		e.global_position = pos
		e.pressed = pressed
		_push(e)


func _centre(i: int) -> Vector2:
	return home.tiles[i].get_global_rect().get_center()


func test_mouse_jitter_changes_nothing() -> void:
	await _setup()
	var p := _centre(2)
	var t := 1000
	for dx in [0, 15, -15, 15, -15, 15]:
		_mouse_to(p + Vector2(dx, 0), t)
		t += 50
	eq(im.mode, Mode.REMOTE, "mode after 30 px of jitter")
	im.fake_now_ms = t + 300
	home.resolve_dwell()
	eq(home.focus, 0, "focus after jitter")
	eq(im.cursor_visible, false, "cursor stays hidden")
	_teardown()


func test_big_move_enters_pointer_mode() -> void:
	await _setup()
	_mouse_to(Vector2(100, 100), 1000)
	_mouse_to(Vector2(140, 100), 1100)
	eq(im.mode, Mode.POINTER, "mode after 40 px in 100 ms")
	eq(im.cursor_visible, true, "cursor shows")
	_teardown()


func test_slow_drift_stays_in_focus_mode() -> void:
	await _setup()
	var t := 1000
	for i in 10:
		_mouse_to(Vector2(100 + i * 10, 100), t)
		t += 150
	eq(im.mode, Mode.REMOTE, "10 px per 150 ms never makes 40 px within 250 ms")
	_teardown()


func test_dpad_snaps_back_to_focus_mode() -> void:
	await _setup()
	_mouse_to(Vector2(100, 100), 1000)
	_mouse_to(Vector2(200, 100), 1050)
	eq(im.mode, Mode.POINTER, "pointer first")
	_button(JOY_BUTTON_DPAD_RIGHT)
	_button(JOY_BUTTON_DPAD_RIGHT, false)
	eq(im.mode, Mode.CONTROLLER, "D-pad enters controller mode")
	eq(im.cursor_visible, false, "cursor hidden at once")
	eq(home.focus, 1, "D-pad moved focus")
	_key(KEY_LEFT)
	eq(im.mode, Mode.REMOTE, "key enters remote mode")
	eq(home.focus, 0, "arrow moved focus")
	_teardown()


func test_hover_needs_dwell() -> void:
	await _setup()
	_mouse_to(_centre(0) + Vector2(-60, 0), 1000)
	_mouse_to(_centre(0), 1050)
	eq(im.mode, Mode.POINTER, "pointer mode")
	_mouse_to(_centre(2), 1100)
	im.fake_now_ms = 1200
	home.resolve_dwell()
	eq(home.focus, 0, "no focus change at 100 ms")
	im.fake_now_ms = 1230
	home.resolve_dwell()
	eq(home.focus, 2, "focus moves after 120 ms dwell")
	_teardown()


func test_hover_ignored_outside_pointer_mode() -> void:
	await _setup()
	_button(JOY_BUTTON_DPAD_DOWN)
	_mouse_to(_centre(3), 1000)
	_mouse_to(_centre(3) + Vector2(5, 0), 1100)
	im.fake_now_ms = 2000
	home.resolve_dwell()
	eq(home.focus, 0, "hover in controller mode")
	_teardown()


func test_gamepad_repeat() -> void:
	await _setup()
	_button(JOY_BUTTON_DPAD_RIGHT)
	eq(home.focus, 1, "press")
	im.tick(0.39)
	eq(home.focus, 1, "no repeat before 400 ms")
	im.tick(0.01)
	eq(home.focus, 2, "first repeat at 400 ms")
	im.tick(0.11)
	eq(home.focus, 3, "then every 110 ms")
	im.tick(0.22)
	eq(home.focus, 5, "two more after 220 ms")
	_button(JOY_BUTTON_DPAD_RIGHT, false)
	im.tick(1.0)
	eq(home.focus, 5, "release stops repeat")
	_teardown()


func test_held_key_uses_our_repeat_not_os_echo() -> void:
	await _setup()
	_key(KEY_RIGHT)
	eq(home.focus, 1, "press")
	for i in 5:
		_key(KEY_RIGHT, true, true)
	eq(home.focus, 1, "OS echo ignored")
	im.tick(0.39)
	eq(home.focus, 1, "no repeat before 400 ms")
	im.tick(0.01)
	eq(home.focus, 2, "first repeat at 400 ms")
	im.tick(0.11)
	eq(home.focus, 3, "then every 110 ms")
	_key(KEY_RIGHT, false)
	im.tick(1.0)
	eq(home.focus, 3, "release stops repeat")
	_teardown()


func test_focus_loss_stops_repeat() -> void:
	await _setup()
	_key(KEY_RIGHT)
	im._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	im.tick(1.0)
	eq(home.focus, 1, "no repeat after focus loss")
	_teardown()


func test_stick_moves_once_per_push() -> void:
	await _setup()
	_stick(0.8)
	await tree.process_frame
	eq(home.focus, 1, "past deadzone")
	_stick(0.95)
	await tree.process_frame
	eq(home.focus, 1, "still held")
	_stick(0.2)
	_stick(0.7)
	await tree.process_frame
	eq(home.focus, 2, "second push")
	_stick(0.0)
	eq(im.mode, Mode.CONTROLLER, "stick enters controller mode")
	_teardown()


func test_focus_stops_at_ends() -> void:
	await _setup()
	_key(KEY_LEFT)
	eq(home.focus, 0, "left end")
	home.set_focus(9)
	_key(KEY_RIGHT)
	eq(home.focus, 9, "right end")
	_teardown()


func test_wheel_scrolls_one_tile_per_notch() -> void:
	await _setup()
	_click(Vector2(10, 10), MOUSE_BUTTON_WHEEL_DOWN)
	_click(Vector2(10, 10), MOUSE_BUTTON_WHEEL_DOWN)
	_click(Vector2(10, 10), MOUSE_BUTTON_WHEEL_UP)
	eq(home.focus, 1, "two down, one up")
	eq(im.mode, Mode.REMOTE, "wheel leaves the mode alone")
	_teardown()


func test_accept_emits_launch() -> void:
	await _setup()
	launched.clear()
	_key(KEY_RIGHT)
	_key(KEY_ENTER)
	home.play_return()
	_button(JOY_BUTTON_A)
	eq(launched, ["plex", "plex"], "Enter and A launch the focused app")
	_teardown()


func test_click_launches_clicked_tile() -> void:
	await _setup()
	launched.clear()
	_click(_centre(3))
	eq(im.mode, Mode.POINTER, "click enters pointer mode")
	eq(home.focus, 3, "focus follows the click")
	eq(launched, ["netflix"], "click launches that tile")
	_click(Vector2(960, 60))
	eq(launched.size(), 1, "click off the tiles does nothing")
	_teardown()


func test_hints_follow_mode() -> void:
	await _setup()
	_key(KEY_DOWN)
	eq(home.hint_labels(), ["OK", "Back"], "remote")
	_button(JOY_BUTTON_DPAD_DOWN)
	eq(home.hint_labels(), ["A", "B"], "controller")
	_mouse_to(Vector2(100, 100), 1000)
	_mouse_to(Vector2(300, 100), 1050)
	eq(im.mode, Mode.POINTER, "pointer")
	eq(home.hint_labels(), ["A", "B"], "pointer keeps the previous hints")
	_teardown()


func test_cursor_hides_when_still() -> void:
	await _setup()
	_mouse_to(Vector2(100, 100), 1000)
	_mouse_to(Vector2(200, 100), 1050)
	eq(im.cursor_visible, true, "shown on entering pointer mode")
	im._on_hide_timeout()
	eq(im.cursor_visible, false, "hidden after 3 s still")
	eq(im.mode, Mode.POINTER, "still pointer mode")
	_mouse_to(Vector2(201, 100), 1100)
	eq(im.cursor_visible, true, "any move shows it again")
	_teardown()


func test_pad_style_from_name() -> void:
	eq(InputModeScript.style_for_pad("DualSense Wireless Controller"), "playstation", "DualSense")
	eq(InputModeScript.style_for_pad("PS4 Controller"), "playstation", "PS4")
	eq(InputModeScript.style_for_pad("Sony DualShock 4"), "playstation", "DualShock")
	eq(InputModeScript.style_for_pad("Xbox Series X Controller"), "xbox", "Xbox")
	eq(InputModeScript.style_for_pad(""), "xbox", "unknown")


func test_debug_overlay() -> void:
	await _setup()
	_key(KEY_F12)
	_key(KEY_LEFT)
	var text: String = im.overlay_text()
	check(text.contains("nav_left"), "overlay shows the action: %s" % text)
	check(text.contains("remote"), "overlay shows the mode: %s" % text)
	_key(KEY_F12)
	eq(im.overlay_text(), "", "F12 hides it")
	_teardown()


# Saved events must match any device: a second pad, or a keyboard Godot
# numbers differently, has to work too.
func test_actions_match_every_device() -> void:
	for a in InputMap.get_actions():
		if a.begins_with("ui_"):
			continue
		for ev in InputMap.action_get_events(a):
			eq(ev.device, -1, "%s: %s" % [a, ev.as_text()])
	var pad := InputEventJoypadButton.new()
	pad.device = 2
	pad.button_index = JOY_BUTTON_A
	pad.pressed = true
	check(pad.is_action_pressed("accept"), "third pad's A is accept")


# Box test: hovering a tile never selected it. The dwell timer fired a frame
# early by the clock, resolve_dwell gave up, and nothing tried again.
func test_early_dwell_timer_waits_out_the_rest() -> void:
	await _setup()
	_mouse_to(_centre(0) + Vector2(-60, 0), 1000)
	_mouse_to(_centre(0), 1050)
	_mouse_to(_centre(2), 1100)
	im.fake_now_ms = 1210            # 110 ms: the timer fired early
	home.resolve_dwell()
	eq(home.focus, 0, "not yet")
	check(not home._dwell_timer.is_stopped(), "re-armed for the remaining 10 ms")
	check(absf(home._dwell_timer.time_left - 0.010) < 0.002, "for the rest only: %s" % home._dwell_timer.time_left)
	im.fake_now_ms = 1220
	home.resolve_dwell()
	eq(home.focus, 2, "selected once the dwell is really over")
	_teardown()
