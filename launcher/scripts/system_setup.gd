# Keeps the TV picture and sound as Settings has them (D79, D80): at login,
# again every few seconds for the first half minute (the adapter and the
# desktop can still change things then), and each time the launcher comes
# back. Also lists and joins Wi-Fi networks for Settings (D81). xrandr, pactl
# and nmcli run one job at a time on a worker thread, each under `timeout`,
# so a slow or stuck one never holds up the launcher.
extends Node

const Tokens := preload("res://theme/tokens.gd")
const Display := preload("res://scripts/display.gd")
const Sound := preload("res://scripts/sound.gd")
const Network := preload("res://scripts/network.gd")

## Bytes read from a command's output at a time.
const _READ_CHUNK := 65536
## The word before a password in nmcli's argv; the log hides what follows.
const _SECRET_AFTER := ["password", "wifi-sec.psk"]

## A check finished; display and sound hold the latest results.
signal changed
## A picture change from Settings finished: Display.ensure's result.
signal picture_done(result: Dictionary)
## Joining a Wi-Fi network finished: Network.join's result.
signal wifi_done(result: Dictionary)

## On only in an exported build (what deploy.sh ships to the box) on Linux
## with an X display: see can_run. Elsewhere nothing runs. BOSCAMOR_DRY_RUN=1
## logs changes instead.
var enabled := can_run(OS.get_name(), OS.get_environment("DISPLAY"), DisplayServer.get_name(),
	OS.has_feature("template"))
## Tests run jobs on the calling thread with a fake runner.
var threaded := true
var run: Callable = run_command
var display_mode := "1920x1080@60"
var sound_output := "hdmi"
var volume := 100
## Latest results, for Settings: Display.ensure and Sound.ensure.
var display := {}
var sound := {}
## The last Wi-Fi scan (Network.scan), and the network being joined.
var wifi := {}
var joining := ""

var _thread: Thread
var _queue: Array = []
var _running := ""                # the kind of job on the worker
var _boot_left := 0
var _volume_done := false
var _timer: Timer


## Whether picture, sound and Wi-Fi may be changed. Only an exported build
## (template) may: `godot --path launcher` on a Linux desktop, shots and tests
## leave the dev machine's screen and sound alone, and so does a headless run
## or one without an X display.
static func can_run(os_name: String, display: String, server: String, template: bool) -> bool:
	return template and os_name == "Linux" and not display.is_empty() and server != "headless"


func _ready() -> void:
	_timer = Timer.new()
	# Paused with the tree while an app is in front (Law 5); the launcher
	# checks again when it comes back anyway.
	_timer.wait_time = Tokens.SETUP_CHECK_EVERY
	_timer.timeout.connect(_on_boot_timer)
	add_child(_timer)


func _exit_tree() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func configure(prefs: Dictionary) -> void:
	display_mode = prefs.get("display_mode", display_mode)
	sound_output = prefs.get("sound_output", sound_output)
	volume = prefs.get("volume", volume)


## At login: check now, then every SETUP_CHECK_EVERY for the first 30 s.
func start() -> void:
	if not enabled:
		return
	_boot_left = Tokens.SETUP_BOOT_CHECKS - 1
	check(true)
	_timer.start()


func _on_boot_timer() -> void:
	if _boot_left <= 0:
		_timer.stop()
		return
	_boot_left -= 1
	check(true)


## Puts picture and sound back as Settings has them. probe: ask the TV
## again (login) rather than what X already knows (the launcher came back).
func check(probe := false) -> void:
	if not enabled:
		return
	for j in _queue:
		if j.kind == "check":
			j.probe = j.probe or probe   # one is already waiting; a login check stays strict (D83)
			return
	_push({"kind": "check", "probe": probe})


## A Picture change from Settings; picture_done follows. Until it is kept
## or undone, the checks hold the screen at mode too.
func try_picture(mode: String) -> void:
	if not enabled:
		picture_done.emit.call_deferred({"ok": false, "error": "not on the box"})
		return
	display_mode = mode
	_push({"kind": "picture", "mode": mode, "reply": true})


## Back to the picture before a change that wasn't kept.
func undo_picture(mode: String) -> void:
	display_mode = mode
	if enabled:
		_push({"kind": "picture", "mode": mode, "reply": false})


## Sound output or volume changed in Settings: apply it now.
func apply_sound(set_volume: bool) -> void:
	if enabled:
		_push({"kind": "sound", "volume_now": set_volume})


## Networks in range; rescan asks the Wi-Fi card to look again.
func wifi_scan(rescan := false) -> void:
	if not enabled:
		return
	for j in _queue:
		if j.kind == "wifi_scan":
			j.rescan = j.rescan or rescan
			return
	_push({"kind": "wifi_scan", "rescan": rescan})


func wifi_join(ssid: String, password: String, known: bool) -> void:
	if not enabled or not joining.is_empty():
		return
	joining = ssid
	_push({"kind": "wifi_join", "ssid": ssid, "password": password, "known": known})


## A Wi-Fi scan is waiting or running (Settings shows "Searching").
func wifi_scanning() -> bool:
	if _running == "wifi_scan":
		return true
	for j in _queue:
		if j.kind == "wifi_scan":
			return true
	return false


func busy() -> bool:
	return _thread != null or not _queue.is_empty()


func _push(job: Dictionary) -> void:
	# Each job carries the settings it was asked with.
	job.display_mode = display_mode
	job.sound_output = sound_output
	job.volume = volume
	if job.kind == "check" and not _volume_done:
		job.set_volume = true
	_queue.append(job)
	_next()


