extends "res://tests/test_case.gd"

const MainScene := preload("res://scenes/main.tscn")
const Apps := preload("res://scripts/apps.gd")
const State := preload("res://scripts/state.gd")
const Tokens := preload("res://theme/tokens.gd")
const Wifi := preload("res://scripts/wifi.gd")
const SettingsView := preload("res://scripts/settings.gd")

var main: Control


func _setup() -> void:
	main = MainScene.instantiate()
	main.apps_path = Apps.DEFAULT_PATH
	main.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(main)
	main.daemon.stub_delay = -1.0
	main.daemon.stand_in = true     # the no-daemon stand-in on every OS (D66 keeps it off Linux)
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
	eq(OS.low_processor_usage_mode_sleep_usec, Tokens.SHOWN_SLEEP_USEC, when + ": 60 Hz sleep again (D84)")


func test_launch_hides_then_app_exit_shows() -> void:
	await _setup()
	main.home.set_focus(4, false)
	var shown_sleep := OS.low_processor_usage_mode_sleep_usec
	_act("accept")
	check(not main.is_hidden, "still shown during the fade")
	_finish_tweens()
	main.daemon.app_window.emit("prime")
	_check_hidden("app window up")
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
	main.daemon.app_window.emit("youtube")
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
	check(main.is_hidden, "off screen for the daemon: Home now closes the app")
	check(not tree.paused, "still drawing while the app starts")
	check(main.waiting_for_window, "black and waiting for the app's window")
	main.daemon.app_window.emit("youtube")
	check(not main.waiting_for_window, "app window up")
	_check_hidden("asleep behind the app")
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


# Box test: minimising was plainly visible. For an app the launcher now stays
# black and paused behind it and never minimises; only Desktop does (D69).
func test_app_launch_never_minimises() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	eq(main.minimize_requests, 0, "no minimise for an app")
	check(main.is_hidden and tree.paused, "paused behind the app")
	main.daemon.app_exited.emit("youtube", 0)
	main.state.run_item("desktop")
	_finish_tweens()
	eq(main.minimize_requests, 1, "Desktop still minimises")
	_teardown()


# Some apps take 10 to 15 s to open on the J4105, so the black after a
# launch shows the app's tile, "Opening <name>" and pulsing dots (D76).
func test_loading_screen_while_the_app_opens() -> void:
	await _setup()
	main.home.set_focus(1, false)
	_act("accept")
	_finish_tweens()
	check(main.loader.active, "loading screen started")
	check(not main.loader.visible, "not shown yet: a fast app never sees it")
	eq(Engine.max_fps, Tokens.LOADER_FPS, "frame rate capped while waiting")
	main.loader.reveal()            # what the delay timer does after LOADER_DELAY
	check(main.loader.visible, "shown")
	eq(main.loader.name_text(), "Opening Plex", "names the app")
	var pulsing := tree.get_processed_tweens().filter(func(t): return t.is_valid() and t.is_running())
	check(pulsing.size() >= 1, "dots pulsing")
	main.daemon.app_window.emit("plex")
	check(not main.loader.visible and not main.loader.active, "gone once the window is up")
	eq(Engine.max_fps, 0, "frame cap lifted")
	_check_hidden("asleep behind Plex")
	main.daemon.app_exited.emit("plex", 0)
	_teardown()


func test_fast_app_never_sees_the_loading_screen() -> void:
	await _setup()
	_act("accept")
	main.daemon.app_window.emit("youtube")
	_finish_tweens()
	check(not main.loader.active and not main.loader.visible, "no loading screen")
	eq(Engine.max_fps, 0, "no frame cap")
	_check_hidden("straight to sleep")
	_teardown()


func test_loading_screen_goes_on_timeout_and_failure() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.loader.reveal()
	main.daemon.launch_timed_out.emit("youtube")
	check(not main.loader.visible and not main.loader.active, "gone on the timeout")
	eq(Engine.max_fps, 0, "frame cap lifted")
	_check_shown("back on Home")
	_act("accept")
	_finish_tweens()
	main.daemon.launch_failed.emit("youtube", "nope")
	check(not main.loader.active, "gone on a failed launch")
	_teardown()


# D86: picking another tile while an app runs behind Home (keep_on_home, or
# Power then Cancel). The daemon ends the old app first; its exit must not
# end the new launch, or the new app comes up over an awake launcher.
func test_replacing_an_app_keeps_the_new_launch() -> void:
	await _setup()
	_act("accept")                         # YouTube, left running on Home
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	main.daemon.show_home.emit()
	_finish_tweens()
	_check_shown("Home over YouTube")
	main.home.set_focus(1, false)
	_act("accept")                         # Plex replaces it
	main.daemon._dispatch({"evt": "app_exited", "id": "youtube", "code": 0, "replaced": true})
	check(main.home.is_launching(), "still launching Plex")
	eq(main.daemon.waiting_id, "plex", "still waiting for Plex's window")
	main.daemon.app_exited.emit("youtube", 0)   # or YouTube quit by itself just then
	check(main.home.is_launching(), "an older app's exit doesn't end it either")
	_finish_tweens()
	check(main.waiting_for_window, "black, waiting for Plex")
	main.daemon.app_window.emit("plex")
	_check_hidden("asleep behind Plex")
	_teardown()


