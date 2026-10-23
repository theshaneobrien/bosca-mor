# The one way the launcher talks to boscamor-input: newline JSON over TCP on
# 127.0.0.1, after a token line (SPEC "IPC"). It reads the port and token the
# daemon writes to Paths.runtime_dir() (or BOSCAMOR_IPC on the Windows dev
# machine), polls the socket from one
# timer that keeps running while the tree is paused, and reconnects if the
# daemon restarts. With no daemon (the dev machine), it stands in: it logs,
# and pretends an app exited or a power-off was a dry run after stub_delay.
extends Node

const Apps := preload("res://scripts/apps.gd")
const Paths := preload("res://scripts/paths.gd")
const Tokens := preload("res://theme/tokens.gd")

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
## The launched app showed its first window (D63).
signal app_window(app_id: String)
## The launched app showed no window within LAUNCH_TIMEOUT: the daemon said
## so, or the launcher's own deadline passed first (D63). Emitted once.
signal launch_timed_out(app_id: String)
## OK on a remote whose key X doesn't map (KEY_OK, KEY_SELECT, D82).
signal accept_pressed
## Power off or restart did not happen: no daemon on the box, or the daemon
## said the command failed. kind is "poweroff" or "restart".
signal power_failed(kind: String)
signal connected_changed(connected: bool)

## Seconds before the stand-in pretends an app exited or a power-off was a
## dry run. Below 0 it never does (tests).
@export var stub_delay := 1.5
## Where the port and token files are. Empty uses BOSCAMOR_IPC if set, else
## Paths.runtime_dir().
@export var runtime_dir := ""

var calls: Array = []
## Off Linux (the Windows dev machine) a launch with no daemon is faked. On the
## box it fails with a toast, so a daemon that never started can't hide (D66).
var stand_in := OS.get_name() != "Linux"
var connected := false
## The app waiting for its first window, or "".
var waiting_id := ""
## Tests set this to drive the launch deadline; below 0 reads the real clock.
var fake_now_ms := -1
var _window_deadline := 0

var _peer: StreamPeerTCP
var _token := ""
var _sent_token := false
var _buf := PackedByteArray()      # bytes read but not yet a whole line
var _retry_in := 0.0
var _visible := true
var _timer: Timer


func _ready() -> void:
	# The poll timer is the one node that runs while the tree is paused.
	_timer = Timer.new()
	_timer.wait_time = Tokens.DAEMON_POLL
	_timer.process_mode = PROCESS_MODE_ALWAYS
	_timer.timeout.connect(poll)
	add_child(_timer)
	_timer.start()
	poll()


# Commands ---------------------------------------------------------------------

func launch(app: Dictionary) -> void:
	_record(["launch", app.id])
	waiting_id = app.id
	# After the daemon's own 15 s, plus the wait before it shows the window (D77).
	_window_deadline = _now_ms() + int(Tokens.LAUNCH_BACKUP * 1000.0)
	if not _send({"cmd": "launch", "id": app.id, "argv": Apps.argv_for(app),
			"keep_on_home": app.get("keep_on_home", false)}):
		if not stand_in:
			_stop_waiting(app.id)
			push_warning("no daemon: cannot launch %s" % app.id)
			launch_failed.emit.call_deferred(app.id, "the background service isn't running")
			return
		_later(func():
			_stop_waiting(app.id)
			app_exited.emit(app.id, 0))


## kind is "poweroff" or "restart". Only ever after the confirm.
func power(kind: String) -> void:
	_record(["power", kind])
	if _send({"cmd": "power", "action": "reboot" if kind == "restart" else kind}):
		return
	if stand_in:
		_later(show_home.emit)         # the dev machine: as if it were a dry run (D28)
		return
	# On the box with no daemon nothing can power off: say so, like a launch (D66).
	push_warning("no daemon: cannot %s" % kind)
	power_failed.emit.call_deferred(kind)


func show_desktop() -> void:
	_record(["show_desktop"])
	_visible = false
	_send_hiding({"cmd": "desktop"})


## Show me: raise a window still open (the launcher has hidden).
func show_window(wid: String) -> void:
	_record(["show_window", wid])
	_visible = false
	_send_hiding({"cmd": "show_window", "wid": wid})


## Close anyway, after the confirm. The daemon uses xkill -id per window.
func force_close(wids: Array) -> void:
	_record(["force_close"] + wids)
	_send({"cmd": "force_close", "wids": wids})


## Back to desktop: hide, close nothing, no notification this time.
func back_to_desktop() -> void:
	_record(["back_to_desktop"])
	_visible = false
	_send_hiding({"cmd": "desktop", "notify": false})


