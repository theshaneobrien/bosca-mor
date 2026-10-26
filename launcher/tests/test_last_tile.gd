extends "res://tests/test_case.gd"

# SPEC: Home remembers the last focused tile across launches and reboots.

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const StateFile := preload("res://scripts/state_file.gd")

var dir: String
var state_path: String
var main: Control


func _setup() -> void:
	dir = ProjectSettings.globalize_path("user://test-last-tile-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	state_path = dir.path_join("state.json")


func _start_main() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = state_path
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	main.daemon.stand_in = true     # the no-daemon stand-in on every OS (D66 keeps it off Linux)
	await tree.process_frame


func _stop_main() -> void:
	tree.paused = false
	OS.low_processor_usage_mode_sleep_usec = 6900
	main.free()


func _finish_tweens() -> void:
	for t in tree.get_processed_tweens():
		if t.is_valid():
			t.custom_step(10.0)


func test_launch_saves_and_a_restart_restores() -> void:
	_setup()
	await _start_main()
	eq(main.home.focus, 0, "no state yet: first tile")
	main.home.set_focus(6, false)
	main.home.launch()
	eq(StateFile.load_file(state_path).get("last_app"), "spotify", "saved on launch")
	_stop_main()
	await _start_main()            # a reboot, as far as the launcher can tell
	eq(main.home.focus, 6, "same tile after restart")
	eq(main.home._name.text, "Spotify", "hero follows")
	_stop_main()


func test_focus_saved_once_it_settles() -> void:
	_setup()
	await _start_main()
	main.home.move(1)
	main.home.move(1)
	check(not FileAccess.file_exists(state_path), "nothing written while moving")
	check(not main.home._save_timer.is_stopped(), "save waits for focus to rest")
	main.home._save_timer.timeout.emit()
	eq(StateFile.load_file(state_path).get("last_app"), "jellyfin", "saved after the pause")
	_stop_main()


func test_hiding_saves_and_keeps_other_state() -> void:
	_setup()
	StateFile.update({"reduce_motion": true}, state_path)
	await _start_main()
	main.home.move(1)
	main.state.handle("back")
	main.state.set_sidebar_focus(2)    # Desktop
	main.state.handle("accept")
	eq(main.state.screen, State.Screen.DESKTOP, "desktop")
	var saved := StateFile.load_file(state_path)
	eq(saved.get("last_app"), "plex", "saved on hide")
	eq(saved.get("reduce_motion"), true, "other keys kept")
	_stop_main()


func test_missing_app_falls_back_to_first_tile() -> void:
	_setup()
	StateFile.update({"last_app": "gone-app"}, state_path)
	await _start_main()
	eq(main.home.focus, 0, "unknown id: first tile")
	_stop_main()


func test_fixture_state_is_never_written() -> void:
	eq(StateFile.update({"last_app": "x"}, "res://tests/fixtures/nope.json"), ERR_FILE_NO_PERMISSION, "res:// refused")
	check(not FileAccess.file_exists("res://tests/fixtures/nope.json"), "no fixture file made")
