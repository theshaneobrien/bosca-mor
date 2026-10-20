# Reads state.json (state, not config). Writes come with the features that
# change state, and go through a temp file and a rename.
extends RefCounted

const Apps := preload("res://scripts/apps.gd")


static func default_path() -> String:
	var xdg := OS.get_environment("XDG_STATE_HOME")
	if xdg.is_empty():
		xdg = Apps.home_dir().path_join(".local/state")
	return xdg.path_join("boscamor/state.json")


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
