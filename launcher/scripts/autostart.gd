# Settings > Startup: the launcher's own XDG autostart entry, which the
# installer writes. Turning it off sets X-GNOME-Autostart-enabled=false,
# which Cinnamon honours; the file itself stays.
extends RefCounted

const Apps := preload("res://scripts/apps.gd")
const Paths := preload("res://scripts/paths.gd")

const KEY := "X-GNOME-Autostart-enabled"
const GROUP := "[Desktop Entry]"


static func default_path() -> String:
	return Paths.autostart_file()


static func installed(path := "") -> bool:
	return FileAccess.file_exists(path if path else default_path())


static func enabled(path := "") -> bool:
	if not installed(path):
		return false
	var lines: Array[String] = []
	lines.assign(FileAccess.get_file_as_string(path if path else default_path()).split("\n"))
	var group := _group(lines)
	if group.x < 0:
		return false
	for line in lines:
		if line.strip_edges().begins_with("["):
			break
		if _is_switch(line):
			return false   # an older build's key above the group: the whole file is rejected
	for i in range(group.x + 1, group.y):
		var l := lines[i].strip_edges()
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
	lines.assign(FileAccess.get_file_as_string(path).split("\n"))
	var group := _group(lines)
	if group.x < 0:
		return false   # not a desktop entry; leave it alone
	# Only [Desktop Entry] is touched: a key above it (after a leading comment,
	# say) makes the whole file invalid. An older build wrote the switch there,
	# so take any such line out; no key is valid above the first group.
	var i := 0
	while i < lines.size() and not lines[i].strip_edges().begins_with("["):
		if _is_switch(lines[i]):
			lines.remove_at(i)
		else:
			i += 1
	group = _group(lines)
	var at := group.y
	for k in range(group.y - 1, group.x, -1):
		if _is_switch(lines[k]):
			lines.remove_at(k)
			at -= 1
	while at > group.x + 1 and lines[at - 1].strip_edges().is_empty():
		at -= 1
	lines.insert(at, "%s=%s" % [KEY, "true" if on else "false"])
	while not lines.is_empty() and lines[-1].strip_edges().is_empty():
		lines.pop_back()
	return Apps.write_atomic(path, "\n".join(lines) + "\n") == OK


# [Desktop Entry]'s header line and the line after its last one (the next
# group's header, or the end), as (header, end); (-1, -1) if it isn't there.
static func _group(lines: Array[String]) -> Vector2i:
	var head := -1
	for i in lines.size():
		var l := lines[i].strip_edges()
		if head < 0:
			if l == GROUP:
				head = i
		elif l.begins_with("["):
			return Vector2i(head, i)
	return Vector2i(head, lines.size()) if head >= 0 else Vector2i(-1, -1)


static func _is_switch(line: String) -> bool:
	var l := line.strip_edges()
	return l.begins_with(KEY + "=") or l.begins_with("Hidden=")
