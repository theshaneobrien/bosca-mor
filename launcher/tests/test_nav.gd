extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
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
	[S.SIDEBAR, "accept", {"screen": S.SIDEBAR, "settings": true}],
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
	main.state.settings_requested.connect(func(): settings_asked = true)
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
