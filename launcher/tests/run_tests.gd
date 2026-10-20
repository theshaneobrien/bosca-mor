# Minimal test runner: loads every tests/test_*.gd, calls each test_* method,
# prints failures and exits with the failure count.
# godot --headless --path launcher -s res://tests/run_tests.gd
extends SceneTree

const DIR := "res://tests"


# Script errors raised while a test runs count as failures of that test.
class ErrorCatcher extends Logger:
	var errors: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		errors.append("%s (%s:%d %s)" % [rationale if rationale else code, file, line, function])
		_mutex.unlock()

	func take() -> Array[String]:
		_mutex.lock()
		var e := errors.duplicate()
		errors.clear()
		_mutex.unlock()
		return e


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var failures := 0
	var passed := 0
	var files := Array(DirAccess.get_files_at(DIR)).filter(
		func(f): return f.begins_with("test_") and f.ends_with(".gd"))
	files.sort()
	for f in files:
		var script: GDScript = load(DIR.path_join(f))
		if script == null or not script.can_instantiate():
			print("FAIL %s: does not load" % f)
			failures += 1
			continue
		for m in script.get_script_method_list():
			if not m.name.begins_with("test_"):
				continue
			catcher.take()
			var t: Object = script.new()
			t.set("tree", self)
			await t.call(m.name)
			var errs: Array = t.get("failures") + catcher.take()
			if errs.is_empty():
				passed += 1
			else:
				failures += 1
				for e in errs:
					print("FAIL %s %s: %s" % [f, m.name, e])
			if t is Node:
				t.free()
	print("%d passed, %d failed" % [passed, failures])
	quit(failures)
