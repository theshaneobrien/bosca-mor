extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const Tokens := preload("res://theme/tokens.gd")
const S := State.Screen

# The SPEC navigation table, one row per cell. Each case starts with Home
# focused on tile 2, the sidebar on Settings (1), the confirm on Cancel (0).
# want: screen after, plus any of home_focus, sidebar_focus, confirm_focus,
# confirm_kind, calls (daemon), settings (requested).
const CELLS := [
	[S.HOME, "nav_left", {"screen": S.HOME, "home_focus": 1}],
	[S.HOME, "nav_right", {"screen": S.HOME, "home_focus": 3}],
	[S.HOME, "nav_up", {"screen": S.HOME, "home_focus": 2}],
	[S.HOME, "nav_down", {"screen": S.HOME, "home_focus": 2}],
	[S.HOME, "accept", {"screen": S.HOME, "calls": [["launch", "jellyfin"]]}],
	[S.HOME, "back", {"screen": S.SIDEBAR, "sidebar_focus": 0}],
	[S.HOME, "menu", {"screen": S.SIDEBAR, "sidebar_focus": 0}],
	[S.HOME, "home", {"screen": S.HOME, "home_focus": 2}],
	[S.HOME, "power", {"screen": S.CONFIRM, "confirm_kind": "poweroff", "confirm_focus": 0}],

	[S.SIDEBAR, "nav_left", {"screen": S.SIDEBAR, "sidebar_focus": 1}],
	[S.SIDEBAR, "nav_right", {"screen": S.SIDEBAR, "sidebar_focus": 1}],
	[S.SIDEBAR, "nav_up", {"screen": S.SIDEBAR, "sidebar_focus": 0}],
	[S.SIDEBAR, "nav_down", {"screen": S.SIDEBAR, "sidebar_focus": 2}],
	[S.SIDEBAR, "accept", {"screen": S.SETTINGS}],
	[S.SIDEBAR, "back", {"screen": S.HOME, "home_focus": 2}],
	[S.SIDEBAR, "menu", {"screen": S.HOME, "home_focus": 2}],
	[S.SIDEBAR, "home", {"screen": S.HOME, "home_focus": 2}],
	[S.SIDEBAR, "power", {"screen": S.CONFIRM, "confirm_kind": "poweroff", "confirm_focus": 0}],

	[S.CONFIRM, "nav_left", {"screen": S.CONFIRM, "confirm_focus": 0}],
	[S.CONFIRM, "nav_right", {"screen": S.CONFIRM, "confirm_focus": 1}],
	[S.CONFIRM, "nav_up", {"screen": S.CONFIRM, "confirm_focus": 0}],
	[S.CONFIRM, "nav_down", {"screen": S.CONFIRM, "confirm_focus": 0}],
	[S.CONFIRM, "accept", {"screen": S.SIDEBAR, "calls": []}],
	[S.CONFIRM, "back", {"screen": S.SIDEBAR}],
	[S.CONFIRM, "menu", {"screen": S.CONFIRM, "confirm_focus": 0}],
	[S.CONFIRM, "home", {"screen": S.HOME}],
	[S.CONFIRM, "power", {"screen": S.CONFIRM, "confirm_focus": 0}],
]

var main: Control
var settings_asked := false


func _setup() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		im._set_mode(InputModeScript.Mode.REMOTE)
		im.release_all()
	await tree.process_frame
	await tree.process_frame


func _teardown() -> void:
	main.free()


func _start(screen: S) -> void:
	main.home.set_focus(2, false)
	match screen:
		S.SIDEBAR:
			main.state.handle("back")
			main.state.set_sidebar_focus(1)
		S.CONFIRM:
			main.state.ask("poweroff")
	main.daemon.calls.clear()
	settings_asked = false


