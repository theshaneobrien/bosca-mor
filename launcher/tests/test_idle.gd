extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const Tokens := preload("res://theme/tokens.gd")
const Wifi := preload("res://scripts/wifi.gd")

var main: Control


func _setup() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(main)
	main.daemon.stub_delay = -1.0
	await tree.process_frame


func _teardown() -> void:
	tree.paused = false
	OS.low_processor_usage_mode_sleep_usec = 6900
	main.free()


func _act(action: String) -> void:
	var a := InputEventAction.new()
	a.action = action
	a.pressed = true
	tree.root.push_input(a, true)


func _finish_tweens() -> void:
	for t in tree.get_processed_tweens():
		if t.is_valid():
			t.custom_step(10.0)


# Nodes under Main that would still run with the tree paused.
func _running_while_paused() -> Array:
	var out := []
	var stack: Array[Node] = [main]
	while stack:
		var n: Node = stack.pop_back()
		if n.can_process():
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _check_hidden(when: String) -> void:
	check(main.is_hidden, when + ": hidden")
	check(tree.paused, when + ": tree paused")
	eq(OS.low_processor_usage_mode_sleep_usec, Tokens.HIDDEN_SLEEP_USEC, when + ": long sleep")
	eq(main.sidebar.has_capture(), false, when + ": blur freed")
	var running := _running_while_paused()
	eq(running.size(), 1, when + ": one node runs while paused: %s" % [running])
	if running.size() == 1:
		check(running[0] is Timer and running[0].get_parent() == main.daemon, when + ": it is the daemon poll timer")
	var im = tree.root.get_node_or_null("InputMode")
	if im:
		check(not im.can_process(), when + ": InputMode pauses too")
	var live := tree.get_processed_tweens().filter(func(t): return t.is_valid() and t.is_running())
	eq(live.size(), 0, when + ": no tweens")


func _check_shown(when: String) -> void:
	check(not main.is_hidden, when + ": shown")
	check(not tree.paused, when + ": tree running")
	check(OS.low_processor_usage_mode_sleep_usec != Tokens.HIDDEN_SLEEP_USEC, when + ": short sleep again")


func test_launch_hides_then_app_exit_shows() -> void:
	await _setup()
	main.home.set_focus(4, false)
	var shown_sleep := OS.low_processor_usage_mode_sleep_usec
	_act("accept")
	check(not main.is_hidden, "still shown during the fade")
	_finish_tweens()
	_check_hidden("after the launch fade")
	main.daemon.app_exited.emit("prime", 0)
	_check_shown("app exited")
	eq(OS.low_processor_usage_mode_sleep_usec, shown_sleep, "sleep restored")
	eq(main.home.focus, 4, "same tile focused")
	check(main.home.is_launching() == false, "Home takes input again")
	check(main.home._fade.visible, "return fade playing")
	_finish_tweens()
	eq(main.home._fade.visible, false, "return fade done")
	_act("nav_right")
	eq(main.home.focus, 5, "input works")
	_teardown()


func test_desktop_hides_and_frees_the_blur() -> void:
	await _setup()
	main.state.handle("back")
	# Headless can't capture the screen, so give the sidebar a texture to free.
	main.sidebar._blur.texture = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGB8))
	check(main.sidebar.has_capture(), "blur held while the sidebar is open")
	main.state.set_sidebar_focus(2)
	_act("accept")
	eq(main.state.screen, State.Screen.DESKTOP, "desktop")
	check(not main.is_hidden, "still shown while it fades to black")
	check(main._cover.visible, "black cover fading in")
	_finish_tweens()
	_check_hidden("desktop")
	main.daemon.show_home.emit()
	_check_shown("Home pressed")
	check(not main._cover.visible, "cover gone on the way back")
	eq(main.state.screen, State.Screen.HOME, "Home screen")
	check(main.home.accepting_input, "Home has focus")
	_teardown()


