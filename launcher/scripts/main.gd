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
const Loader := preload("res://scripts/loader.gd")
const Apps := preload("res://scripts/apps.gd")
const Toast := preload("res://scripts/toast.gd")
const SystemSetup := preload("res://scripts/system_setup.gd")

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
var toast: Control
var loader: Control
var daemon: Node
## The TV picture and sound (D79, D80).
var setup: Node
var _launched := {}                # the app last sent to the daemon, for its name
var _off: ColorRect
var _off_text: Label
var _window_mode := Window.MODE_FULLSCREEN
var _minimized := false
## After the launch fade the launcher stays full screen, black and paused
## behind the app; it never minimises for an app (D65, D69). This is true
## until the daemon says the app's window is up.
var waiting_for_window := false
var _window_seen := false
var _cover: ColorRect              # black over everything while going to the desktop
## True while an app or the desktop is in front: the window is minimised and
## the tree paused, with only the daemon poll timer running.
var is_hidden := false
var _shown_sleep_usec := 0
var _asleep := false               # tree paused and long main-loop sleeps
var _removing := {}               # the app the remove confirm is about
var _panel_running := false        # a Cinnamon settings panel opened from Settings
var _picture_old := ""             # while a new picture is on trial: the one to go back to
var _picture_new := ""
var _picture_timer: Timer


func _ready() -> void:
	# Idle Home wakes 60 times a second, not 145 (D84).
	OS.low_processor_usage_mode_sleep_usec = Tokens.SHOWN_SLEEP_USEC
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	if apps_path.is_empty():
		Apps.seed_dev_home()
	daemon = DaemonClient.new()
	daemon.name = "Daemon"
	add_child(daemon)
	setup = SystemSetup.new()
	setup.name = "Setup"
	add_child(setup)
	_picture_timer = Timer.new()
	_picture_timer.one_shot = true
	_picture_timer.timeout.connect(func():
		if state.confirm_kind == "picture":
			state.cancel_confirm())
	add_child(_picture_timer)

	home = HomeScene.instantiate()
	home.apps_path = apps_path
	home.state_path = state_path
	add_child(home)
	loader = Loader.new()              # over Home's black launch fade
	add_child(loader)
	settings = SettingsView.new()
	settings.apps_path = apps_path
	settings.state_path = state_path
	settings.setup = setup
	add_child(settings)
	still = StillOpen.new()
	add_child(still)
	sidebar = Sidebar.new(home)
	add_child(sidebar)
	confirm = Confirm.new()
	add_child(confirm)
	toast = Toast.new()
	add_child(toast)
	_build_off()
	_cover = ColorRect.new()
	_cover.size = Tokens.BASE_SIZE
	_cover.color = Color(Tokens.BLACK, 0.0)
	_cover.visible = false
	_cover.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_cover)

	state.changed.connect(_on_changed)
	state.sidebar_focus_changed.connect(sidebar.set_focus)
	state.confirm_focus_changed.connect(confirm.set_focus)
	state.still_focus_changed.connect(still.set_focus)
	state.force_close_confirmed.connect(func(): daemon.force_close(still.wids()))
	settings.closed.connect(func(): state.go(State.Screen.HOME))
	settings.apps_changed.connect(home.reload)
	settings.prefs_changed.connect(apply_prefs)
	settings.launch_panel.connect(_launch_panel)
	settings.remove_requested.connect(func(app):
		_removing = app
		state.ask("remove"))
	state.remove_confirmed.connect(func(): settings.remove_app(_removing.get("id", "")))
	settings.picture_requested.connect(_on_picture_requested)
	setup.picture_done.connect(_on_picture_done)
	setup.changed.connect(settings.refresh)
	setup.wifi_done.connect(_on_wifi_done)
	settings.wifi_message.connect(toast.push)
	state.picture_kept.connect(_keep_picture)
	home.launch_requested.connect(_launch)
	home.launch_faded.connect(_on_launch_faded)
	daemon.app_window.connect(_on_app_window)
	daemon.app_exited.connect(_on_app_exited)
	daemon.launch_failed.connect(_on_launch_failed)
	daemon.launch_timed_out.connect(_on_launch_timed_out)
	daemon.show_home.connect(_on_show_home)
	daemon.power_pressed.connect(_on_power_pressed)
	daemon.memory_warning.connect(_on_memory_warning)
	daemon.still_open.connect(_on_still_open)
	daemon.accept_pressed.connect(_on_remote_accept)
	print("session type: %s" % OS.get_environment("XDG_SESSION_TYPE"))
	apply_prefs(Prefs.load_prefs(state_path))
	setup.start()