func test_relaunching_the_running_app() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	main.daemon.show_home.emit()
	_finish_tweens()
	_act("accept")                         # the same tile again: same id
	main.daemon._dispatch({"evt": "app_exited", "id": "youtube", "code": 0, "replaced": true})
	check(main.home.is_launching(), "still launching")
	eq(main.daemon.waiting_id, "youtube", "still waiting for the new window")
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	_check_hidden("asleep behind the new one")
	_teardown()


func test_replaced_app_does_not_end_a_panel() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	main.daemon.show_home.emit()
	_finish_tweens()
	main.state.go(State.Screen.SETTINGS)
	main._launch_panel(SettingsView.PANELS.network)
	main.daemon._dispatch({"evt": "app_exited", "id": "youtube", "code": 0, "replaced": true})
	check(main.is_hidden and main._panel_running, "still opening the panel")
	main.daemon.app_exited.emit("network-settings", 0)
	check(not main.is_hidden and not main._panel_running, "back when the panel closes")
	_teardown()


# Review: Power over a panel, then Cancel, Back and another tile. The panel's
# exit came as replaced (or under an old id) and was dropped, so the flag
# stayed set; when the new app quit, the launcher came back with Home still
# black and taking no keys.
func test_a_panel_replaced_by_a_tile_launch_leaves_no_trace() -> void:
	await _setup()
	main.state.go(State.Screen.SETTINGS)
	main._launch_panel(SettingsView.PANELS.network)
	main.daemon.app_window.emit("network-settings")
	_check_hidden("behind the panel")
	main.daemon.power_pressed.emit()
	eq(main.state.screen, State.Screen.CONFIRM, "confirm over the panel")
	main.state.handle("accept")            # Cancel
	main.state.handle("back")              # Home
	_finish_tweens()
	eq(main.state.screen, State.Screen.HOME, "Home")
	main.home.set_focus(1, false)
	_act("accept")                         # Plex
	main.daemon._dispatch({"evt": "app_exited", "id": "network-settings", "code": 0, "replaced": true})
	main.daemon.app_exited.emit("network-settings", 0)   # or under its own id
	_finish_tweens()
	main.daemon.app_window.emit("plex")
	_check_hidden("behind Plex")
	main.daemon.app_exited.emit("plex", 0)
	_check_shown("Plex quit")
	check(not main.home.is_launching(), "Home takes input again")
	check(main.home._fade.visible, "with the return fade")
	_finish_tweens()
	eq(main.home._fade.visible, false, "and the fade ends")
	_teardown()


# Power within Desktop's fade to black: the black cover must go with it, or
# the confirm and then Home sit under black.
func test_leaving_during_the_desktop_fade_clears_the_cover() -> void:
	await _setup()
	main.state.handle("back")
	main.state.run_item("desktop")
	check(main._cover.visible, "fading to black")
	main.daemon.power_pressed.emit()
	_finish_tweens()
	eq(main.state.screen, State.Screen.CONFIRM, "confirm open")
	check(not main._cover.visible, "no black cover over it")
	eq(main._cover.color.a, 0.0, "cover clear")
	check(not main.is_hidden, "never hid")
	main.state.go(State.Screen.HOME)
	main.state.run_item("desktop")
	main.state.show_home()                 # the window got the focus back mid-fade
	_finish_tweens()
	eq(main.state.screen, State.Screen.HOME, "Home")
	check(not main._cover.visible, "cover gone on a focus-in too")
	check(not main.is_hidden, "still shown")
	_teardown()


# Power from behind an app: the last frame drawn was black, so no blur is
# taken from it, and Cancel shows the sidebar over Home as it is.
func test_power_from_an_app_takes_no_black_blur() -> void:
	await _setup()
	_act("accept")
	_finish_tweens()
	main.daemon.app_window.emit("youtube")
	main.blur_captures = 0
	main.daemon.power_pressed.emit()
	eq(main.state.screen, State.Screen.CONFIRM, "confirm")
	eq(main.blur_captures, 0, "nothing captured from the black")
	main.state.handle("accept")            # Cancel
	eq(main.state.screen, State.Screen.SIDEBAR, "sidebar")
	eq(main.blur_captures, 0, "nor from the frame with the dialog in it")
	main.state.go(State.Screen.HOME)
	main.state.handle("power")
	eq(main.blur_captures, 1, "captured when Home is on screen")
	_teardown()


func test_settings_confirms_take_no_blur() -> void:
	await _setup()
	main.state.go(State.Screen.SETTINGS)
	main.blur_captures = 0
	main.state.ask("remove")
	main.state.cancel_confirm()
	main.state.ask("picture")
	main.state.cancel_confirm()
	eq(main.state.screen, State.Screen.SETTINGS, "back in Settings")
	eq(main.blur_captures, 0, "remove and picture go back to Settings, not the sidebar")
	main.state.handle("power")
	eq(main.blur_captures, 1, "the power confirm still does")
	_teardown()