func test_keep_on_home_show_returns_while_app_runs() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	_check_hidden("launched")
	main.daemon.show_home.emit()
	_check_shown("show without app_exited")
	check(not main.home.is_launching(), "back on Home")
	_teardown()


func test_power_key_while_hidden() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.daemon.power_pressed.emit()
	_check_shown("power key")
	eq(main.state.screen, State.Screen.CONFIRM, "confirm open")
	_teardown()


func test_hide_and_show_are_idempotent() -> void:
	await _setup()
	var shown_sleep := OS.low_processor_usage_mode_sleep_usec
	main.hide_launcher()
	main.hide_launcher()
	main.show_launcher()
	main.show_launcher()
	eq(OS.low_processor_usage_mode_sleep_usec, shown_sleep, "sleep restored once")
	_check_shown("after two hides and two shows")
	_teardown()


# SPEC System setup: the launcher must not inhibit screen blanking on Home.
func test_screen_blanking_not_inhibited() -> void:
	eq(ProjectSettings.get_setting("display/window/energy_saving/keep_screen_on"), false, "keep_screen_on off")


func test_wifi_states() -> void:
	var header := "Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n"
	eq(Wifi.parse(header + "wlp2s0: 0000   58.  -52.  -256        0      0      0      0     21        0\n"), "on", "link")
	eq(Wifi.parse(header + "wlp2s0: 0000    0.    0.     0        0      0      0      0      0        0\n"), "off", "no link")
	eq(Wifi.parse(header), "none", "no wireless interface")
	eq(Wifi.state("res://tests/fixtures/nope"), "unknown", "no /proc")


func test_wifi_icon_follows_state() -> void:
	await _setup()
	var home: Control = main.home
	home.set_wifi("on")
	check(home._wifi.visible, "on: shown")
	var on_tex: Texture2D = home._wifi.texture
	home.set_wifi("off")
	check(home._wifi.visible and home._wifi.texture != on_tex, "off: struck through")
	home.set_wifi("none")
	check(not home._wifi.visible, "none: hidden on a wired box")
	home.set_wifi("unknown")
	check(home._wifi.visible, "unknown: shown")
	eq(home._wifi_timer.wait_time, Tokens.WIFI_POLL, "polled every 30 s")
	check(not home._wifi_timer.is_stopped(), "poll timer running")
	_teardown()


func test_clock_timer_aligned_to_minute() -> void:
	await _setup()
	var left: float = main.home._clock_timer.time_left
	var sec: int = Time.get_datetime_dict_from_system().second
	check(absf(left - (60 - sec)) <= 1.0, "next tick at the minute: %s s left at :%02d" % [left, sec])
	check(main.home._clock_timer.one_shot, "re-aimed each minute, so it never drifts")
	_teardown()


# Box test: the desktop showed between Home and the app while the launcher
# minimised. Now it stays up, black, until the app's window is there.
func test_launch_waits_for_the_app_window() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	_check_hidden("after the launch fade")
	check(main.waiting_for_window, "black and waiting for the app's window")
	main.daemon.app_window.emit("youtube")
	check(not main.waiting_for_window, "app window up: minimise behind it")
	check(main.is_hidden, "still hidden")
	main.daemon.app_exited.emit("youtube", 0)
	_check_shown("app closed")
	_teardown()


func test_fast_app_window_before_the_fade_ends() -> void:
	await _setup()
	_act("accept")
	main.daemon.app_window.emit("youtube")
	_finish_tweens()
	check(main.is_hidden, "hidden")
	check(not main.waiting_for_window, "window already up: no wait")
	_teardown()


func test_timeout_while_waiting_returns_home() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	check(main.waiting_for_window, "waiting")
	main.daemon.launch_timed_out.emit("youtube")
	_check_shown("timed out")
	check(not main.waiting_for_window, "wait over")
	check(not main._minimized, "never minimised, so nothing to restore")
	_teardown()


func test_fullscreen_by_default() -> void:
	eq(ProjectSettings.get_setting("display/window/size/mode"), DisplayServer.WINDOW_MODE_FULLSCREEN, "full screen without --fullscreen")
