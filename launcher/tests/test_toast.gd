extends "res://tests/test_case.gd"

# Toasts (launch failed, no window within 15 s, memory warning) and the
# launch timeout that app_window cancels.

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const Tokens := preload("res://theme/tokens.gd")

var main: Control
var toast: Control


func _setup() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(main)
	main.animate = false
	main.daemon.stub_delay = -1.0
	main.daemon.fake_now_ms = 1000
	toast = main.toast
	await tree.process_frame


func _teardown() -> void:
	tree.paused = false
	OS.low_processor_usage_mode_sleep_usec = 6900
	main.free()


func _finish_tweens() -> void:
	for t in tree.get_processed_tweens():
		if t.is_valid():
			t.custom_step(10.0)


# Launches the focused tile and lets the fade finish, so the launcher hides.
func _launch(i: int) -> void:
	main.home.set_focus(i, false)
	main.home.launch()
	_finish_tweens()
	check(main.is_hidden, "hidden after launch")


func _wait_out_toast() -> void:
	toast._timer.timeout.emit()
	_finish_tweens()


func _advance(ms: int) -> void:
	main.daemon.fake_now_ms += ms
	main.daemon.poll()


func test_toast_shows_then_goes() -> void:
	await _setup()
	toast.push("Couldn't open Plex")
	check(toast.visible, "shown")
	eq(toast.text, "Couldn't open Plex", "text")
	eq(toast._label.text, "Couldn't open Plex", "label")
	eq(toast._timer.wait_time, Tokens.TOAST_HOLD, "holds for the token time")
	check(not toast._timer.is_stopped(), "hold timer running")
	eq(toast.focus_mode, Control.FOCUS_NONE, "never takes focus")
	eq(toast.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never takes the mouse")
	check(main.home.accepting_input, "Home still takes input")
	main.home.move(1)
	eq(main.home.focus, 1, "keys still move Home")
	_wait_out_toast()
	check(not toast.visible, "gone")
	check(not toast.is_showing(), "nothing showing")
	_teardown()


func test_toasts_queue() -> void:
	await _setup()
	toast.push("one")
	toast.push("two")
	eq(toast.text, "one", "first")
	_wait_out_toast()
	eq(toast.text, "two", "then the second")
	_wait_out_toast()
	check(not toast.visible, "then none")
	_teardown()


func test_launch_failed_shows_toast_naming_app() -> void:
	await _setup()
	_launch(1)
	main.daemon._dispatch({"evt": "launch_failed", "id": "plex", "error": "No such file"})
	check(not main.is_hidden, "launcher back")
	eq(toast.text, "Couldn't open Plex", "toast names the app")
	check(toast.visible, "toast on screen")
	eq(main.daemon.waiting_id, "", "launch timer cancelled")
	_teardown()


func test_timeout_returns_home_with_toast() -> void:
	await _setup()
	_launch(2)
	eq(main.daemon.waiting_id, "jellyfin", "waiting for a window")
	_advance(int(Tokens.LAUNCH_BACKUP * 1000) - 100)
	check(main.is_hidden, "still hidden just before the deadline")
	eq(toast.text, "", "no toast yet")
	_advance(100)
	check(not main.is_hidden, "back on Home at the deadline")
	check(not main.home.is_launching(), "Home takes input")
	eq(main.home.focus, 2, "same tile focused")
	eq(toast.text, "Jellyfin took too long to open", "toast names the app")
	# The daemon gives up at the same time; its event and the app's exit
	# must not toast twice or replay the return.
	main.daemon._dispatch({"evt": "launch_timeout", "id": "jellyfin"})
	main.daemon._dispatch({"evt": "app_exited", "id": "jellyfin", "code": -15})
	eq(toast.queue.size(), 0, "one toast only")
	_teardown()


func test_app_window_cancels_timeout() -> void:
	await _setup()
	_launch(1)
	_advance(3000)
	main.daemon._dispatch({"evt": "app_window", "id": "plex"})
	eq(main.daemon.waiting_id, "", "no longer waiting")
	_advance(int(Tokens.LAUNCH_TIMEOUT * 1000) * 2)
	check(main.is_hidden, "app stays in front")
	eq(toast.text, "", "no toast")
	_teardown()


func test_daemon_timeout_event() -> void:
	await _setup()
	_launch(3)
	main.daemon._dispatch({"evt": "launch_timeout", "id": "netflix"})
	check(not main.is_hidden, "back on Home")
	eq(toast.text, "Netflix took too long to open", "toast")
	_advance(int(Tokens.LAUNCH_BACKUP * 1000))
	eq(toast.queue.size(), 0, "the launcher's own deadline does not fire again")
	_teardown()


func test_app_exit_cancels_timeout() -> void:
	await _setup()
	_launch(1)
	main.daemon._dispatch({"evt": "app_exited", "id": "plex", "code": 0})
	_advance(int(Tokens.LAUNCH_BACKUP * 1000))
	eq(toast.text, "", "no toast after a normal exit")
	_teardown()


func test_memory_warning_waits_for_the_launcher() -> void:
	await _setup()
	_launch(1)
	main.daemon._dispatch({"evt": "memory_warning", "id": "plex", "available_mb": 400, "app_mb": 900})
	eq(toast.text, "", "not shown behind the app")
	check(not toast.visible, "hidden")
	eq(toast.queue, ["Memory ran low while Plex was open"] as Array[String], "queued")
	main.daemon._dispatch({"evt": "app_window", "id": "plex"})
	main.daemon._dispatch({"evt": "show"})
	check(not main.is_hidden, "launcher back")
	eq(toast.text, "Memory ran low while Plex was open", "shown when the launcher appears")
	check(toast.visible, "on screen")
	_teardown()


func test_memory_warning_while_shown() -> void:
	await _setup()
	main.daemon._dispatch({"evt": "memory_warning", "id": null, "available_mb": 300, "app_mb": 0})
	eq(toast.text, "Memory ran low", "no app named")
	_teardown()


func test_toast_dropped_when_launcher_hides() -> void:
	await _setup()
	toast.push("one")
	toast.push("two")
	_launch(1)
	check(not toast.visible, "nothing over the app")
	eq(toast.text, "", "the one on screen was seen")
	main.daemon._dispatch({"evt": "app_exited", "id": "plex", "code": 0})
	eq(toast.text, "two", "the rest shows on return")
	_teardown()