## Reduce motion, screen size and button names, from Settings or state.json.
func apply_prefs(p: Dictionary) -> void:
	Motion.reduce = p.reduce_motion
	pivot_offset = Vector2(Tokens.BASE_SIZE) / 2.0
	scale = Vector2.ONE * p.ui_scale
	var im := get_node_or_null("/root/InputMode")
	if im:
		im.set_glyph_style(p.glyph_style)
	if _picture_old.is_empty():          # not while a new picture is on trial
		setup.configure(p)


# Picture (D79): try the new mode, then ask to keep it. Cancel, Back, Home or
# PICTURE_KEEP seconds with no answer put the old one back.
func _on_picture_requested(mode: String) -> void:
	if not _picture_old.is_empty():
		return                           # one change at a time
	_picture_old = settings.prefs.display_mode
	_picture_new = mode
	setup.try_picture(mode)


func _on_picture_done(r: Dictionary) -> void:
	if _picture_old.is_empty():
		return
	if not r.get("ok", false):
		toast.push("Couldn't change the picture")
		_undo_picture()
		return
	_picture_new = r.mode
	if not r.changed:
		_keep_picture()                  # it was on that already
		return
	if state.screen != State.Screen.SETTINGS:
		_undo_picture()                  # left Settings while it changed
		return
	state.ask("picture")
	_picture_timer.start(Tokens.PICTURE_KEEP)


# Wi-Fi (D81): a saved network whose password stopped working asks for it.
func _on_wifi_done(r: Dictionary) -> void:
	if r.ok:
		toast.push("Connected to %s" % r.ssid)
	elif r.error == "password" and not r.get("tried_password", false) and state.screen == State.Screen.SETTINGS:
		settings.ask_wifi_password(settings.wifi_net(r.ssid))
	elif r.error == "password":
		toast.push("The password for %s didn't work" % r.ssid)
	else:
		toast.push("Couldn't connect to %s" % r.ssid)


func _keep_picture() -> void:
	_picture_timer.stop()
	settings.keep_picture(_picture_new)
	setup.display_mode = _picture_new
	_picture_old = ""


func _undo_picture() -> void:
	_picture_timer.stop()
	setup.undo_picture(_picture_old)
	_picture_old = ""


# The daemon saw OK on a remote that X has no key for (D82): press Accept.
func _on_remote_accept() -> void:
	if is_hidden:
		return
	for down in [true, false]:
		var ev := InputEventAction.new()
		ev.action = "accept"
		ev.pressed = down
		Input.parse_input_event(ev)


# Return to Bosca Mor ended with windows still open.
func _on_still_open(apps: Array) -> void:
	if apps.is_empty():
		_on_show_home()
		return
	show_launcher()
	still.open(apps)
	state.show_still_open()


# SPEC Memory watch: shown as a toast, now or the next time the launcher appears.
func _on_memory_warning(app_id: String, mb: int) -> void:
	var note := "%d MB free%s" % [mb, " while %s ran" % app_id if app_id else ""]
	print("memory low: " + note)
	settings.memory_note = note
	toast.push("Memory ran low while %s was open" % app_name(app_id) if app_id else "Memory ran low")


func _launch(app: Dictionary) -> void:
	_launched = app
	_window_seen = false
	daemon.launch(app)


func _launch_panel(app: Dictionary) -> void:
	_panel_running = true
	_launch(app)
	_await_window()


func _on_launch_faded() -> void:
	_await_window()


# Paused and black, but still on screen until the app's window is up, so the
# desktop never shows between Home and the app.
func _await_window() -> void:
	if _window_seen:
		hide_launcher(false)
		return
	# Off screen for the daemon (Home closes the app), but still drawing the
	# loading screen, at a capped frame rate, until the app's window is up (D76).
	_leave()
	waiting_for_window = true
	loader.start(_launched)
	Engine.max_fps = Tokens.LOADER_FPS


# The daemon has raised the app's first window above the launcher, which
# stays where it is: black, paused, behind the app (D69).
func _on_app_window(_app_id: String) -> void:
	_window_seen = true
	if waiting_for_window:
		waiting_for_window = false
		_stop_loader()
		_sleep(false)


func _stop_loader() -> void:
	loader.stop()
	Engine.max_fps = 0


## The name to show for an app id: the launched app, then Home's tiles.
func app_name(app_id: String) -> String:
	if _launched.get("id") == app_id and _launched.has("name"):
		return _launched.name
	var i: int = home.index_of(app_id)
	return home.apps[i].name if i >= 0 else app_id


# Daemon events ----------------------------------------------------------------

func _on_app_exited(_app_id: String, _code: int) -> void:
	if _panel_running:
		_panel_running = false
		show_launcher()
	elif home.is_launching():
		show_launcher()
		home.play_return()


func _on_launch_failed(app_id: String, error: String) -> void:
	push_warning("could not start %s: %s" % [app_id, error])
	toast.push("Couldn't open %s" % app_name(app_id))
	_on_app_exited(app_id, -1)


