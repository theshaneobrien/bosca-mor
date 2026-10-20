# Base for test scripts. Methods named test_* are run by run_tests.gd.
extends RefCounted

var tree: SceneTree
var failures: Array[String] = []


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures.append(msg)


func eq(got, want, msg: String) -> void:
	if got != want:
		failures.append("%s: got %s, want %s" % [msg, got, want])
