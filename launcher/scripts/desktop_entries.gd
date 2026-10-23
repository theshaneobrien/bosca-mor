# Installed apps from their .desktop files, for Settings > Apps > Add app.
# Follows the Desktop Entry spec closely enough for Exec lines: the string
# escapes (\s, \\ and the rest) first, then quoting, and field codes (%u, %F
# and the rest) dropped. Single quotes are read too, as GLib does: Flatpak's
# exporter quotes arguments that way.
extends RefCounted

const Paths := preload("res://scripts/paths.gd")

const FIELD_CODES := ["%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k", "%v", "%m"]
const STRING_ESCAPES := {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
const QUOTED_ESCAPES := ["\"", "`", "$", "\\"]   # what a backslash escapes inside "..."
# The first kind with a matching category wins. Every music player also lists
# AudioVideo and often Player, so those generic ones come last.
const KINDS := [
	["Video", ["Video", "TV"]],
	["Music", ["Audio", "Music"]],
	["Games", ["Game", "Emulator"]],
	["Web", ["WebBrowser"]],
	["Video", ["AudioVideo", "Player"]],
]


static func dirs() -> Array[String]:
	return Paths.desktop_dirs()


## Every launchable entry, one per desktop file name (the first folder wins),
## sorted by name. Each: {file, name, argv, kind, comment, icon}.
static func scan(folders: Array = []) -> Array:
	if folders.is_empty():
		folders = dirs()
	var seen := {}
	var out := []
	for d in folders:
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			if not f.ends_with(".desktop") or seen.has(f):
				continue
			seen[f] = true
			var e := parse(FileAccess.get_file_as_string(d.path_join(f)))
			if e.is_empty():
				continue
			e.file = f
			out.append(e)
	out.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return out


## The [Desktop Entry] group of one file, or {} if it isn't a shown app.
static func parse(text: String) -> Dictionary:
	var keys := {}
	var in_group := false
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.begins_with("["):
			in_group = line == "[Desktop Entry]"
			continue
		if not in_group or line.begins_with("#") or not line.contains("="):
			continue
		var kv := line.split("=", true, 1)
		var k := kv[0].strip_edges()
		if not keys.has(k):
			keys[k] = kv[1].strip_edges()
	if keys.get("Type", "") != "Application" or keys.get("NoDisplay", "") == "true" \
			or keys.get("Hidden", "") == "true" or keys.get("Name", "").is_empty() or not keys.has("Exec"):
		return {}
	var argv := exec_to_argv(keys.Exec)
	if argv.is_empty():
		return {}
	return {
		"name": keys.Name,
		"argv": argv,
		"kind": kind_for(keys.get("Categories", "")),
		"comment": keys.get("Comment", keys.get("GenericName", "")),
		"icon": keys.get("Icon", ""),
	}


## The Exec value as it is written in the file, as an argv.
static func exec_to_argv(exec: String) -> Array[String]:
	exec = _unescape(exec)
	var args: Array[String] = []
	var cur := ""
	var quote := ""          # "", "\"" or "'"
	var started := false
	var i := 0
	while i < exec.length():
		var c := exec[i]
		if quote == "'":
			if c == "'":
				quote = ""
			else:
				cur += c
		elif quote == "\"":
			if c == "\\" and i + 1 < exec.length() and exec[i + 1] in QUOTED_ESCAPES:
				i += 1
				cur += exec[i]
			elif c == "\"":
				quote = ""
			else:
				cur += c
		elif c == "\"" or c == "'":
			quote = c
			started = true
		elif c == "\\" and i + 1 < exec.length():
			i += 1
			cur += exec[i]
			started = true
		elif c == " " or c == "\t" or c == "\n":
			if started:
				args.append(cur)
			cur = ""
			started = false
		else:
			cur += c
			started = true
		i += 1
	if started:
		args.append(cur)
	var out: Array[String] = []
	for a in args:
		if a in FIELD_CODES:
			continue
		a = a.replace("%%", "%")
		if not a.is_empty():
			out.append(a)
	return out


# The string escapes every .desktop value has. Others are left as they are.
static func _unescape(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "\\" and i + 1 < s.length() and STRING_ESCAPES.has(s[i + 1]):
			out += STRING_ESCAPES[s[i + 1]]
			i += 2
			continue
		out += s[i]
		i += 1
	return out


static func kind_for(categories: String) -> String:
	var cats := categories.split(";", false)
	for pair in KINDS:
		for c in pair[1]:
			if c in cats:
				return pair[0]
	return "Other"


## An apps.json id from the file name: org.foo.Bar.desktop -> org-foo-bar.
static func id_for(file: String, taken: Dictionary) -> String:
	var base := file.trim_suffix(".desktop").to_lower()
	var id := ""
	for c in base:
		id += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "-"
	id = id.strip_edges().trim_prefix("-").trim_suffix("-")
	if id.is_empty():
		id = "app"
	var out := id
	var n := 2
	while taken.has(out):
		out = "%s-%d" % [id, n]
		n += 1
	return out