func _act(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	tree.root.push_input(a, true)


func _click(pos: Vector2) -> void:
	var im = tree.root.get_node("InputMode")
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = pos
		e.global_position = pos
		e.pressed = pressed
		tree.root.push_input(e, true)


func test_every_cell() -> void:
	await _setup()
	for c in CELLS:
		_start(c[0])
		eq(main.state.screen, c[0], "start in %s" % S.keys()[c[0]])
		_act(c[1])
		var want: Dictionary = c[2]
		var cell := "%s / %s" % [S.keys()[c[0]], c[1]]
		eq(main.state.screen, want.screen, cell + ": screen")
		if want.has("home_focus"):
			eq(main.home.focus, want.home_focus, cell + ": home focus")
		if want.has("sidebar_focus"):
			eq(main.state.sidebar_focus, want.sidebar_focus, cell + ": sidebar focus")
			eq(main.sidebar.focus, want.sidebar_focus, cell + ": sidebar shows focus")
		if want.has("confirm_focus"):
			eq(main.state.confirm_focus, want.confirm_focus, cell + ": confirm focus")
			eq(main.confirm.focus, want.confirm_focus, cell + ": confirm shows focus")
		if want.has("confirm_kind"):
			eq(main.state.confirm_kind, want.confirm_kind, cell + ": confirm kind")
		if want.has("calls"):
			eq(main.daemon.calls, want.calls, cell + ": daemon calls")
		if want.has("settings"):
			eq(settings_asked, want.settings, cell + ": settings requested")
		# Leave Home ready for the next case.
		if main.home.is_launching():
			main.home.play_return()
		main.state.go(S.HOME)
	_teardown()


func test_views_follow_screen() -> void:
	await _setup()
	_start(S.SIDEBAR)
	check(main.sidebar.visible and main.sidebar.is_open, "sidebar shown")
	eq(main.home.accepting_input, false, "Home ignores input under the sidebar")
	_act("power")
	check(main.confirm.visible, "confirm shown")
	check(not main.sidebar.visible, "sidebar hidden under the confirm")
	eq(main.confirm.title(), "Power off this device?", "power title")
	_act("back")
	check(main.sidebar.visible and not main.confirm.visible, "back to the sidebar")
	_act("back")
	check(not main.sidebar.visible and not main.confirm.visible, "Home alone")
	eq(main.home.accepting_input, true, "Home takes input again")
	_teardown()


func test_sidebar_skips_divider_and_stops_at_ends() -> void:
	await _setup()
	_start(S.SIDEBAR)
	main.state.set_sidebar_focus(2)
	_act("nav_down")
	eq(main.state.sidebar_focus, 3, "desktop to restart, over the divider")
	_act("nav_down")
	_act("nav_down")
	eq(main.state.sidebar_focus, 4, "stops at Power off")
	for i in 6:
		_act("nav_up")
	eq(main.state.sidebar_focus, 0, "stops at Home")
	_teardown()


func test_sidebar_items() -> void:
	await _setup()
	var runs := {
		0: {"screen": S.HOME},
		2: {"screen": S.DESKTOP, "calls": [["show_desktop"]]},
		3: {"screen": S.CONFIRM, "kind": "restart"},
		4: {"screen": S.CONFIRM, "kind": "poweroff"},
	}
	for i in runs:
		_start(S.SIDEBAR)
		main.state.set_sidebar_focus(i)
		_act("accept")
		var want: Dictionary = runs[i]
		eq(main.state.screen, want.screen, "item %d" % i)
		if want.has("calls"):
			eq(main.daemon.calls, want.calls, "item %d calls" % i)
		if want.has("kind"):
			eq(main.state.confirm_kind, want.kind, "item %d kind" % i)
			eq(main.state.confirm_focus, 0, "item %d opens on Cancel" % i)
		main.state.go(S.HOME)
	_teardown()


func test_confirm_always_opens_on_cancel() -> void:
	await _setup()
	_start(S.CONFIRM)
	_act("nav_right")
	eq(main.state.confirm_focus, 1, "moved to the action")
	_act("back")
	_act("power")
	eq(main.state.confirm_focus, 0, "reopened on Cancel")
	eq(main.confirm.focus, 0, "Cancel shown focused")
	_teardown()


func test_confirm_action_powers_off_once() -> void:
	await _setup()
	for kind in ["poweroff", "restart"]:
		main.home.set_focus(2, false)
		main.state.ask(kind)
		main.daemon.calls.clear()
		_act("nav_right")
		_act("accept")
		eq(main.state.screen, S.OFF, kind + ": off screen")
		eq(main.daemon.calls, [["power", kind]], kind + ": one daemon call")
		_act("accept")
		_act("home")
		eq(main.daemon.calls.size(), 1, kind + ": input ignored once off")
		main.daemon.show_home.emit()
		eq(main.state.screen, S.HOME, kind + ": dry run returns Home")
	_teardown()


func test_desktop_and_back() -> void:
	await _setup()
	_start(S.SIDEBAR)
	main.state.run_item("desktop")
	eq(main.state.screen, S.DESKTOP, "desktop")
	check(not main.sidebar.visible, "sidebar closed")
	_act("nav_right")
	eq(main.home.focus, 2, "Home ignores input while hidden")
	main.daemon.show_home.emit()
	eq(main.state.screen, S.HOME, "daemon brings Home back")
	_teardown()


func test_daemon_power_key() -> void:
	await _setup()
	_start(S.HOME)
	main.daemon.power_pressed.emit()
	eq(main.state.screen, S.CONFIRM, "power key opens the confirm")
	eq(main.state.confirm_focus, 0, "on Cancel")
	_teardown()


func test_mouse_in_sidebar_and_confirm() -> void:
	await _setup()
	_start(S.SIDEBAR)
	await tree.process_frame
	var item_rect: Rect2 = main.sidebar._items[4].get_global_rect()
	_click(item_rect.get_center())
	eq(main.state.screen, S.CONFIRM, "click Power off opens the confirm")
	var cancel: Rect2 = main.confirm._buttons[0].get_global_rect()
	_click(cancel.get_center())
	eq(main.state.screen, S.SIDEBAR, "click Cancel returns to the sidebar")
	_click(Vector2(1500, 500))
	eq(main.state.screen, S.HOME, "click the dimmed area closes the sidebar")
	_teardown()


func test_launch_routes_to_daemon_and_returns() -> void:
	await _setup()
	_start(S.HOME)
	_act("accept")
	eq(main.daemon.calls, [["launch", "jellyfin"]], "launch")
	check(main.home.is_launching(), "launching")
	_act("back")
	eq(main.state.screen, S.HOME, "no sidebar while launching")
	main.daemon.app_exited.emit("jellyfin", 0)
	check(not main.home.is_launching(), "back from the app")
	eq(main.home.focus, 2, "same tile")
	_teardown()


func test_daemon_power_shows_launcher_over_anything() -> void:
	await _setup()
	_start(S.SIDEBAR)
	main.state.run_item("desktop")
	main.daemon.power_pressed.emit()
	eq(main.state.screen, S.CONFIRM, "from Desktop")
	_start(S.HOME)
	_act("accept")
	main.daemon.power_pressed.emit()
	check(not main.home.is_launching(), "launch fade undone")
	eq(main.state.screen, S.CONFIRM, "from a launch")
	_teardown()


func test_launch_failed_returns_home() -> void:
	await _setup()
	_start(S.HOME)
	_act("accept")
	main.daemon.launch_failed.emit("jellyfin", "No such file")
	check(not main.home.is_launching(), "back on Home")
	_teardown()


const STILL := [
	{"wid": "0x3a00007", "name": "LibreOffice Writer", "icon": "", "asking": true},
	{"wid": "0x4400002", "name": "Text Editor", "icon": "", "asking": false},
]


func _still() -> void:
	main.state.run_item("desktop")
	main.daemon.calls.clear()
	main.daemon.still_open.emit(STILL)


func test_still_open_screen() -> void:
	await _setup()
	_still()
	eq(main.state.screen, S.STILL_OPEN, "Still open shown")
	check(not main.is_hidden, "launcher back on screen")
	eq(main.still.title(), "2 apps are still open", "title")
	eq(main.state.still_focus, 0, "Show me focused")
	_act("nav_left")
	eq(main.state.still_focus, 0, "stops at the left")
	_act("nav_right")
	_act("nav_right")
	_act("nav_right")
	eq(main.state.still_focus, 2, "stops at the right")
	_act("nav_up")
	_act("menu")
	eq(main.state.screen, S.STILL_OPEN, "Up and Menu do nothing")
	_teardown()


func test_show_me_raises_the_first_window() -> void:
	await _setup()
	_still()
	_act("accept")
	eq(main.state.screen, S.DESKTOP, "launcher hides")
	check(main.is_hidden, "hidden")
	eq(main.daemon.calls, [["show_window", "0x3a00007"]], "raise the first, no notification")
	_teardown()


func test_back_to_desktop_closes_nothing() -> void:
	await _setup()
	_still()
	_act("back")
	eq(main.state.screen, S.DESKTOP, "Back is Back to desktop")
	eq(main.daemon.calls, [["back_to_desktop"]], "no force close, no notification")
	_still()
	main.state.set_still_focus(2)
	_act("accept")
	eq(main.daemon.calls, [["back_to_desktop"]], "the button too")
	_teardown()


func test_close_anyway_confirms_first() -> void:
	await _setup()
	_still()
	_act("nav_right")
	_act("accept")
	eq(main.state.screen, S.CONFIRM, "confirm")
	eq(main.state.confirm_kind, "forceclose", "force-close confirm")
	eq(main.confirm.title(), "Close 2 apps?", "title counts the apps")
	eq(main.state.confirm_focus, 0, "Cancel focused")
	check(main.still.visible, "Still open stays underneath")
	_act("accept")
	eq(main.state.screen, S.STILL_OPEN, "Cancel returns to Still open")
	eq(main.daemon.calls, [], "nothing closed")
	_act("accept")
	_act("back")
	eq(main.state.screen, S.STILL_OPEN, "Back returns to Still open")
	_act("accept")
	_act("nav_right")
	_act("accept")
	eq(main.daemon.calls, [["force_close", "0x3a00007", "0x4400002"]], "xkill both, by window id")
	eq(main.state.screen, S.HOME, "then Home")
	check(not main.still.visible, "Still open gone")
	_teardown()


func test_one_app_still_open() -> void:
	await _setup()
	main.state.run_item("desktop")
	main.daemon.still_open.emit([STILL[1]])
	eq(main.still.title(), "1 app is still open", "singular")
	main.state.set_still_focus(1)
	_act("accept")
	eq(main.confirm.title(), "Close 1 app?", "singular confirm")
	_teardown()


func test_return_with_nothing_left_shows_home() -> void:
	await _setup()
	main.state.run_item("desktop")
	main.daemon.show_home.emit()
	eq(main.state.screen, S.HOME, "Home")
	check(main.home._fade.visible, "with the return fade")
	_teardown()


# Box test: Settings from the sidebar left the sidebar on top, so Settings
# took input unseen and needed two or three Backs to leave.
func test_settings_from_the_sidebar_closes_it() -> void:
	await _setup()
	_start(S.SIDEBAR)
	main.state.set_sidebar_focus(1)
	_act("accept")
	eq(main.state.screen, S.SETTINGS, "Settings")
	check(not main.sidebar.visible and not main.sidebar.is_open, "sidebar closed")
	check(main.settings.visible, "Settings shown")
	eq(main.home.scale, Vector2.ONE, "Home no longer shrunk behind")
	_act("back")
	eq(main.state.screen, S.HOME, "one Back from the section list returns Home")
	_teardown()


# Box test: with no daemon, every launch pretended to work. On Linux it now
# fails with a toast.
func test_no_daemon_on_linux_fails_visibly() -> void:
	await _setup()
	main.daemon.stand_in = false
	_start(S.HOME)
	_act("accept")
	await tree.process_frame
	check(not main.home.is_launching(), "back on Home")
	check(main.toast.visible, "toast shown")
	_teardown()


# And Power off with no daemon doesn't pretend: straight back to Home, saying so.
func test_no_daemon_on_linux_power_says_so() -> void:
	await _setup()
	main.daemon.stand_in = false
	main.state.ask("poweroff")
	main.state.set_confirm_focus(1)
	main.state.handle("accept")
	eq(main.state.screen, S.OFF, "Shutting down")
	await tree.process_frame
	eq(main.state.screen, S.HOME, "straight back to Home")
	check(not main._off.visible, "off screen gone")
	eq(main.toast.text, "Couldn't power off", "toast")
	_teardown()


func test_power_failed_from_the_daemon_returns_home() -> void:
	await _setup()
	main.daemon.stand_in = true
	main.state.ask("restart")
	main.state.set_confirm_focus(1)
	main.state.handle("accept")
	eq(main.state.screen, S.OFF, "Restarting")
	main.daemon._dispatch({"evt": "power_failed", "action": "reboot"})
	eq(main.state.screen, S.HOME, "back to Home")
	eq(main.toast.text, "Couldn't restart", "toast")
	main.daemon._dispatch({"evt": "power_failed", "action": "poweroff"})
	eq(main.toast.queue.size(), 0, "nothing more once off that screen")
	_teardown()


# While a Cinnamon panel opens, Settings takes no input: a second OK used to
# launch it twice, and Back could leave Settings unseen.
func test_panel_opening_takes_no_input() -> void:
	await _setup()
	main.state.go(S.SETTINGS)
	_act("nav_down")
	_act("nav_down")
	_act("nav_right")
	main.daemon.calls.clear()
	_act("accept")
	_act("accept")
	eq(main.daemon.calls, [["launch", "network-settings"]], "launched once")
	_act("back")
	_act("back")
	eq(main.state.screen, S.SETTINGS, "Back does nothing while it opens")
	check(main.loader.active, "loading screen started")
	check(main.loader.get_index() > main.settings.get_index(), "drawn over Settings")
	main.daemon.app_window.emit("network-settings")
	main.daemon.app_exited.emit("network-settings", 0)
	check(not main.is_hidden, "back when it closes")
	check(main.settings.accepting_input, "Settings takes input again")
	_teardown()


func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	tree.root.push_input(e, true)


# The remote's Power reaches the launcher only through the daemon. It counts
# as a key press (remote mode), and a pointer resting on the action button
# when the confirm opens can't take the focus off Cancel by jitter (Law 2).
func test_power_from_the_daemon_keeps_cancel_focused() -> void:
	await _setup()
	var im = tree.root.get_node("InputMode")
	im._set_mode(InputModeScript.Mode.POINTER)
	main.daemon.power_pressed.emit()
	eq(im.mode, InputModeScript.Mode.REMOTE, "remote mode")
	eq(main.state.confirm_focus, 0, "Cancel focused")
	await tree.process_frame
	im._set_mode(InputModeScript.Mode.POINTER)
	var action: Vector2 = main.confirm._buttons[1].get_global_rect().get_center()
	_move(action)
	_move(action + Vector2(1, 0))
	_move(action + Vector2(-2, 1))
	eq(main.state.confirm_focus, 0, "jitter leaves Cancel focused")
	_move(action + Vector2(Tokens.POINTER_MOVE + 10, 0))
	eq(main.state.confirm_focus, 1, "a real move still points at it")
	main.state.set_confirm_focus(0)
	im._set_mode(InputModeScript.Mode.POINTER)
	main.daemon.accept_pressed.emit()
	eq(im.mode, InputModeScript.Mode.REMOTE, "the daemon's OK too")
	await tree.process_frame         # its Accept arrives with the next frame: let it land here
	await tree.process_frame
	eq(main.state.screen, S.SIDEBAR, "and it pressed Cancel")
	_teardown()
