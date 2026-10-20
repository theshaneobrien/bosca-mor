# Settings > Startup: the launcher's own XDG autostart entry, which the
# installer writes. Turning it off sets X-GNOME-Autostart-enabled=false,
# which Cinnamon honours; the file itself stays.
extends RefCounted

const Apps := preload("res://scripts/apps.gd")

const KEY := "X-GNOME-Autostart-enabled"


static func default_path() -> String:
	var xdg := OS.get_environment("XDG_CONFIG_HOME")
	if xdg.is_empty():
		xdg = Apps.home_dir().path_join(".config")
	return xdg.path_join("autostart/boscamor.desktop")


static func installed(path := "") -> bool:
	return FileAccess.file_exists(path if path else default_path())


static func enabled(path := "") -> bool:
	if not installed(path):
		return false
	for line in FileAccess.get_file_as_string(path if path else default_path()).split("\n"):
		var l := line.strip_edges()
		if l == KEY + "=false" or l == "Hidden=true":
			return false
	return true


## Rewrites the entry with the switch set. False if there is no entry.
static func set_enabled(on: bool, path := "") -> bool:
	if path.is_empty():
		path = default_path()
	if not installed(path):
		return false
	var lines: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var l := line.strip_edges()
		if l.begins_with(KEY + "=") or l.begins_with("Hidden="):
			continue
		lines.append(line)
	while not lines.is_empty() and lines[-1].strip_edges().is_empty():
		lines.pop_back()
	var at := lines.size()
	for i in lines.size():   # keep the key inside [Desktop Entry]
		if i > 0 and lines[i].strip_edges().begins_with("["):
			at = i
			break
	lines.insert(at, "%s=%s" % [KEY, "true" if on else "false"])
	return Apps.write_atomic(path, "\n".join(lines) + "\n") == OK
