extends "res://tests/test_case.gd"

# DaemonClient against a stand-in daemon: a TCPServer in this process.

const DaemonClient := preload("res://scripts/daemon_client.gd")

var server: TCPServer
var dir: String
var client: Node
var conn: StreamPeerTCP
var got := []
var _env := {}                      # environment to put back in _teardown


## With ipc, the client finds the server through BOSCAMOR_IPC, and the
## runtime files point somewhere else.
func _setup(token := "secret-token", ipc := false) -> void:
	server = TCPServer.new()
	server.listen(0, "127.0.0.1")
	dir = OS.get_cache_dir().path_join("boscamor-test-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("port"), "1" if ipc else str(server.get_local_port()))
	_write(dir.path_join("token"), "wrong-token" if ipc else token)
	client = DaemonClient.new()
	if ipc:
		for v in ["BOSCAMOR_IPC", "BOSCAMOR_RUNTIME_DIR"]:
			_env[v] = OS.get_environment(v) if OS.has_environment(v) else null
		OS.set_environment("BOSCAMOR_IPC", "%d:%s" % [server.get_local_port(), token])
		OS.set_environment("BOSCAMOR_RUNTIME_DIR", dir)
	else:
		client.runtime_dir = dir
	client.stub_delay = -1.0
	tree.root.add_child(client)
	for s in ["show_home", "power_pressed"]:
		client.connect(s, func(): got.append([s]))
	client.app_exited.connect(func(id, code): got.append(["app_exited", id, code]))
	client.launch_failed.connect(func(id, e): got.append(["launch_failed", id, e]))
	client.memory_warning.connect(func(id, mb): got.append(["memory_warning", id, mb]))
	client.still_open.connect(func(apps): got.append(["still_open", apps]))
	client.power_failed.connect(func(kind): got.append(["power_failed", kind]))
	for i in 20:
		client.poll()
		if server.is_connection_available():
			conn = server.take_connection()
		if conn and client.connected:
			break
		OS.delay_msec(20)


func _teardown() -> void:
	for v in _env:
		if _env[v] == null:
			OS.unset_environment(v)
		else:
			OS.set_environment(v, _env[v])
	client.free()
	server.stop()
	for f in ["port", "token"]:
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


func _lines() -> Array:
	var out := []
	for i in 10:
		conn.poll()
		if conn.get_available_bytes() > 0:
			break
		OS.delay_msec(20)
	var n := conn.get_available_bytes()
	if n > 0:
		var text := (conn.get_data(n)[1] as PackedByteArray).get_string_from_utf8()
		for l in text.split("\n", false):
			out.append(l)
	return out


func _say(line: String) -> void:
	conn.put_data((line + "\n").to_utf8_buffer())
	for i in 5:
		OS.delay_msec(20)
		client.poll()


func test_handshake_token_first_then_state() -> void:
	_setup()
	check(conn != null, "connected")
	check(client.connected, "client says connected")
	var lines := _lines()
	eq(lines[0], "secret-token", "token is the first line")
	eq(JSON.parse_string(lines[1]), {"cmd": "state", "visible": true}, "then the state")
	_teardown()


func test_boscamor_ipc_wins_over_runtime_files() -> void:
	_setup("ipc-token", true)
	check(conn != null, "connected through BOSCAMOR_IPC")
	check(client.connected, "client says connected")
	if conn:
		eq(_lines()[0], "ipc-token", "sent the BOSCAMOR_IPC token")
	_teardown()


func test_commands_go_out() -> void:
	_setup()
	_lines()
	client.launch({"id": "browser", "argv": ["firefox", "{url}"], "url": "https://example.org", "keep_on_home": false})
	client.power("restart")
	client.show_desktop()
	client.set_visible(true)
	client.show_window("0x3a00007")
	client.force_close(["0x3a00007", "0x4400002"])
	client.back_to_desktop()
	var lines := _lines().map(func(l): return JSON.parse_string(l))
	eq(lines, [
		{"cmd": "launch", "id": "browser", "argv": ["firefox", "https://example.org"], "keep_on_home": false},
		{"cmd": "power", "action": "reboot"},
		{"cmd": "desktop"},
		{"cmd": "state", "visible": true},
		{"cmd": "show_window", "wid": "0x3a00007"},
		{"cmd": "force_close", "wids": ["0x3a00007", "0x4400002"]},
		{"cmd": "desktop", "notify": false},
	], "commands")
	_teardown()


func test_events_come_in() -> void:
	_setup()
	_say('{"evt":"show"}')
	_say('{"evt":"power_confirm"}\nnot json\n{"evt":"app_exited","id":"plex","code":0}')
	_say('{"evt":"launch_failed","id":"x","error":"nope"}')
	_say('{"evt":"memory_warning","id":null,"available_mb":400}')
	_say('{"evt":"still_open","apps":[{"wid":"0x3a00007","name":"Writer","icon":"","asking":true}]}')
	eq(got, [["show_home"], ["power_pressed"], ["app_exited", "plex", 0],
		["launch_failed", "x", "nope"], ["memory_warning", "", 400],
		["still_open", [{"wid": "0x3a00007", "name": "Writer", "icon": "", "asking": true}]]], "events")
	_teardown()


# D86: an app ended because a new launch replaced it says nothing to Main,
# and the launch still waits for its window.
func test_replaced_exit_is_not_an_exit() -> void:
	_setup()
	client.launch({"id": "plex", "argv": ["plex"]})
	_say('{"evt":"app_exited","id":"plex","code":-15,"replaced":true}')
	eq(got, [], "nothing emitted")
	eq(client.waiting_id, "plex", "still waiting for the new one's window")
	_say('{"evt":"app_exited","id":"plex","code":0}')
	eq(got, [["app_exited", "plex", 0]], "its own exit is")
	eq(client.waiting_id, "", "and ends the wait")
	_teardown()


func test_power_failed_event() -> void:
	_setup()
	_say('{"evt":"power_failed","action":"reboot"}\n{"evt":"power_failed","action":"poweroff"}')
	eq(got, [["power_failed", "restart"], ["power_failed", "poweroff"]], "named the way the launcher does")
	_teardown()


# A read can end inside a character: lines are decoded whole.
func test_a_character_split_across_reads() -> void:
	_setup()
	var bytes := '{"evt":"still_open","apps":[{"wid":"0x1","name":"Éditeur de texte","icon":"","asking":false}]}\n'.to_utf8_buffer()
	var cut := bytes.find(0xC3) + 1     # between the two bytes of É
	conn.put_data(bytes.slice(0, cut))
	for i in 5:
		OS.delay_msec(20)
		client.poll()
	eq(got, [], "half a line: nothing yet")
	conn.put_data(bytes.slice(cut))
	for i in 5:
		OS.delay_msec(20)
		client.poll()
	eq(got, [["still_open", [{"wid": "0x1", "name": "Éditeur de texte", "icon": "", "asking": false}]]], "decoded whole")
	_teardown()


func test_reconnects_after_daemon_restart() -> void:
	_setup()
	conn.disconnect_from_host()
	for i in 10:
		client.poll()
		OS.delay_msec(20)
	eq(client.connected, false, "noticed the drop")
	conn = null
	for i in 40:
		client.poll()
		if server.is_connection_available():
			conn = server.take_connection()
		if conn and client.connected:
			break
		OS.delay_msec(20)
	check(client.connected, "connected again")
	_teardown()
