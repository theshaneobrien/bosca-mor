# Autoload "InputMode": which device was used last (remote/keyboard,
# controller, pointer), the air-mouse rules, held-direction repeat, and the
# F12 debug overlay. Screens read actions; they ask this node only for the mode.
extends Node

const Tokens := preload("res://theme/tokens.gd")

enum Mode { REMOTE, CONTROLLER, POINTER }

const NAV := ["nav_left", "nav_right", "nav_up", "nav_down"]

signal mode_changed(mode: Mode)
## "remote", "xbox" or "playstation"; pointer mode keeps the previous style.
signal hints_changed(style: String)

var mode := Mode.REMOTE
var cursor_visible := false
var pad_style := "xbox"
## Settings > Controllers: "auto" follows the pad's name, or "xbox", "playstation".
var glyph_style := "auto"
## Tests set this to drive time by hand; -1 uses the real clock.
var fake_now_ms := -1

var _focus_mode := Mode.REMOTE      # last non-pointer mode
var _motion: Array = []             # [[ms, position], ...] within POINTER_WINDOW
var _stick := {}                    # axis -> held direction action or ""
var _held := {}                     # nav action -> true while a key or button holds it
var _repeat_action := ""
var _repeat_t := 0.0
var _repeat_next := 0.0
var _hide_timer: Timer
var _overlay: CanvasLayer
var _overlay_text: Label


func _ready() -> void:
	set_process(false)
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.timeout.connect(_on_hide_timeout)
	add_child(_hide_timer)
	if not Input.get_connected_joypads().is_empty():
		_set_mode(Mode.CONTROLLER)
	_apply_cursor()


func now_ms() -> int:
	return fake_now_ms if fake_now_ms >= 0 else Time.get_ticks_msec()


func hint_style() -> String:
	if _focus_mode == Mode.REMOTE:
		return "remote"
	return pad_style if glyph_style == "auto" else glyph_style


func set_glyph_style(s: String) -> void:
	var old := hint_style()
	glyph_style = s
	if hint_style() != old:
		hints_changed.emit(hint_style())


static func style_for_pad(pad_name: String) -> String:
	for s in ["DualSense", "DualShock", "PS"]:
		if pad_name.contains(s):
			return "playstation"
	return "xbox"


func _input(ev: InputEvent) -> void:
	if ev.is_action_pressed("debug_overlay"):
		_toggle_overlay()
		get_viewport().set_input_as_handled()
		return

	if ev is InputEventKey:
		if ev.echo and _nav_action(ev) != "":
			# OS key repeat (X11, the G20S, Windows) is replaced by our own timer.
			get_viewport().set_input_as_handled()
			return
		if ev.pressed:
			_set_mode(Mode.REMOTE)
		_track_nav(ev)
	elif ev is InputEventJoypadButton:
		if ev.pressed:
			pad_style = style_for_pad(Input.get_joy_name(ev.device))
			_set_mode(Mode.CONTROLLER)
		_track_nav(ev)
	elif ev is InputEventJoypadMotion:
		_track_stick(ev)
		# Screens never see raw stick motion, only the edges sent above.
		get_viewport().set_input_as_handled()
	elif ev is InputEventMouseButton:
		if ev.pressed and not _is_wheel(ev):
			_set_mode(Mode.POINTER)
			_wake_cursor()
	elif ev is InputEventMouseMotion:
		_track_motion(ev)

	if _overlay and _overlay.visible:
		_show_event(ev)


# Air mouse --------------------------------------------------------------------

func _track_motion(ev: InputEventMouseMotion) -> void:
	var t := now_ms()
	var window := int(Tokens.POINTER_WINDOW * 1000)
	_motion.append([t, ev.position])
	while not _motion.is_empty() and t - _motion[0][0] > window:
		_motion.pop_front()
	if mode == Mode.POINTER:
		_wake_cursor()
		return
	for m in _motion:
		if ev.position.distance_to(m[1]) >= Tokens.POINTER_MOVE:
			_motion.clear()
			_set_mode(Mode.POINTER)
			_wake_cursor()
			return


func _wake_cursor() -> void:
	_show_cursor(true)
	_hide_timer.start(Tokens.POINTER_HIDE)


func _on_hide_timeout() -> void:
	_show_cursor(false)


func _show_cursor(on: bool) -> void:
	cursor_visible = on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if on else Input.MOUSE_MODE_HIDDEN


func _is_wheel(ev: InputEventMouseButton) -> bool:
	return ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]


# Held-direction repeat --------------------------------------------------------
# Keys, D-pad and stick all repeat on one timer: REPEAT_DELAY, then REPEAT_RATE.

