# The one way the launcher talks to boscamor-input: newline JSON over TCP on
# 127.0.0.1, after a token line (SPEC "IPC"). It reads the port and token the
# daemon writes to $XDG_RUNTIME_DIR/boscamor/, polls the socket from one
# timer that keeps running while the tree is paused, and reconnects if the
# daemon restarts. With no daemon (the dev machine), it stands in: it logs,
# and pretends an app exited or a power-off was a dry run after stub_delay.
extends Node

const Apps := preload("res://scripts/apps.gd")

const POLL_S := 0.1                 # SPEC Resource use: poll the socket every 100 ms
const RETRY_S := 1.0

## The daemon wants Home shown: Home or Guide pressed while hidden, or an app
## closed by Home.
signal show_home
## The app launched from a tile has gone.
signal app_exited(app_id: String, code: int)
## The app could not start.
signal launch_failed(app_id: String, error: String)
## The remote's power key: show the launcher and open the confirm.
signal power_pressed
## Memory stayed low; the launcher shows it the next time it appears.
signal memory_warning(app_id: String, available_mb: int)
## Return to Bosca Mor left these windows open: [{wid, name, icon, asking}].
signal still_open(apps: Array)
signal connected_changed(connected: bool)

## Seconds before the stand-in pretends an app exited or a power-off was a
## dry run. Below 0 it never does (tests).
@export var stub_delay := 1.5
## Where the port and token files are; empty uses BOSCAMOR_RUNTIME_DIR, then
## $XDG_RUNTIME_DIR/boscamor.
@export var runtime_dir := ""

var calls: Array = []
var connected := false

var _peer: StreamPeerTCP
var _token := ""
var _sent_token := false
var _buf := ""
var _retry_in := 0.0
var _visible := true
var _timer: Timer


func _ready() -> void:
	# The poll timer is the one node that runs while the tree is paused.
	_timer = Timer.new()
	_timer.wait_time = POLL_S
	_timer.process_mode = PROCESS_MODE_ALWAYS
	_timer.timeout.connect(poll)
	add_child(_timer)
	_timer.start()
	poll()


# Commands ---------------------------------------------------------------------

func launch(app: Dictionary) -> void:
	_record(["launch", app.id])
	if not _send({"cmd": "launch", "id": app.id, "argv": Apps.argv_for(app),
			"keep_on_home": app.get("keep_on_home", false)}):
		_later(func(): app_exited.emit(app.id, 0))


## kind is "poweroff" or "restart". Only ever after the confirm.
func power(kind: String) -> void:
	_record(["power", kind])
	if not _send({"cmd": "power", "action": "reboot" if kind == "restart" else kind}):
		_later(show_home.emit)


func show_desktop() -> void:
	_record(["show_desktop"])
	_visible = false
	_send({"cmd": "desktop"})


## Show me: raise a window still open (the launcher has hidden).
func show_window(wid: String) -> void:
	_record(["show_window", wid])
	_visible = false
	_send({"cmd": "show_window", "wid": wid})


## Close anyway, after the confirm. The daemon uses xkill -id per window.
func force_close(wids: Array) -> void:
	_record(["force_close"] + wids)
	_send({"cmd": "force_close", "wids": wids})


## Back to desktop: hide, close nothing, no notification this time.
func back_to_desktop() -> void:
	_record(["back_to_desktop"])
	_visible = false
	_send({"cmd": "desktop", "notify": false})


## Tells the daemon whether the launcher is on screen, so it knows whether
## to act on Home.
func set_visible(v: bool) -> void:
	_visible = v
	_send({"cmd": "state", "visible": v})


func _record(call_args: Array) -> void:
	calls.append(call_args)
	print("daemon%s: %s" % ["" if connected else " (stand-in)", " ".join(call_args)])


func _later(f: Callable) -> void:
	if stub_delay >= 0.0 and is_inside_tree():
		get_tree().create_timer(stub_delay, true).timeout.connect(f)


# Connection -------------------------------------------------------------------

func _dir() -> String:
	if not runtime_dir.is_empty():
		return runtime_dir
	var d := OS.get_environment("BOSCAMOR_RUNTIME_DIR")
	if not d.is_empty():
		return d
	var xdg := OS.get_environment("XDG_RUNTIME_DIR")
	return "" if xdg.is_empty() else xdg.path_join("boscamor")


## Runs every POLL_S: connects, reads, and dispatches events.
func poll() -> void:
	if _peer == null:
		_retry_in -= POLL_S
		if _retry_in <= 0.0:
			_retry_in = RETRY_S
			_connect()
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_CONNECTED:
			if not _sent_token:
				_sent_token = true
				_peer.put_data((_token + "\n").to_utf8_buffer())
				_set_connected(true)
				_send({"cmd": "state", "visible": _visible})
			_read()
		_:
			_disconnect()


func _connect() -> void:
	var dir := _dir()
	if dir.is_empty():
		return
	var port := FileAccess.get_file_as_string(dir.path_join("port")).strip_edges()
	_token = FileAccess.get_file_as_string(dir.path_join("token")).strip_edges()
	if not port.is_valid_int() or _token.is_empty():
		return
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host("127.0.0.1", int(port)) != OK:
		_peer = null
		return
	_sent_token = false
	_buf = ""


func _disconnect() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_peer = null
	_retry_in = RETRY_S
	_set_connected(false)


func _set_connected(c: bool) -> void:
	if c != connected:
		connected = c
		print("daemon %s" % ("connected" if c else "not connected"))
		connected_changed.emit(c)


func _send(msg: Dictionary) -> bool:
	if not connected:
		return false
	var err := _peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())
	if err != OK:
		_disconnect()
		return false
	return true


func _read() -> void:
	var n := _peer.get_available_bytes()
	if n <= 0:
		return
	var got := _peer.get_partial_data(n)
	if got[0] != OK:
		_disconnect()
		return
	_buf += (got[1] as PackedByteArray).get_string_from_utf8()
	while _buf.contains("\n"):
		var i := _buf.find("\n")
		var line := _buf.substr(0, i)
		_buf = _buf.substr(i + 1)
		var json := JSON.new()
		if json.parse(line) == OK and json.data is Dictionary:
			_dispatch(json.data)


func _dispatch(msg: Dictionary) -> void:
	match msg.get("evt", ""):
		"show":
			show_home.emit()
		"power_confirm":
			power_pressed.emit()
		"app_exited":
			app_exited.emit(str(msg.get("id", "")), int(msg.get("code", 0)))
		"launch_failed":
			launch_failed.emit(str(msg.get("id", "")), str(msg.get("error", "")))
		"still_open":
			var list = msg.get("apps", [])
			still_open.emit(list if list is Array else [])
		"memory_warning":
			var app_id = msg.get("id")
			memory_warning.emit("" if app_id == null else str(app_id), int(msg.get("available_mb", 0)))
		var other:
			push_warning("daemon: unknown event %s" % other)