func _next() -> void:
	if _thread != null or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	_running = job.kind
	if not threaded:
		_finish(job, _work(job))
		return
	_thread = Thread.new()
	_thread.start(func(): _finish.call_deferred(job, _work(job)))


# On the worker thread: no nodes, only run.
func _work(job: Dictionary) -> Dictionary:
	var out := {}
	match job.kind:
		"picture":
			out.display = Display.ensure(job.mode, run)
		"sound":
			out.sound = Sound.ensure(job.sound_output, job.volume if job.volume_now else -1, run)
		"wifi_scan":
			out.wifi = Network.scan(run, job.rescan)
		"wifi_join":
			out.wifi_join = Network.join(job.ssid, job.password, job.known, run)
			out.wifi = Network.scan(run)
		"check":
			if job.display_mode != "auto":
				out.display = Display.ensure(job.display_mode, run, job.probe)
			if job.sound_output != "auto" or job.get("set_volume", false):
				out.sound = Sound.ensure(job.sound_output, job.volume if job.get("set_volume", false) else -1, run)
	return out


func _finish(job: Dictionary, out: Dictionary) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_running = ""
	if out.has("wifi"):
		wifi = out.wifi
	if out.has("wifi_join"):
		joining = ""
		print("wifi: %s %s" % ["joined" if out.wifi_join.ok else "could not join", out.wifi_join.ssid])
		wifi_done.emit(out.wifi_join)
	if out.has("display"):
		display = out.display
		_log_picture(out.display, job.get("probe", true))
	if out.has("sound"):
		sound = out.sound
		_log("sound", out.sound)
		if job.get("set_volume", false) and out.sound.ok:
			_volume_done = true
	if job.get("reply", false):
		picture_done.emit(out.display)
	changed.emit()
	_next()


# Every check that reads the TV again (login, Settings) says what the screen
# was on, so a bad boot is in the launcher's log after a replug (D83).
func _log_picture(r: Dictionary, probe: bool) -> void:
	if not r.get("ok", false):
		print("picture: %s%s" % [r.get("error", "failed"), " on " + r.output if r.has("output") else ""])
	elif r.changed or probe:
		print("picture: %s was %s" % [r.output, r.was])
	if r.get("changed", false):
		for step in r.steps:
			print("picture: ran %s" % " ".join(step))
		print("picture: %s timings: %s" % [Display.describe(r.mode), "; ".join(r.modes)])


func _log(what: String, r: Dictionary) -> void:
	if not r.get("ok", false):
		print("%s: %s" % [what, r.get("error", "failed")])
	elif r.get("changed", false):
		print("%s: set %s" % [what, Display.describe(r.mode) if r.has("mode") else r.get("playing", "")])


## xrandr, pactl or nmcli, with C-locale output and a time limit. Never a
## shell (Law 3): OS.execute with an output array runs through /bin/sh on
## Linux, which would change or run a Wi-Fi name or password, so the command
## runs from execute_with_pipe. stderr: add it to out (nmcli says why a join
## failed there). Waits for the command, so the worker thread only. Under
## BOSCAMOR_DRY_RUN=1 a command that changes something is logged, not run.
static func run_command(argv: Array, limit_s := Tokens.SETUP_CMD_TIMEOUT, stderr := false) -> Dictionary:
	if OS.get_environment("BOSCAMOR_DRY_RUN") == "1" and not reads_only(argv):
		print("dry run: %s" % shown(argv))
		return {"code": 0, "out": ""}
	var args := PackedStringArray([str(limit_s), "env", "LC_ALL=C"])
	args.append_array(PackedStringArray(argv))
	var p := OS.execute_with_pipe("timeout", args, false)
	if p.is_empty():
		return {"code": -1, "out": ""}
	var io: FileAccess = p.stdio
	var err: FileAccess = p.stderr
	var out := PackedByteArray()
	var errs := PackedByteArray()
	while true:
		# Asked before reading, so whatever it wrote before it ended is read.
		var running := OS.is_process_running(p.pid)
		var a := io.get_buffer(_READ_CHUNK)
		var b := err.get_buffer(_READ_CHUNK)
		out.append_array(a)
		errs.append_array(b)
		if a.is_empty() and b.is_empty():
			if not running:
				break
			OS.delay_msec(Tokens.SETUP_CMD_POLL_MS)
	io.close()
	err.close()
	var text := out.get_string_from_utf8()
	if stderr:
		text += errs.get_string_from_utf8()
	return {"code": OS.get_process_exit_code(p.pid), "out": text}


## The commands that only read: xrandr --verbose [--current], pactl list and
## info, and nmcli's terse device list, Wi-Fi list and saved connections. A
## dry run still runs these.
static func reads_only(argv: Array) -> bool:
	if argv.is_empty():
		return false
	match argv[0]:
		"xrandr":
			return argv.slice(1).all(func(a): return a in ["--verbose", "--current"])
		"pactl":
			return argv.size() > 1 and argv[1] in ["list", "info"]
		"nmcli":
			if argv.size() < 5 or argv[1] != "-t" or argv[2] != "-f":
				return false
			var rest := argv.slice(4)
			return rest == ["device"] or rest == ["connection", "show"] \
				or rest.slice(0, 3) == ["device", "wifi", "list"]
	return false


## argv for the log, with any password hidden.
static func shown(argv: Array) -> String:
	var words := PackedStringArray()
	for i in argv.size():
		words.append("(hidden)" if i > 0 and argv[i - 1] in _SECRET_AFTER else str(argv[i]))
	return " ".join(words)
