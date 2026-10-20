# The launcher root: Home, the sidebar, the power confirm and the power-off
# screen, driven by the state machine in state.gd. Home handles its own
# moves and launches; everything else comes through here.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const UI := preload("res://scripts/ui.gd")
const State := preload("res://scripts/state.gd")
const HomeScene := preload("res://scenes/home.tscn")
const Sidebar := preload("res://scripts/sidebar.gd")
const Confirm := preload("res://scripts/confirm.gd")
const DaemonClient := preload("res://scripts/daemon_client.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const Motion := preload("res://scripts/motion.gd")
const SettingsView := preload("res://scripts/settings.gd")
const Prefs := preload("res://scripts/prefs.gd")
const StillOpen := preload("res://scripts/still_open.gd")
const Apps := preload("res://scripts/apps.gd")

const OFF_TEXT := {"poweroff": "Shutting down", "restart": "Restarting"}

## Passed to Home; empty reads the user's files.
@export var apps_path := ""
@export var state_path := ""
## Tests and the shot tool switch screens without tweens.
var animate := true

var state := State.new()
var home: Control
var sidebar: Control
var confirm: Control
var settings: Control
var still: Control
var daemon: Node
var _off: ColorRect
var _off_text: Label
var _window_mode := Window.MODE_WINDOWED
## True while an app or the desktop is in front: the window is minimised and
## the tree paused, with only the daemon poll timer running.
var is_hidden := false
var _shown_sleep_usec := 0
var _panel_running := false        # a Cinnamon settings panel opened from Settings


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	if apps_path.is_empty():
		Apps.seed_dev_home()
	daemon = DaemonClient.new()
	daemon.name = "Daemon"
	add_child(daemon)

	home = HomeScene.instantiate()
	home.apps_path = apps_path
	home.state_path = state_path
	add_child(home)
	settings = SettingsView.new()
	settings.apps_path = apps_path
	settings.state_path = state_path
	add_child(settings)
	still = StillOpen.new()
	add_child(still)
	sidebar = Sidebar.new(home)
	add_child(sidebar)
	confirm = Confirm.new()
	add_child(confirm)
	_build_off()

	state.changed.connect(_on_changed)
	state.sidebar_focus_changed.connect(sidebar.set_focus)
	state.confirm_focus_changed.connect(confirm.set_focus)
	state.still_focus_changed.connect(still.set_focus)
	state.force_close_confirmed.connect(func(): daemon.force_close(still.wids()))
	settings.closed.connect(func(): state.go(State.Screen.HOME))
	settings.apps_changed.connect(home.reload)
	settings.prefs_changed.connect(apply_prefs)
	settings.launch_panel.connect(_launch_panel)
	home.launch_requested.connect(daemon.launch)
	home.launch_faded.connect(hide_launcher)
	daemon.app_exited.connect(_on_app_exited)
	daemon.launch_failed.connect(_on_launch_failed)
	daemon.show_home.connect(_on_show_home)
	daemon.power_pressed.connect(_on_power_pressed)
	daemon.memory_warning.connect(_on_memory_warning)
	daemon.still_open.connect(_on_still_open)
	print("session type: %s" % OS.get_environment("XDG_SESSION_TYPE"))
	apply_prefs(Prefs.load_prefs(state_path))


## Reduce motion, screen size and button names, from Settings or state.json.
func apply_prefs(p: Dictionary) -> void:
	Motion.reduce = p.reduce_motion
	pivot_offset = Vector2(Tokens.BASE_SIZE) / 2.0
	scale = Vector2.ONE * p.ui_scale
	var im := get_node_or_null("/root/InputMode")
	if im:
		im.set_glyph_style(p.glyph_style)


# Return to Bosca Mor ended with windows still open.
func _on_still_open(apps: Array) -> void:
	if apps.is_empty():
		_on_show_home()
		return
	show_launcher()
	still.open(apps)
	state.show_still_open()


func _on_memory_warning(app_id: String, mb: int) -> void:
	var note := "%d MB free%s" % [mb, " while %s ran" % app_id if app_id else ""]
	print("memory low: " + note)
	settings.memory_note = note


func _launch_panel(app: Dictionary) -> void:
	_panel_running = true
	daemon.launch(app)
	hide_launcher()


# Daemon events ----------------------------------------------------------------

func _on_app_exited(_app_id: String, _code: int) -> void:
	if _panel_running:
		_panel_running = false
		show_launcher()
	elif home.is_launching():
		show_launcher()
		home.play_return()


# The toast naming the app comes later; for now the launcher just comes back.
func _on_launch_failed(app_id: String, error: String) -> void:
	push_warning("could not start %s: %s" % [app_id, error])
	_on_app_exited(app_id, -1)


# Home or Guide while hidden. An app with keep_on_home is still running.
func _on_show_home() -> void:
	_panel_running = false
	show_launcher()
	if home.is_launching():
		home.play_return()
	if state.screen in [State.Screen.DESKTOP, State.Screen.OFF, State.Screen.SETTINGS]:
		state.show_home()


# Power from the daemon shows the launcher and opens the confirm, whatever
# was on screen (SPEC: "Power, in any state").
func _on_power_pressed() -> void:
	show_launcher()
	if home.is_launching():
		home.play_return()
	if state.screen in [State.Screen.DESKTOP, State.Screen.OFF]:
		state.show_home()
	state.handle("power")


# Hidden and shown (SPEC Resource use) ------------------------------------------

## After the launch fade, or on Desktop: minimise, pause, free the blur and
## stop tweens, and sleep longer between main-loop wakeups.
func hide_launcher() -> void:
	if is_hidden:
		return
	is_hidden = true
	daemon.set_visible(false)
	sidebar.close(false)
	confirm.close(false)
	Motion.stop_all()
	_shown_sleep_usec = OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode_sleep_usec = Tokens.HIDDEN_SLEEP_USEC
	get_tree().paused = true
	_minimize_window()   # last: minimising can deliver window events at once


## The reverse: unpause first so the return fade can run.
func show_launcher() -> void:
	if not is_hidden:
		return
	is_hidden = false
	get_tree().paused = false
	OS.low_processor_usage_mode_sleep_usec = _shown_sleep_usec
	_restore_window()
	if not home.is_launching():
		home.set_focus(home.focus, false)   # settle anything a stopped tween left
	home.refresh()
	daemon.set_visible(true)


func _unhandled_input(ev: InputEvent) -> void:
	if home.is_launching():
		return
	var s := state.screen
	if ev is InputEventMouseMotion:
		if _pointer_mode():
			if s == State.Screen.SIDEBAR:
				var i: int = sidebar.item_at(ev.position)
				if i >= 0:
					state.set_sidebar_focus(i)
			elif s == State.Screen.CONFIRM:
				var b: int = confirm.button_at(ev.position)
				if b >= 0:
					state.set_confirm_focus(b)
			elif s == State.Screen.STILL_OPEN:
				var b: int = still.button_at(ev.position)
				if b >= 0:
					state.set_still_focus(b)
		return
	if ev is InputEventMouseButton and ev.is_action_pressed("accept"):
		if s == State.Screen.SIDEBAR:
			var i: int = sidebar.item_at(ev.position)
			if i >= 0:
				state.set_sidebar_focus(i)
				state.run_item(State.ITEMS[i])
			elif sidebar.is_on_dim(ev.position):
				state.go(State.Screen.HOME)
			get_viewport().set_input_as_handled()
			return
		if s == State.Screen.CONFIRM or s == State.Screen.STILL_OPEN:
			var b: int = (confirm if s == State.Screen.CONFIRM else still).button_at(ev.position)
			if b >= 0:
				if s == State.Screen.CONFIRM:
					state.set_confirm_focus(b)
				else:
					state.set_still_focus(b)
				state.handle("accept")
			get_viewport().set_input_as_handled()
			return
	for a in State.ACTIONS:
		if ev.is_action_pressed(a, a.begins_with("nav_")):
			if state.handle(a):
				get_viewport().set_input_as_handled()
			return


func _on_changed(to: State.Screen, from: State.Screen) -> void:
	home.accepting_input = to == State.Screen.HOME
	settings.accepting_input = to == State.Screen.SETTINGS
	if to == State.Screen.SETTINGS:
		settings.open()
	elif not (to == State.Screen.CONFIRM and from == State.Screen.SETTINGS):
		settings.close()
	# Still open stays under its force-close confirm.
	if to != State.Screen.STILL_OPEN and not (to == State.Screen.CONFIRM and state.confirm_kind == "forceclose"):
		still.close()
	match to:
		State.Screen.HOME:
			sidebar.close(animate)
			confirm.close(animate)
			_off.visible = false
			if from == State.Screen.DESKTOP:
				show_launcher()
				home.play_return()     # SPEC: Home with the return fade
		State.Screen.SIDEBAR:
			if not sidebar.has_capture():
				sidebar.capture()
			confirm.close(animate)
			sidebar.open(animate)
		State.Screen.CONFIRM:
			if from in [State.Screen.HOME, State.Screen.SETTINGS]:
				sidebar.capture()     # ready for Back, which returns to the sidebar
			sidebar.close(animate, true)
			confirm.open(state.confirm_kind, animate, still.apps.size())
		State.Screen.STILL_OPEN:
			confirm.close(animate)
			sidebar.close(false)
		State.Screen.DESKTOP:
			sidebar.close(false)
			confirm.close(false)
			var wids: Array = still.wids()
			hide_launcher()
			match state.desktop_reason:
				"show_me":
					daemon.show_window(wids[0] if wids else "")
				"back":
					daemon.back_to_desktop()
				_:
					daemon.show_desktop()
		State.Screen.OFF:
			sidebar.close(false)
			confirm.close(false)
			_off_text.text = OFF_TEXT[state.confirm_kind]
			_off.visible = true
			daemon.power(state.confirm_kind)


func _pointer_mode() -> bool:
	var im := get_node_or_null("/root/InputMode")
	return im != null and im.mode == InputModeScript.Mode.POINTER


func _build_off() -> void:
	_off = ColorRect.new()
	_off.size = Tokens.BASE_SIZE
	_off.color = Tokens.BLACK
	_off.visible = false
	var center := CenterContainer.new()
	center.size = Tokens.BASE_SIZE
	_off.add_child(center)
	_off_text = UI.label("", Tokens.sans(400, Tokens.OFF_TEXT), Tokens.OFF_TEXT, Tokens.DIM)
	center.add_child(_off_text)
	add_child(_off)
	UI.ignore_mouse(_off)


func _minimize_window() -> void:
	if DisplayServer.get_name() == "headless" or get_viewport() != get_window():
		return
	_window_mode = get_window().mode
	get_window().mode = Window.MODE_MINIMIZED


func _restore_window() -> void:
	if DisplayServer.get_name() == "headless" or get_viewport() != get_window():
		return
	get_window().mode = _window_mode
	get_window().move_to_foreground()
	get_window().grab_focus()


# On the dev machine there is no daemon to bring the launcher back, so
# focusing its window again does it (D23).
# Minimising itself can deliver a focus-in, so only a window that is no longer
# minimised counts, checked once that event has settled.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and state.screen == State.Screen.DESKTOP:
		_refocused.call_deferred()


func _refocused() -> void:
	if state.screen == State.Screen.DESKTOP and get_window().mode != Window.MODE_MINIMIZED 			and DisplayServer.get_name() != "headless":
		state.show_home()
