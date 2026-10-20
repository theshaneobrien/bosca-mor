# Reads and writes state.json (state, not config). Writes go through a temp
# file and a rename, and keep keys they don't know.
extends RefCounted

const Apps := preload("res://scripts/apps.gd")
const Paths := preload("res://scripts/paths.gd")


static func default_path() -> String:
	return Paths.state_json()


## The state as a Dictionary; missing or unreadable gives {}.
static func load_file(path := "") -> Dictionary:
	if path.is_empty():
		path = default_path()
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		push_warning("state.json unreadable, using defaults: %s" % path)
		return {}
	return json.data


## Merges `changes` into the state file and writes it atomically.
static func update(changes: Dictionary, path := "") -> Error:
	if path.is_empty():
		path = default_path()
	var data := load_file(path)
	data.merge(changes, true)
	return Apps.write_atomic(path, JSON.stringify(data, "  ") + "
")
