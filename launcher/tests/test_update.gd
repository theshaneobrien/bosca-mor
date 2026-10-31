extends "res://tests/test_case.gd"

# Updates in the launcher (D103): Settings > About, the confirm, "Updating",
# the restart into the new launcher, and the install once nobody is pressing
# anything. The daemon's side is daemon/tests/test_update.py.

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const SettingsView := preload("res://scripts/settings.gd")
const MainScript := preload("res://scripts/main.gd")
const S := State.Screen

var main: Control


func _setup() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	main.daemon.stand_in = true
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		im._set_mode(InputModeScript.Mode.REMOTE)
		im.release_all()
	await tree.process_frame


func _teardown() -> void:
	main.free()


func _act(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	tree.root.push_input(a, true)


func _say(info: Dictionary) -> void:
	main.daemon._dispatch(info.merged({"evt": "update"}))


func _about() -> void:
	main.state.go(S.SETTINGS)
	for i in 6:
		_act("nav_down")
	_act("nav_right")
	_act("nav_down")                     # Version, then Updates


func test_words_for_each_status() -> void:
	var cases := [
		[{}, "Needs the background service"],
		[{"status": "unknown"}, "Not checked yet"],
		[{"status": "checking"}, "Checking"],
		[{"status": "current", "version": "0.13.3"}, "Up to date"],
		[{"status": "available", "version": "0.14.0"}, "Version 0.14.0 found"],
		[{"status": "downloading", "version": "0.14.0", "percent": 40}, "Downloading 0.14.0, 40%"],
		[{"status": "ready", "version": "0.14.0"}, "Version 0.14.0 is ready"],
		[{"status": "installing", "version": "0.14.0"}, "Installing 0.14.0"],
		[{"status": "failed", "error": "Couldn't reach GitHub"}, "Couldn't reach GitHub"],
	]
	for c in cases:
		eq(SettingsView.update_words(c[0]), c[1], str(c[0]))
		check(not SettingsView.update_words(c[0]).contains("—"), "no em-dash")


func test_about_checks_then_offers_the_update() -> void:
	await _setup()
	_say({"status": "current", "version": "0.13.3"})
	_about()
	eq(main.settings._current().get("label"), "Updates", "focused")
	eq(main.settings._current().value, "Up to date", "status")
	check(main.settings.hint_words().has("Check now"), "hint: Check now")
	main.daemon.calls.clear()
	_act("accept")
	eq(main.daemon.calls, [["update_check"]], "OK checks now")
	_say({"status": "downloading", "version": "0.14.0", "percent": 12})
	eq(main.settings._current().value, "Downloading 0.14.0, 12%", "the row follows the daemon")
	main.daemon.calls.clear()
	_act("accept")
	eq(main.daemon.calls, [], "nothing to do while it downloads")
	_say({"status": "ready", "version": "0.14.0"})
	check(main.settings.hint_words().has("Update"), "hint: Update")
	_act("accept")
	eq(main.state.screen, S.CONFIRM, "asks first")
	eq(main.state.confirm_kind, "update", "the update confirm")
	eq(main.state.confirm_focus, 0, "Cancel focused (Law 2)")
	eq(main.confirm._title.text, "Update to 0.14.0?", "names the version")
	_act("back")
	eq(main.state.screen, S.SETTINGS, "Back returns to Settings")
	eq(main.settings._current().get("label"), "Updates", "on the same row")
	_teardown()


func test_update_shows_updating_then_restarts_into_the_new_launcher() -> void:
	await _setup()
	_say({"status": "ready", "version": "0.14.0"})
	main.state.go(S.SETTINGS)
	main.state.ask("update")
	main.daemon.calls.clear()
	_act("nav_right")
	_act("accept")
	eq(main.state.screen, S.OFF, "Updating screen")
	eq(main._off_text.text, "Updating", "says so")
	eq(main.daemon.calls, [["update_install"]], "asked the daemon to install")
	_act("accept")
	_act("home")
	main.daemon.power_pressed.emit()
	eq(main.state.screen, S.OFF, "keys and Power do nothing while it installs")
	_say({"status": "installing", "version": "0.14.0"})
	_say({"status": "restart", "version": "0.14.0"})
	eq(main.restart_requests, 1, "started the new launcher")
	eq(main.state.screen, S.OFF, "and stays on Updating until the new one is up")
	main.daemon._dispatch({"evt": "quit"})
	eq(main.quit_requests, 1, "then quits")
	_teardown()


func test_a_failed_install_returns_home() -> void:
	await _setup()
	_say({"status": "ready", "version": "0.14.0"})
	main.state.start_update()
	_say({"status": "failed", "error": "Couldn't install it"})
	eq(main.state.screen, S.HOME, "back to Home")
	eq(main.toast.text, "Couldn't install the update", "toast")
	eq(main.restart_requests, 0, "no restart")
	_teardown()


func test_no_answer_from_the_daemon_gives_up() -> void:
	await _setup()
	main.state.start_update()
	main._update_timer.timeout.emit()
	eq(main.state.screen, S.HOME, "back to Home")
	eq(main.toast.text, "Couldn't install the update", "toast")
	_teardown()


func test_the_new_launcher_says_it_was_updated() -> void:
	await _setup()
	_say({"status": "current", "version": "0.14.0", "installed": true})
	eq(main.toast.text, "Updated to 0.14.0", "toast")
	_teardown()


func test_restart_asked_of_a_launcher_not_on_updating() -> void:
	# After a daemon restart the old launcher may be anywhere: it shows
	# Updating, without asking for another install.
	await _setup()
	main.daemon.calls.clear()
	_say({"status": "restart", "version": "0.14.0"})
	eq(main.state.screen, S.OFF, "Updating")
	eq(main._off_text.text, "Updating", "says so")
	eq(main.daemon.calls, [], "no install asked for")
	eq(main.restart_requests, 1, "started the new launcher")
	_teardown()


func test_the_new_launcher_is_started_from_the_file_now_there() -> void:
	# On Chief's box the old launcher started "/opt/boscamor/boscamor (deleted)"
	# after the installer had replaced the file, and waited out UPDATE_WAIT (D104).
	eq(MainScript.new_launcher_path("/opt/boscamor/boscamor (deleted)"), "/opt/boscamor/boscamor", "suffix gone")
	eq(MainScript.new_launcher_path("/opt/boscamor/boscamor"), "/opt/boscamor/boscamor", "a plain path kept")
	eq(MainScript.new_launcher_path("/x (deleted)/boscamor"), "/x (deleted)/boscamor", "only at the end")


func test_no_answer_after_the_restart_says_restart_the_box() -> void:
	# The daemon asked for the restart, so the new files are in.
	await _setup()
	main.state.start_update()
	_say({"status": "restart", "version": "0.14.0"})
	main._update_timer.timeout.emit()
	eq(main.state.screen, S.HOME, "back to Home")
	eq(main.toast.text, "Restart to finish the update", "toast")
	eq(SettingsView.update_words(main.settings.update_info), "Restart to finish the update", "Settings says so too")
	check(not main.toast.text.contains("—"), "no em-dash")
	_teardown()


func test_a_new_launcher_that_ends_is_noticed_in_seconds() -> void:
	await _setup()
	_say({"status": "restart", "version": "0.14.0"})
	# Headless starts nothing, so stand in a child that ends at once.
	main._new_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--version"])
	check(main._new_pid > 0, "started a stand-in")
	main._new_timer.start()
	var waited := 0.0
	while main.state.screen != S.HOME and waited < 10.0:
		await tree.create_timer(0.1).timeout
		waited += 0.1
	eq(main.state.screen, S.HOME, "back to Home well before UPDATE_WAIT")
	eq(main.toast.text, "Restart to finish the update", "toast")
	check(main._new_timer.is_stopped(), "stopped checking")
	_teardown()


func test_a_ready_update_installs_once_nobody_presses_anything() -> void:
	await _setup()
	_say({"status": "ready", "version": "0.14.0"})
	check(not main._idle_timer.is_stopped(), "waiting for quiet")
	eq(main._idle_timer.wait_time, main.Tokens.UPDATE_IDLE, "for UPDATE_IDLE")
	main._idle_timer.start(5.0)
	_act("nav_right")
	check(main._idle_timer.time_left > 60.0, "a key starts the wait again")
	main.state.ask("poweroff")
	main.daemon.calls.clear()
	main._idle_timer.timeout.emit()
	eq(main.state.screen, S.CONFIRM, "not over a dialog")
	check(not main._idle_timer.is_stopped(), "tries again later")
	main.state.go(S.HOME)
	main._idle_timer.timeout.emit()
	eq(main.state.screen, S.OFF, "installs from Home")
	eq(main.daemon.calls, [["update_install"]], "asked the daemon")
	_teardown()


func test_no_idle_install_without_a_ready_update() -> void:
	await _setup()
	_say({"status": "current", "version": "0.13.3"})
	check(main._idle_timer.is_stopped(), "no wait")
	main._idle_timer.timeout.emit()
	eq(main.state.screen, S.HOME, "nothing happens")
	_teardown()