func _nav_action(ev: InputEvent) -> String:
	for a in NAV:
		if ev.is_action(a):
			return a
	return ""


func _track_nav(ev: InputEvent) -> void:
	var a := _nav_action(ev)
	if a != "":
		_hold(a, ev.is_pressed())


## Drops every held direction, e.g. when the window loses focus and the
## release would never arrive.
func release_all() -> void:
	_held.clear()
	_stick.clear()
	_repeat_action = ""
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all()


func _track_stick(ev: InputEventJoypadMotion) -> void:
	var dir := ""
	if ev.axis == JOY_AXIS_LEFT_X:
		dir = "nav_left" if ev.axis_value <= -Tokens.STICK_DEADZONE else ("nav_right" if ev.axis_value >= Tokens.STICK_DEADZONE else "")
	elif ev.axis == JOY_AXIS_LEFT_Y:
		dir = "nav_up" if ev.axis_value <= -Tokens.STICK_DEADZONE else ("nav_down" if ev.axis_value >= Tokens.STICK_DEADZONE else "")
	else:
		return
	var was: String = _stick.get(ev.axis, "")
	if dir == was:
		return
	_stick[ev.axis] = dir
	if not was.is_empty():
		_hold(was, false)
	if not dir.is_empty():
		pad_style = style_for_pad(Input.get_joy_name(ev.device))
		_set_mode(Mode.CONTROLLER)
		_hold(dir, true)
		_send.call_deferred(dir)


func _hold(action: String, down: bool) -> void:
	if down:
		_held[action] = true
		_repeat_action = action
		_repeat_t = 0.0
		_repeat_next = Tokens.REPEAT_DELAY
		set_process(true)
	else:
		_held.erase(action)
		if action == _repeat_action:
			_repeat_action = ""
			set_process(false)


func _process(delta: float) -> void:
	tick(delta)


## Advances the repeat. Runs only while a direction is held.
func tick(delta: float) -> void:
	if _repeat_action.is_empty():
		return
	_repeat_t += delta
	while _repeat_t >= _repeat_next - 0.0001:
		_repeat_next += Tokens.REPEAT_RATE
		_send(_repeat_action)


func _send(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	get_viewport().push_input(a)


# Mode -------------------------------------------------------------------------

func _set_mode(m: Mode) -> void:
	var old_style := hint_style()
	if m != Mode.POINTER:
		_focus_mode = m
		_hide_timer.stop()
	if m != mode:
		mode = m
		_apply_cursor()
		mode_changed.emit(m)
	if hint_style() != old_style:
		hints_changed.emit(hint_style())


func _apply_cursor() -> void:
	if mode != Mode.POINTER:
		_show_cursor(false)


# Debug overlay (F12) ------------------------------------------------------------

func _toggle_overlay() -> void:
	if _overlay == null:
		_build_overlay()
	_overlay.visible = not _overlay.visible
	if _overlay.visible:
		_overlay_text.text = "Waiting for input\nMode: %s" % Mode.keys()[mode].to_lower()


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	_overlay.visible = false
	add_child(_overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(Tokens.PAD_X, Tokens.PAD_TOP)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Tokens.SURFACE
	sb.border_color = Tokens.BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(Tokens.TILE_RADIUS)
	sb.set_content_margin_all(Tokens.HINT_GAP)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(panel)
	_overlay_text = Label.new()
	_overlay_text.add_theme_font_override("font", Tokens.mono(400, Tokens.TOPBAR_DATE))
	_overlay_text.add_theme_font_size_override("font_size", Tokens.TOPBAR_DATE)
	_overlay_text.add_theme_color_override("font_color", Tokens.TEXT)
	panel.add_child(_overlay_text)


func overlay_text() -> String:
	return _overlay_text.text if _overlay and _overlay.visible else ""


func _show_event(ev: InputEvent) -> void:
	var device := "mouse"
	if ev is InputEventKey:
		device = "keyboard or remote"
	elif ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
		device = "pad %d (%s)" % [ev.device, Input.get_joy_name(ev.device)]
	elif ev is InputEventAction:
		device = "repeat"
	var actions := []
	for a in InputMap.get_actions():
		if not a.begins_with("ui_") and ev.is_action(a):
			actions.append(a)
	if ev is InputEventAction:
		actions = [ev.action]
	var detail := ev.as_text()
	if ev is InputEventKey:
		detail += "  keycode %d  physical %d" % [ev.keycode, ev.physical_keycode]
	_overlay_text.text = "Event: %s\nDevice: %s\nAction: %s\nMode: %s" % [
		detail, device, ", ".join(actions) if actions else "none", Mode.keys()[mode].to_lower()]
