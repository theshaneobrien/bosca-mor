# Integration check run by daemon/tests/test_integration.py: connect to a real
# boscamor-input, launch a dummy app, wait for app_exited. Exit code 0 on success.
# BOSCAMOR_IPC=<port>:<token> godot --headless --path launcher -s res://tests/daemon_roundtrip.gd
extends SceneTree

const DaemonClient := preload("res://scripts/daemon_client.gd")
const TIMEOUT_MS := 15000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ipc := OS.get_environment("BOSCAMOR_IPC")
	if DaemonClient.parse_ipc(ipc).is_empty():
		printerr("roundtrip: BOSCAMOR_IPC unset or malformed: '%s'" % ipc)
		quit(1)
		return
	var client := DaemonClient.new()
	client.stub_delay = -1.0
	root.add_child(client)
	var exited := []
	client.app_exited.connect(func(id, code): exited.append([id, code]))

	var start := Time.get_ticks_msec()
	while not client.connected and Time.get_ticks_msec() - start < TIMEOUT_MS:
		await create_timer(0.1).timeout
	if not client.connected:
		printerr("roundtrip: never connected to the daemon on port %d" % DaemonClient.parse_ipc(ipc).port)
		quit(1)
		return
	client.set_visible(false)
	client.launch({"id": "dummy", "argv": ["sleep", "1"]})
	while exited.is_empty() and Time.get_ticks_msec() - start < TIMEOUT_MS:
		await create_timer(0.1).timeout
	if exited != [["dummy", 0]]:
		printerr("roundtrip: wanted app_exited for dummy, got %s" % [exited])
		quit(1)
		return
	print("roundtrip: launch and app_exited ok")
	quit(0)
