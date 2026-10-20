# The one way the launcher talks to boscamor-input. This is the stub: it
# records calls and logs them, and never acts on the machine. Step 5 swaps
# the insides for the real IPC; the methods and signals stay.
extends Node

## The daemon wants Home shown: Home or Guide pressed, or Desktop ended.
signal show_home
## The app launched from a tile has gone.
signal app_exited(app_id: String)
## The remote's power key (the daemon sees it; the launcher never does).
signal power_pressed

## Seconds before the stub pretends an app exited or a power-off was a dry
## run. Below 0, it never does (tests).
@export var stub_delay := 1.5

var calls: Array = []


func launch(app: Dictionary) -> void:
	_record(["launch", app.id])
	_later(func(): app_exited.emit(app.id))


func power(kind: String) -> void:
	_record(["power", kind])
	_later(show_home.emit)


func show_desktop() -> void:
	_record(["show_desktop"])


func _record(call_args: Array) -> void:
	calls.append(call_args)
	print("daemon stub: ", " ".join(call_args))


func _later(f: Callable) -> void:
	if stub_delay >= 0.0 and is_inside_tree():
		get_tree().create_timer(stub_delay).timeout.connect(f)