# SPEC: no window within 15 s, so back to Home with a toast naming the app.
# The daemon ends the app itself (D63).
func _on_launch_timed_out(app_id: String) -> void:
	toast.push("%s took too long to open" % app_name(app_id))
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

## After the launch fade, or on Desktop: pause, free the blur and stop
## tweens, sleep longer between main-loop wakeups, and minimise (unless an
## app's window is still on its way).
func hide_launcher(minimize := true) -> void:
	if is_hidden:
		return
	_leave()
	_sleep(minimize)


# Off screen as far as the daemon is concerned: it acts on Home now.
func _leave() -> void:
	is_hidden = true
	daemon.set_visible(false)
	home.save_focus()
	sidebar.close(false)
	confirm.close(false)
	toast.hold()
	Motion.stop_all()


# Nothing left to draw: pause, sleep longer, and minimise if asked.
func _sleep(minimize: bool) -> void:
	if _asleep:
		return
	_asleep = true
	_shown_sleep_usec = OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode_sleep_usec = Tokens.HIDDEN_SLEEP_USEC
	get_tree().paused = true
	if minimize:
		_minimize_window()   # last: minimising can deliver window events at once


## The reverse: unpause first so the return fade can run.
func show_launcher() -> void:
	if not is_hidden:
		return
	is_hidden = false
	waiting_for_window = false
	_stop_loader()
	get_tree().paused = false
	Motion.stop(_cover, "color:a")
	_cover.color.a = 0.0
	_cover.visible = false
	if _asleep:
		_asleep = false
		OS.low_processor_usage_mode_sleep_usec = _shown_sleep_usec
	_restore_window()
	if not home.is_launching():
		home.set_focus(home.focus, false)   # settle anything a stopped tween left
	home.refresh()
	toast.release()
	daemon.set_visible(true)
	setup.check()                      # an app or the TV may have changed the picture


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
	if from == State.Screen.CONFIRM and state.confirm_kind == "picture" and not _picture_old.is_empty():
		_undo_picture()                  # left the confirm without Keep
	if to == State.Screen.SETTINGS:
		if from == State.Screen.CONFIRM and state.confirm_kind in ["remove", "picture"]:
			settings.resume()        # back where it was, not reset to the top
		else:
			settings.open()
	elif not (to == State.Screen.CONFIRM and from == State.Screen.SETTINGS):
		settings.close()
	# Still open stays under its force-close confirm.
	if to != State.Screen.STILL_OPEN and not (to == State.Screen.CONFIRM and state.confirm_kind == "forceclose"):
		still.close()
	match to:
		State.Screen.SETTINGS:
			sidebar.close(animate)
			confirm.close(animate)
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
			confirm.open(state.confirm_kind, animate, still.apps.size(), _removing.get("name", ""))
		State.Screen.STILL_OPEN:
			confirm.close(animate)
			sidebar.close(false)
		State.Screen.DESKTOP:
			# Fade to black first, so minimising isn't the first thing seen.
			if animate:
				_cover.visible = true
				Motion.to(_cover, "color:a", 1.0, "launch").finished.connect(_to_desktop)
			else:
				_to_desktop()
		State.Screen.OFF:
			sidebar.close(false)
			confirm.close(false)
			_off_text.text = OFF_TEXT[state.confirm_kind]
			_off.visible = true
			home.save_focus()
			daemon.power(state.confirm_kind)


func _to_desktop() -> void:
	if state.screen != State.Screen.DESKTOP or is_hidden:
		return
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


## How often the launcher asked to minimise (tests: never for an app, D69).
var minimize_requests := 0


func _minimize_window() -> void:
	minimize_requests += 1
	if DisplayServer.get_name() == "headless" or get_viewport() != get_window():
		return
	if _minimized:
		return
	_window_mode = get_window().mode
	get_window().mode = Window.MODE_MINIMIZED
	_minimized = true


## Restores only a window this script minimised: one that stayed up black
## while an app failed to open keeps its mode.
func _restore_window() -> void:
	if DisplayServer.get_name() == "headless" or get_viewport() != get_window():
		return
	if _minimized:
		_minimized = false
		get_window().mode = _window_mode
	# Behind an app, or back from the desktop: take the focus (the daemon
	# also raises this window with wmctrl, D69).
	get_window().grab_focus()


# On the dev machine there is no daemon to bring the launcher back, so
# focusing its window again does it (D23).
# Minimising itself can deliver a focus-in, so only a window that is no longer
# minimised counts, checked once that event has settled.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and state.screen == State.Screen.DESKTOP:
		_refocused.call_deferred()


func _refocused() -> void:
	if state.screen == State.Screen.DESKTOP and get_window().mode != Window.MODE_MINIMIZED and DisplayServer.get_name() != "headless":
		state.show_home()
