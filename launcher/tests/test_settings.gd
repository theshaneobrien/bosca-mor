extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const Paths := preload("res://scripts/paths.gd")
const Motion := preload("res://scripts/motion.gd")
const Prefs := preload("res://scripts/prefs.gd")
const StateFile := preload("res://scripts/state_file.gd")
const Autostart := preload("res://scripts/autostart.gd")
const DesktopEntries := preload("res://scripts/desktop_entries.gd")
const OSK := preload("res://scripts/osk.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const IconResolver := preload("res://scripts/icon_resolver.gd")
const Tokens := preload("res://theme/tokens.gd")
const SettingsScript := preload("res://scripts/settings.gd")


# Enough of SystemSetup for the Wi-Fi rows and a join.
class FakeSetup extends Node:
	var enabled := true
	var wifi := {}
	var joining := ""
	var display := {}
	var sound := {}
	var joined: Array = []

	func wifi_scan(_rescan := false) -> void:
		pass

	func wifi_scanning() -> bool:
		return false

	func wifi_join(ssid: String, password: String, known: bool) -> void:
		joined.append([ssid, password, known])

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
	_rm_tree(dir)


func _rm_tree(path: String) -> void:
	for d in DirAccess.get_directories_at(path):
		_rm_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


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


# Walks the D-pad to a key on the page showing and presses it, the way a
# remote would.
func _dpad_press(osk: Control, label: String) -> void:
	var tr := -1
	var tc := -1
	for r in OSK.ROWS.size():
		for c in OSK.ROWS[r].size():
			if osk.label_at(r, c) == label:
				tr = r
				tc = c
	check(tr >= 0, "key %s exists on the %s page" % [label, osk.layer])
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


# Types any printable text with the D-pad alone: Shift for capitals, the
# symbols key for the rest.
func _dpad_type(osk: Control, s: String) -> void:
	for ch in s:
		if not _on_page(osk, ch):
			var want := "symbols" if _in_symbols(ch) else ("upper" if ch != ch.to_lower() else "lower")
			if want == "symbols":
				_dpad_press(osk, OSK.SYMBOLS_KEY)
			elif osk.layer == "symbols" and want == "lower":
				_dpad_press(osk, OSK.LETTERS_KEY)
			else:
				_dpad_press(osk, OSK.SHIFT)
		_dpad_press(osk, ch)


func _on_page(osk: Control, ch: String) -> bool:
	for r in OSK.ROWS.size():
		for c in OSK.ROWS[r].size():
			if osk.label_at(r, c) == ch:
				return true
	return false


func _in_symbols(ch: String) -> bool:
	for r in OSK.SYMBOLS:
		if ch in r:
			return true
	return false


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
	eq(st._items[0].type, "website", "A website comes first")
	var names: Array = st._items.slice(1).map(func(i): return i.entry.name)
	eq(names, ["Bar Game", "Kodi"], "shown apps only, sorted")
	_act("nav_down")
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
	eq(st._items.slice(1).map(func(i): return i.entry.name), ["Bar Game"], "Kodi not offered twice")
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
	# As Flatpak's exporter writes them: single quotes, and every backslash
	# doubled by the string escapes (r"" is the text in the file).
	var fp := DesktopEntries.exec_to_argv(r"/usr/bin/flatpak run --branch=stable --command='bar game' org.foo.Bar -c 'cd /app && ./run' '--x=a,b' %U")
	eq(fp, ["/usr/bin/flatpak", "run", "--branch=stable", "--command=bar game", "org.foo.Bar", "-c", "cd /app && ./run", "--x=a,b"], "single quotes")
	eq(IconResolver.flatpak_id(fp), "org.foo.Bar", "Flatpak id past a quoted --command")
	eq(DesktopEntries.exec_to_argv(r"echo 'it'\\''s'"), ["echo", "it's"], "a quote inside single quotes")
	eq(DesktopEntries.exec_to_argv(r'sh -c "echo \\"hi\\""'), ["sh", "-c", 'echo "hi"'], "escaped quotes, as the spec writes them")
	eq(DesktopEntries.exec_to_argv(r'x "a\\\\b" "c\d"'), ["x", "a\\b", "c\\d"], "a backslash in quotes")
	eq(DesktopEntries.parse("[Desktop Entry]\nType=Application\nName=\nExec=x\n"), {}, "an empty Name is not offered")


# Box finding: a music player was labelled Video (every one lists AudioVideo).
func test_kind_from_categories() -> void:
	eq(DesktopEntries.kind_for("Audio;Music;Player;AudioVideo;"), "Music", "Spotify")
	eq(DesktopEntries.kind_for("GNOME;GTK;AudioVideo;Audio;Player;"), "Music", "Rhythmbox")
	eq(DesktopEntries.kind_for("AudioVideo;Video;Player;"), "Video", "Kodi")
	eq(DesktopEntries.kind_for("AudioVideo;Audio;Video;Player;TV;"), "Video", "mpv")
	eq(DesktopEntries.kind_for("AudioVideo;Player;Recorder;"), "Video", "a generic player")
	eq(DesktopEntries.kind_for("Network;FileTransfer;Game;"), "Games", "Steam")
	eq(DesktopEntries.kind_for("Network;WebBrowser;"), "Web", "a browser")
	eq(DesktopEntries.kind_for("Network;InstantMessaging;"), "Other", "chat is not the web")


# Display, Controllers, Startup, Network ---------------------------------------------

func test_display_prefs_persist() -> void:
	await _setup()
	_act("nav_down")
	_act("nav_right")
	eq(st._current().key, "display_mode", "Picture first")
	_act("nav_down")
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


# A hand-edited entry that starts with a comment: the key must stay inside
# [Desktop Entry], or the whole file stops loading.
func test_startup_toggle_keeps_the_key_in_its_group() -> void:
	var path := ProjectSettings.globalize_path("user://test-autostart-%d.desktop" % Time.get_ticks_usec())
	Apps.write_atomic(path, "# hand edited\n\n[Desktop Entry]\nType=Application\nExec=/opt/boscamor/boscamor\nX-GNOME-Autostart-enabled=true\n\n[Desktop Action other]\nName=Other\nHidden=true\n")
	for on in [false, true]:
		check(Autostart.set_enabled(on, path), "rewritten")
		var lines := FileAccess.get_file_as_string(path).split("\n")
		var head := lines.find("[Desktop Entry]")
		var key := lines.find("X-GNOME-Autostart-enabled=%s" % ("true" if on else "false"))
		check(head >= 0 and key > head and key < lines.find("[Desktop Action other]"), "key inside the group: %s" % [lines])
		eq(Array(lines).filter(func(l): return l.begins_with("X-GNOME-Autostart-enabled")).size(), 1, "one key")
		eq(Autostart.enabled(path), on, "reads back")
		check(lines.has("Hidden=true") and lines.has("# hand edited") and lines.has("Exec=/opt/boscamor/boscamor"), "the rest kept")
	Apps.write_atomic(path, "# no group\nExec=x\n")
	check(not Autostart.set_enabled(false, path), "not a desktop entry: left alone")
	eq(FileAccess.get_file_as_string(path), "# no group\nExec=x\n", "unchanged")
	DirAccess.remove_absolute(path)


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


func _type(text: String) -> void:
	for ch in text:
		_key(ch.unicode_at(0))


# Box test: Add app listed every app on the system. Now it offers Flatpaks
# only, and a website that opens full screen in the browser (D72).
func test_picker_reads_only_the_flatpak_folders() -> void:
	await _setup()
	st.desktop_dirs = []
	var dirs: Array = Paths.flatpak_desktop_dirs()
	eq(dirs.size(), 2, "user and system Flatpak exports")
	for d in dirs:
		check(d.ends_with("flatpak/exports/share/applications"), "a Flatpak export: %s" % d)
	_teardown()


func test_flatpak_on_home_is_not_offered_again() -> void:
	await _setup()
	# A Flatpak whose id is already on Home, even with a different Exec line.
	st.desktop_dirs = [dir]
	var f := FileAccess.open(dir.path_join("tv.plex.PlexHTPC.desktop"), FileAccess.WRITE)
	f.store_string("[Desktop Entry]\nType=Application\nName=Plex HTPC\nExec=/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=Plex tv.plex.PlexHTPC\n")
	f.close()
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	eq(st._items.slice(1).map(func(i): return i.entry.name), [], "Plex is on Home already")
	DirAccess.remove_absolute(dir.path_join("tv.plex.PlexHTPC.desktop"))
	_teardown()


func test_add_a_website() -> void:
	await _setup()
	st.profiles_dir = dir.path_join("profiles")
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	_act("accept")                  # A website
	var osk: Control = st.osk()
	check(osk.visible, "name keyboard open")
	_type("BBC iPlayer")
	eq(osk.text, "BBC iPlayer", "the space bar types a space")
	osk.press("Done")
	check(osk.visible, "address keyboard open")
	_type("bbc.co.uk/iplayer")
	osk.press("Done")
	check(not osk.visible, "done")
	var site := _file_entry("bbc-iplayer")
	eq(site.name, "BBC iPlayer", "name")
	eq(site.url, "https://bbc.co.uk/iplayer", "address, https added")
	eq(site.kind, "Web", "kind")
	eq(site.description, "bbc.co.uk", "described by its host")
	eq(site.url_editable, true, "start page editable")
	var profile: String = dir.path_join("profiles").path_join("bbc-iplayer")
	eq(site.argv, ["firefox", "--kiosk", "--new-instance", "--profile", profile, "{url}"], "Firefox kiosk, own profile")
	check(FileAccess.file_exists(profile.path_join("user.js")), "profile seeded with user.js")
	check(FileAccess.get_file_as_string(profile.path_join("user.js")).contains("media.eme.enabled"), "DRM on")
	check("bbc-iplayer" in _home_ids(), "on Home")
	_check_written("website")
	DirAccess.remove_absolute(profile.path_join("user.js"))
	DirAccess.remove_absolute(profile)
	DirAccess.remove_absolute(dir.path_join("profiles"))
	_teardown()


func test_bundled_user_js_matches_the_installer() -> void:
	var install := ProjectSettings.globalize_path("res://").path_join("../install/files/user.js")
	if FileAccess.file_exists(install):
		eq(FileAccess.get_file_as_string("res://data/user.js"), FileAccess.get_file_as_string(install), "launcher/data/user.js matches install/files")


# Box test: added apps couldn't be removed. Right along an app row reaches
# Remove, which asks first with Cancel focused (D73).
func test_remove_an_app() -> void:
	await _setup()
	_act("nav_right")
	_act("nav_down")                 # Plex
	_act("nav_right")
	eq(st.col, 1, "Remove, after the toggle (Plex has no start page)")
	eq(st.hint_words(), ["Remove", "Back"], "hint")
	_act("nav_right")
	eq(st.col, 1, "Remove is the last stop")
	_act("accept")
	eq(main.state.screen, State.Screen.CONFIRM, "asks first")
	eq(main.confirm.title(), "Remove Plex?", "names the app")
	eq(main.state.confirm_focus, 0, "Cancel focused")
	_act("back")
	eq(main.state.screen, State.Screen.SETTINGS, "Back returns to Settings")
	eq(st.level, "content", "where it was")
	eq(st._current().app.id, "plex", "same row")
	check("plex" in _file_ids(), "nothing removed")
	_act("accept")
	_act("nav_right")
	_act("accept")
	eq(main.state.screen, State.Screen.SETTINGS, "back in Settings")
	check(not "plex" in _file_ids(), "Plex removed from apps.json")
	check(not "plex" in _home_ids(), "and from Home")
	_check_written("remove")
	_teardown()


func test_remove_on_a_row_with_a_start_page() -> void:
	await _setup()
	_act("nav_right")
	for i in 5:
		_act("nav_down")
	eq(st._current().app.id, "browser", "Browser")
	_act("nav_right")
	eq(st.col, 1, "start page first")
	_act("nav_right")
	eq(st.col, 2, "then Remove")
	_act("nav_left")
	_act("nav_left")
	eq(st.col, 0, "back to the row")
	_act("nav_left")
	eq(st.level, "nav", "then the section list")
	_teardown()


func _toasted(msg: String) -> bool:
	return main.toast.text == msg or msg in main.toast.queue


func _click(pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = pos
	e.global_position = pos
	tree.root.push_input(e, true)


func _centre_of(c: Control) -> Vector2:
	return c.get_global_rect().get_center()


func _net(ssid: String, open := false) -> Dictionary:
	return {"ssid": ssid, "signal": 70, "secure": not open, "known": false, "in_use": false, "enterprise": false}


# The Linux export packs only Godot resources unless include_filter names a
# file. Whatever is read from res://data and isn't a resource must be named
# there, or the box build reads "" (user.js was left out, so website
# profiles got an empty one).
func test_export_includes_the_bundled_data() -> void:
	var cfg := ConfigFile.new()
	eq(cfg.load("res://export_presets.cfg"), OK, "presets load")
	eq(cfg.get_value("preset.0", "name", ""), "Linux", "the Linux preset")
	var filters: Array = Array(String(cfg.get_value("preset.0", "include_filter", "")).split(",", false)).map(func(f): return f.strip_edges())
	var plain := []
	for f in DirAccess.get_files_at("res://data"):
		if f.get_extension() in ["import", "uid"]:
			continue
		var path := "res://data".path_join(f)
		if ResourceLoader.exists(path):
			continue        # a resource: exported anyway
		plain.append(f)
		check(filters.any(func(p): return path.matchn(p) or path.trim_prefix("res://").matchn(p)),
			"%s is in the Linux export's include_filter %s" % [path, filters])
	check("user.js" in plain, "user.js is read from res://data and is not a resource")


func test_website_profile_never_gets_an_empty_user_js() -> void:
	await _setup()
	st.profiles_dir = dir.path_join("profiles")
	var first: String = st.profiles_dir.path_join("bbc-iplayer")
	DirAccess.make_dir_recursive_absolute(first)
	FileAccess.open(first.path_join("user.js"), FileAccess.WRITE).close()   # left empty by an older build
	st._add_website("BBC iPlayer", "https://bbc.co.uk/iplayer")
	check(FileAccess.get_file_as_string(first.path_join("user.js")).contains("media.eme.enabled"), "an empty user.js is seeded again")
	st.user_js = "res://data/missing.js"     # a build that left it out
	st._add_website("Other", "https://example.org")
	check(not FileAccess.file_exists(st.profiles_dir.path_join("other").path_join("user.js")), "no empty user.js written")
	check(_toasted("Couldn't set up the browser for Other"), "and says so")
	check("other" in _file_ids(), "the tile is still added")
	_teardown()


func test_an_address_with_no_site_adds_nothing() -> void:
	await _setup()
	st.profiles_dir = dir.path_join("profiles")
	var before := _file_ids()
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	_act("accept")                  # A website
	var osk: Control = st.osk()
	_type("Test")
	osk.press("Done")
	_type("https://")
	osk.press("Done")
	check(not osk.visible, "keyboard closed")
	eq(_file_ids(), before, "nothing written")
	check(not DirAccess.dir_exists_absolute(st.profiles_dir.path_join("test")), "no profile folder")
	check(_toasted("That address doesn't look right"), "says so")
	eq(SettingsScript._host("https://www.bbc.co.uk/iplayer"), "bbc.co.uk", "host")
	eq(SettingsScript._host("http://"), "", "no host")
	_teardown()


# A hand-edited apps.json that won't parse: Settings shows why and never
# saves, which would replace every entry with only what it holds.
func test_a_broken_apps_json_is_never_saved_over() -> void:
	await _setup()
	var text := FileAccess.get_file_as_string(Apps.DEFAULT_PATH)
	var at := text.find("},\n")
	text = text.left(at + 1) + text.substr(at + 2)       # one comma gone
	var f := FileAccess.open(apps_path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	st.open()
	_act("nav_right")
	eq(st._items.map(func(i): return i.type), ["info", "info"], "only the reason, no Add app and no rows")
	check(String(st._items[0].value).contains("line"), "names the line: %s" % st._items[0].value)
	check(not st._add.visible, "no Add app button")
	eq(st.item, 0, "focus on the reason")
	_act("accept")
	eq(st.level, "content", "OK does nothing there")
	st._add_app({"file": "org.foo.Bar.desktop", "name": "Bar", "kind": "Games", "comment": "", "argv": ["bar"]})
	eq(FileAccess.get_file_as_string(apps_path), text, "file untouched")
	check(not FileAccess.file_exists(apps_path + ".tmp"), "no temp file")
	_teardown()


func test_a_failed_save_reloads_and_says_so() -> void:
	await _setup()
	var before := FileAccess.get_file_as_string(apps_path)
	DirAccess.make_dir_absolute(apps_path + ".tmp")      # the temp file can't be written
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	_act("nav_down")
	_act("nav_down")
	_act("accept")                                       # Kodi
	for a in st._apps:
		check(a.has("tint"), "no placeholder left: %s" % a)
	check(st._items.all(func(i): return i.type != "app" or i.app.id != "kodi"), "no Kodi row")
	eq(FileAccess.get_file_as_string(apps_path), before, "file unchanged")
	check(_toasted("Couldn't save the app list"), "says so")
	st.remove_app("plex")
	check(st._app_index("plex") >= 0, "a failed remove leaves the app in Settings, as on Home")
	DirAccess.remove_absolute(apps_path + ".tmp")
	_teardown()


func _row_glyph(k: int) -> TextureRect:
	# A row holds the grip, then the tile with the icon.
	return st._list.get_child(k).get_child(0).get_child(1).get_child(0)


func test_row_icons_are_decoded_once_per_open() -> void:
	var icons := ProjectSettings.globalize_path("user://test-row-icons-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(icons)
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Tokens.CORAL)
	img.save_png(icons.path_join("youtube.png"))
	IconResolver.reset()
	IconResolver.roots = {"dropin": icons, "cache": icons, "flatpak": [], "themes": [], "pixmaps": [], "desktop": [icons]}
	await _setup()
	_act("nav_right")
	var tex: Texture2D = _row_glyph(0).texture
	check(tex != null, "the drop-in is drawn")
	_act("nav_down")
	_act("nav_down")
	check(_row_glyph(0).texture == tex, "the same texture after two presses, not decoded again")
	st.open()
	_act("nav_right")
	check(_row_glyph(0).texture != tex, "decoded again when Settings opens again")
	IconResolver.reset()
	_teardown()
	_rm_tree(icons)


func test_wifi_password_with_capitals_and_symbols_on_the_dpad() -> void:
	await _setup()
	var fake := FakeSetup.new()
	st.setup = fake
	st.ask_wifi_password(_net("Upstairs"))
	var osk: Control = st.osk()
	check(osk.visible and osk.secret, "keyboard open, hiding what is typed")
	_dpad_type(osk, "Kx7mP2q!")
	eq(osk.text, "Kx7mP2q!", "typed with the D-pad alone")
	eq(osk._field.text, "••••••••|", "bullets on the TV")
	_dpad_press(osk, "Done")
	eq(fake.joined, [["Upstairs", "Kx7mP2q!", false]], "the password as typed goes to the join")
	osk.open("Website name", "")
	check(not osk.secret, "other fields show their text")
	eq(osk.layer, "lower", "and open on lower case")
	_dpad_type(osk, "A&b")
	eq(osk._field.text, "A&b|", "shown as typed")
	osk.close()
	st.setup = null
	fake.free()
	_teardown()


func test_osk_long_text_shows_its_end() -> void:
	await _setup()
	var osk: Control = st.osk()
	var long := "https://www.example.com/" + "a".repeat(60) + "/end"
	osk.open("Browser start page", long)
	var shown: String = osk._field.text
	check(shown.begins_with("…") and shown.ends_with("/end|"), "the end and the cursor show: %s" % shown)
	var font: Font = Tokens.mono(400, Tokens.OSK_FONT)
	check(font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.OSK_FONT).x <= osk._key_width(10) - 2 * Tokens.NAV_ITEM_PAD, "fits the field")
	eq(osk.text, long, "the text itself is whole")
	osk.open("Browser start page", "example.com")
	eq(osk._field.text, "example.com|", "short text as it is")
	osk.close()
	_teardown()


# With a USB keyboard, Enter after typing finishes; it used to type the key
# the D-pad had focused ("example.com1").
func test_keyboard_enter_after_typing_finishes() -> void:
	await _setup()
	_act("nav_right")
	for i in 5:
		_act("nav_down")
	_act("nav_right")
	_act("accept")                     # Browser start page
	var osk: Control = st.osk()
	for i in osk.text.length():
		_key(0, KEY_BACKSPACE)
	_type("example.com")
	_key(0, KEY_ENTER)
	check(not osk.visible, "Enter finished")
	eq(_file_entry("browser").url, "https://example.com", "saved with no stray character")
	_teardown()


func test_wifi_rescan_never_moves_focus_onto_another_network() -> void:
	await _setup()
	var fake := FakeSetup.new()
	fake.wifi = {"ok": true, "connected": "", "networks": [_net("A"), _net("B")]}
	st.setup = fake
	st.section = 2
	eq(st.section_id(), "network", "Network")
	st.level = "content"
	st._build_items()
	st.item = 2
	eq(st._current().label, "B", "on B")
	fake.wifi = {"ok": true, "connected": "", "networks": [_net("C"), _net("B")]}
	st.refresh()
	eq(st._current().label, "B", "B still there: focus follows it")
	fake.wifi = {"ok": true, "connected": "", "networks": [_net("A"), _net("Neighbour", true)]}
	st.refresh()
	eq(st.item, 0, "B went: focus leaves the networks")
	eq(st._current().type, "info", "on Connected to, where OK does nothing")
	st.setup = null
	fake.free()
	_teardown()


# A click acts on the row, button or key under the pointer, like Home and the
# sidebar; it used to act on whatever had focus.
func test_a_click_acts_on_what_is_under_the_pointer() -> void:
	await _setup()
	_act("nav_right")
	eq(st._current().app.id, "youtube", "focus on YouTube")
	await tree.process_frame
	_click(_centre_of(st._list.get_child(1)))     # Add app sits in the heading: YouTube, then Plex
	eq(_file_entry("plex").get("hidden"), true, "Plex hidden")
	eq(_file_entry("youtube").has("hidden"), false, "not YouTube")
	eq(st._current().app.id, "plex", "focus follows the click")
	await tree.process_frame
	var before := FileAccess.get_file_as_string(apps_path)
	_click(Vector2(Tokens.BASE_SIZE.x - Tokens.PAD_X / 2, Tokens.BASE_SIZE.y - Tokens.PAD_BOTTOM / 2))
	eq(FileAccess.get_file_as_string(apps_path), before, "a click on nothing changes nothing")
	eq(st._current().app.id, "plex", "nor the focus")
	var remove: Control = null
	for b in st._list.get_child(0).get_child(0).get_children():
		if b.has_meta("col"):
			remove = b
	_click(_centre_of(remove))
	eq(main.state.screen, State.Screen.CONFIRM, "YouTube's Remove asks first")
	eq(main.confirm.title(), "Remove YouTube?", "names the app clicked")
	eq(main.state.confirm_focus, 0, "Cancel focused")
	_act("back")
	await tree.process_frame
	_click(_centre_of(st._nav.get_child(1)))
	eq(st.section_id(), "display", "a click on a section opens it")
	eq(st.level, "content", "into its rows")
	_teardown()


func test_a_click_on_the_keyboard_presses_the_key_under_it() -> void:
	await _setup()
	_act("nav_right")
	_act("nav_up")
	_act("accept")
	_act("accept")                     # A website: the name keyboard
	var osk: Control = st.osk()
	await tree.process_frame
	_click(_centre_of(osk._keys[2][7]))
	eq(osk.text, "k", "typed the key under the pointer, not the focused 1")
	eq(osk.focused_key(), "k", "and focused it")
	_click(Vector2(Tokens.PAD_X / 2, Tokens.PAD_TOP / 2))
	eq(osk.text, "k", "a click off the keys types nothing")
	check(osk.visible, "and doesn't close it")
	_click(_centre_of(osk._keys[4][0]))      # Shift
	_click(_centre_of(osk._keys[1][0]))
	eq(osk.text, "kQ", "Shift, then Q")
	osk.close()
	_teardown()
