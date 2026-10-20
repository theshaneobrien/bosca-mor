extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const Motion := preload("res://scripts/motion.gd")
const Prefs := preload("res://scripts/prefs.gd")
const StateFile := preload("res://scripts/state_file.gd")
const Autostart := preload("res://scripts/autostart.gd")
const DesktopEntries := preload("res://scripts/desktop_entries.gd")
const OSK := preload("res://scripts/osk.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")

var dir: String
var apps_path: String
var state_path: String
var main: Control
var st: Control


# A Main reading and writing apps.json and state.json in a fresh folder.
# The apps file is the default set plus one broken entry that must survive.
func _setup(extra := [{"id": "broken"}]) -> void:
	dir = ProjectSettings.globalize_path("user://test-settings-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	apps_path = dir.path_join("apps.json")
	state_path = dir.path_join("state.json")
	var entries: Array = JSON.parse_string(FileAccess.get_file_as_string(Apps.DEFAULT_PATH))
	entries.append_array(extra)
	Apps.save_file(apps_path, entries)
	await _start_main()


func _start_main() -> void:
	main = MainScene.instantiate()
	main.apps_path = apps_path
	main.state_path = state_path
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	st = main.settings
	st.desktop_dirs = ["res://tests/fixtures/desktop"]
	st.autostart_path = dir.path_join("autostart.desktop")
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		im._set_mode(InputModeScript.Mode.REMOTE)
		im.release_all()
	await tree.process_frame
	main.state.go(State.Screen.SETTINGS)


func _teardown() -> void:
	main.free()
	Motion.reduce = false
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		im.set_glyph_style("auto")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _act(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	tree.root.push_input(a, true)


func _key(unicode: int, keycode := KEY_NONE) -> void:
	var e := InputEventKey.new()
	e.pressed = true
	e.unicode = unicode
	e.keycode = keycode
	tree.root.push_input(e, true)


func _file_ids() -> Array:
	var data: Array = JSON.parse_string(FileAccess.get_file_as_string(apps_path))
	return data.map(func(e): return e.get("id", "?"))


func _file_entry(id: String) -> Dictionary:
	var data: Array = JSON.parse_string(FileAccess.get_file_as_string(apps_path))
	for e in data:
		if e.get("id") == id:
			return e
	return {}


func _home_ids() -> Array:
	return main.home.apps.map(func(a): return a.id)


func _check_written(when: String) -> void:
	check(not FileAccess.file_exists(apps_path + ".tmp"), when + ": no temp file left")
	check(JSON.parse_string(FileAccess.get_file_as_string(apps_path)) is Array, when + ": file parses")
	eq(_file_ids()[-1], "broken", when + ": broken entry kept")


# Settings column of the navigation table ----------------------------------------

func test_settings_column() -> void:
	await _setup()
	eq(st.level, "nav", "opens on the section list")
	_act("nav_down")
	eq(st.section_id(), "display", "Down moves through sections")
	_act("nav_up")
	_act("nav_up")
	eq(st.section_id(), "apps", "stops at the top")
	_act("nav_left")
	eq(st.level, "nav", "Left on the list does nothing")
	_act("nav_right")
	eq(st.level, "content", "Right goes into content")
	_act("nav_left")
	eq(st.level, "nav", "Left from content goes to the list")
	_act("accept")
	eq(st.level, "content", "Accept opens the section")
	_act("back")
	eq(st.level, "nav", "Back goes up one level")
	_act("menu")
	eq(main.state.screen, State.Screen.SETTINGS, "Menu does nothing")
	_act("back")
	eq(main.state.screen, State.Screen.HOME, "Back at the top returns Home")
	main.state.go(State.Screen.SETTINGS)
	_act("nav_right")
	_act("home")
	eq(main.state.screen, State.Screen.HOME, "Home returns Home from content")
	main.state.go(State.Screen.SETTINGS)
	_act("power")
	eq(main.state.screen, State.Screen.CONFIRM, "Power opens the confirm")
	eq(main.state.confirm_focus, 0, "on Cancel")
	_act("back")
	eq(main.state.screen, State.Screen.SIDEBAR, "confirm Back returns to the sidebar")
	_teardown()


# Apps: hide, reorder, start page, add ---------------------------------------------

func test_hide_writes_and_survives_reload() -> void:
	await _setup()
	_act("nav_right")
	eq(st._current().app.id, "youtube", "first app row focused")
	_act("nav_down")
	_act("accept")
	eq(_file_entry("plex").get("hidden"), true, "plex hidden in the file")
	_check_written("hide")
	check(not "plex" in _home_ids(), "Home dropped Plex")
	main.free()
	await _start_main()
	check(not "plex" in _home_ids(), "still hidden after a restart")
	st.open()
	_act("nav_right")
	_act("nav_down")
	_act("accept")
	eq(_file_entry("plex").has("hidden"), false, "shown again, key removed")
	check("plex" in _home_ids(), "Home has Plex again")
	_teardown()


func test_reorder_writes_and_survives_reload() -> void:
	await _setup()
	_act("nav_right")
	_act("move")
	check(st.moving, "picked up YouTube")
	eq(st.hint_words(), ["Put it here"], "move hint")
	_act("nav_down")
	_act("nav_down")
	eq(_file_ids()[0], "youtube", "not written until dropped")
	_act("move")
	check(not st.moving, "dropped")
	eq(_file_ids().slice(0, 4), ["plex", "jellyfin", "youtube", "netflix"], "new order in the file")
	_check_written("reorder")
	eq(_home_ids().slice(0, 3), ["plex", "jellyfin", "youtube"], "Home follows")
	eq(st._current().app.id, "youtube", "focus stays on the moved app")
	main.free()
	await _start_main()
	eq(_home_ids().slice(0, 3), ["plex", "jellyfin", "youtube"], "order survives a restart")
	_teardown()


func test_move_stops_at_the_ends() -> void:
	await _setup()
	_act("nav_right")
	_act("move")
	_act("nav_up")
	_act("back")
	eq(_file_ids()[0], "youtube", "can't move above the first")
	_teardown()


# Walks the D-pad to a key and presses it, the way a remote would.
func _dpad_press(osk: Control, label: String) -> void:
	var tr := -1
	var tc := -1
	for r in OSK.ROWS.size():
		for c in OSK.ROWS[r].size():
			if OSK.ROWS[r][c][0] == label:
				tr = r
				tc = c
	check(tr >= 0, "key %s exists" % label)
	for i in 10:
		if osk.row == tr:
			break
		_act("nav_down" if osk.row < tr else "nav_up")
	for i in 12:
		if osk.col == tc:
			break
		_act("nav_right" if osk.col < tc else "nav_left")
	eq(osk.focused_key(), label, "reached %s" % label)
	_act("accept")


func test_osk_types_a_url_with_the_dpad() -> void:
	await _setup()
	_act("nav_right")
	for i in 5:
		_act("nav_down")
	eq(st._current().app.id, "browser", "Browser row")
	_act("nav_right")
	eq(st.col, 1, "start page button")
	_act("accept")
	var osk: Control = st.osk()
	check(osk.visible, "keyboard open")
	eq(osk.text, "https://www.google.com", "starts with the current page")
	eq(osk.focused_key(), "1", "focus starts top left")
	for i in osk.text.length():
		_dpad_press(osk, "Delete")
	eq(osk.text, "", "cleared with Delete")
	for k in ["e", "x", "a", "m", "p", "l", "e", ".com", "/", "t", "v"]:
		_dpad_press(osk, k)
	eq(osk.text, "example.com/tv", "typed")
	_dpad_press(osk, "Done")
	check(not osk.visible, "closed")
	eq(_file_entry("browser").url, "https://example.com/tv", "saved with https://")
	_check_written("start page")
	var browser: Dictionary = main.home.apps.filter(func(a): return a.id == "browser")[0]
	eq(Apps.argv_for(browser)[-1], "https://example.com/tv", "Home launches the new page")
	_teardown()


func test_osk_physical_keyboard_and_cancel() -> void:
	await _setup()
	_act("nav_right")
	for i in 5:
		_act("nav_down")
	_act("nav_right")
	_act("accept")
	var osk: Control = st.osk()
	_key(0, KEY_BACKSPACE)
	eq(osk.text, "https://www.google.co", "Backspace deletes, it doesn't cancel")
	_key("m".unicode_at(0), KEY_M)
	eq(osk.text, "https://www.google.com", "typed m")
	check(not st.moving, "M typed, not Move")
	_key(0, KEY_ESCAPE)
	check(not osk.visible, "Esc cancels")
	eq(_file_entry("browser").url, "https://www.google.com", "unchanged")
	_teardown()


func test_add_from_desktop_entries() -> void:
	await _setup()
	_act("nav_right")
	_act("nav_up")
	eq(st._current().type, "add", "Add app")
	_act("accept")
	eq(st.level, "picker", "picker open")
	var names: Array = st._items.map(func(i): return i.entry.name)
	eq(names, ["Bar Game", "Kodi"], "shown apps only, sorted")
	_act("nav_down")
	_act("accept")
	eq(st.level, "content", "back to the list")
	var kodi := _file_entry("kodi")
	eq(kodi.argv, ["kodi", "--standalone"], "field codes dropped")
	eq(kodi.kind, "Video", "kind from Categories")
	eq(kodi.description, "Media centre", "Comment")
	eq(_file_ids()[-2], "kodi", "added at the end, broken entry still last")
	check("kodi" in _home_ids(), "on Home")
	_check_written("add")
	_act("back")
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	eq(st._items.map(func(i): return i.entry.name), ["Bar Game"], "Kodi not offered twice")
	_act("back")
	eq(st.level, "content", "Back leaves the picker")
	_teardown()


func test_exec_parsing() -> void:
	eq(DesktopEntries.exec_to_argv('/usr/bin/flatpak run --branch=stable "--command=bar game" org.foo.Bar %f "100%%"'),
		["/usr/bin/flatpak", "run", "--branch=stable", "--command=bar game", "org.foo.Bar", "100%"], "quotes, codes, %%")
	eq(DesktopEntries.exec_to_argv('sh -c "echo \\"hi\\""'), ["sh", "-c", 'echo "hi"'], "escaped quotes")
	eq(DesktopEntries.id_for("org.foo.Bar.desktop", {}), "org-foo-bar", "id")
	eq(DesktopEntries.id_for("kodi.desktop", {"kodi": {}}), "kodi-2", "unique id")
	eq(DesktopEntries.parse("[Desktop Entry]\nType=Application\nName=X\nExec=x\nHidden=true\n"), {}, "Hidden skipped")


# Display, Controllers, Startup, Network ---------------------------------------------

func test_display_prefs_persist() -> void:
	await _setup()
	_act("nav_down")
	_act("nav_right")
	eq(st._current().key, "ui_scale", "Screen size row")
	_act("accept")
	eq(main.scale, Vector2.ONE * 0.95, "UI shrinks to 95%")
	_act("nav_down")
	_act("accept")
	check(Motion.reduce, "reduce motion on")
	var saved := StateFile.load_file(state_path)
	eq(saved.get("ui_scale"), 0.95, "scale saved")
	eq(saved.get("reduce_motion"), true, "reduce motion saved")
	check(not FileAccess.file_exists(state_path + ".tmp"), "no temp file")
	main.free()
	Motion.reduce = false
	await _start_main()
	check(Motion.reduce, "reduce motion after a restart")
	eq(main.scale, Vector2.ONE * 0.95, "scale after a restart")
	_teardown()


func test_glyph_style_setting() -> void:
	await _setup()
	var im = tree.root.get_node("InputMode")
	im._set_mode(InputModeScript.Mode.CONTROLLER)
	eq(im.hint_style(), "xbox", "auto with no pad name")
	for i in 4:
		_act("nav_down")
	_act("nav_right")
	_act("accept")
	eq(im.hint_style(), "xbox", "Xbox")
	_act("accept")
	eq(im.hint_style(), "playstation", "PlayStation")
	eq(StateFile.load_file(state_path).get("glyph_style"), "playstation", "saved")
	_act("accept")
	eq(im.glyph_style, "auto", "back to automatic")
	_teardown()


func test_startup_toggle() -> void:
	await _setup()
	for i in 5:
		_act("nav_down")
	_act("nav_right")
	eq(st._current().type, "info", "no autostart entry: shown as not set up")
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/fixtures/autostart.desktop"), st.autostart_path)
	_act("nav_left")
	_act("nav_right")
	eq(st._current().type, "toggle", "entry found")
	check(st._current().on, "on")
	_act("accept")
	check(not Autostart.enabled(st.autostart_path), "turned off")
	var text := FileAccess.get_file_as_string(st.autostart_path)
	check(text.contains("X-GNOME-Autostart-enabled=false") and text.contains("Exec=/opt/boscamor/boscamor"), "rewritten, rest kept: %s" % text)
	_act("accept")
	check(Autostart.enabled(st.autostart_path), "on again")
	_teardown()


func test_network_opens_cinnamon_panel_like_an_app() -> void:
	await _setup()
	_act("nav_down")
	_act("nav_down")
	_act("nav_right")
	_act("accept")
	eq(main.daemon.calls, [["launch", "network-settings"]], "launched through the daemon")
	check(main.is_hidden, "launcher hidden")
	main.daemon.app_exited.emit("network-settings", 0)
	check(not main.is_hidden, "back when it closes")
	eq(main.state.screen, State.Screen.SETTINGS, "still in Settings")
	_teardown()


func test_about_shows_device() -> void:
	await _setup()
	main.daemon.memory_warning.emit("plex", 400)
	for i in 6:
		_act("nav_down")
	_act("nav_right")
	var labels: Array = st._items.map(func(i): return i.label)
	eq(labels, ["Version", "Device name", "IP address", "Memory", "Session", "Last memory warning"], "rows")
	eq(st._items[0].value, ProjectSettings.get_setting("application/config/version"), "version")
	eq(st._items[5].value, "400 MB free while plex ran", "memory warning")
	_teardown()