# The desktop still works with no daemon on the box (Cinnamon's own menus are
# the way out then), but Home can't bring the launcher back: say so in the log.
func _send_hiding(msg: Dictionary) -> void:
	if not _send(msg) and not stand_in:
		push_warning("no daemon: Home won't bring the launcher back; click it in the taskbar")


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

## BOSCAMOR_IPC=<port>:<token> as {port, token}, or {} if unset or malformed.
## The Windows dev launcher uses it to reach the WSL2 daemon (SPEC "IPC").
static func parse_ipc(value: String) -> Dictionary:
	var i := value.find(":")
	if i <= 0:
		return {}
	var port := value.left(i).strip_edges()
	var token := value.substr(i + 1).strip_edges()
	if not port.is_valid_int() or int(port) <= 0 or int(port) > 65535 or token.is_empty():
		return {}
	return {"port": int(port), "token": token}


## Where to connect: {port, token}, or {} if there is no daemon to find. An
## explicit runtime_dir (tests) wins, then BOSCAMOR_IPC, then the runtime files.
func _endpoint() -> Dictionary:
	var dir := runtime_dir
	if dir.is_empty():
		var ipc := parse_ipc(OS.get_environment("BOSCAMOR_IPC"))
		if not ipc.is_empty():
			return ipc
		dir = Paths.runtime_dir()
	if dir.is_empty():
		return {}
	var port := FileAccess.get_file_as_string(dir.path_join("port")).strip_edges()
	var token := FileAccess.get_file_as_string(dir.path_join("token")).strip_edges()
	if not port.is_valid_int() or token.is_empty():
		return {}
	return {"port": int(port), "token": token}


func _now_ms() -> int:
	return fake_now_ms if fake_now_ms >= 0 else Time.get_ticks_msec()


# The launch deadline lives here because this poll is the one thing that runs
# while the launcher is hidden (SPEC Resource use).
func _check_launch() -> void:
	if not waiting_id.is_empty() and _now_ms() >= _window_deadline:
		_timed_out(waiting_id)


func _timed_out(app_id: String) -> void:
	if app_id != waiting_id:
		return       # already timed out here, or an older launch
	waiting_id = ""
	print("no window from %s in time" % app_id)
	launch_timed_out.emit(app_id)


func _stop_waiting(app_id: String) -> void:
	if app_id == waiting_id:
		waiting_id = ""


## Runs every DAEMON_POLL: connects, reads, and dispatches events.
func poll() -> void:
	_check_launch()
	if _peer == null:
		_retry_in -= Tokens.DAEMON_POLL
		if _retry_in <= 0.0:
			_retry_in = Tokens.DAEMON_RETRY
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
	var ep := _endpoint()
	if ep.is_empty():
		return
	_token = ep.token
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host("127.0.0.1", ep.port) != OK:
		_peer = null
		return
	_sent_token = false
	_buf = PackedByteArray()


func _disconnect() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_peer = null
	_retry_in = Tokens.DAEMON_RETRY
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
	# Decoded a whole line at a time: a read can end inside a character.
	_buf.append_array(got[1])
	while true:
		var i := _buf.find(10)          # "\n"
		if i < 0:
			break
		var line := _buf.slice(0, i).get_string_from_utf8()
		_buf = _buf.slice(i + 1)
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
			if msg.get("replaced", false):
				# D86: a new launch ended it. That launch is still on its way, and
				# the daemon starts it now, so its window deadline starts again too.
				if not waiting_id.is_empty():
					_window_deadline = _now_ms() + int(Tokens.LAUNCH_BACKUP * 1000.0)
				return
			_stop_waiting(str(msg.get("id", "")))
			app_exited.emit(str(msg.get("id", "")), int(msg.get("code", 0)))
		"launch_failed":
			_stop_waiting(str(msg.get("id", "")))
			launch_failed.emit(str(msg.get("id", "")), str(msg.get("error", "")))
		"app_window":
			_stop_waiting(str(msg.get("id", "")))
			app_window.emit(str(msg.get("id", "")))
		"launch_timeout":
			_timed_out(str(msg.get("id", "")))
		"still_open":
			var list = msg.get("apps", [])
			still_open.emit(list if list is Array else [])
		"accept":
			accept_pressed.emit()
		"power_failed":
			power_failed.emit("restart" if str(msg.get("action", "")) in ["reboot", "restart"] else "poweroff")
		"memory_warning":
			var app_id = msg.get("id")
			memory_warning.emit("" if app_id == null else str(app_id), int(msg.get("available_mb", 0)))
		var other:
			push_warning("daemon: unknown event %s" % other)
