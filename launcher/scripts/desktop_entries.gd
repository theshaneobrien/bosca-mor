# Installed apps from their .desktop files, for Settings > Apps > Add app.
# Follows the Desktop Entry spec closely enough for Exec lines: quoting,
# escapes, and field codes (%u, %F and the rest) dropped.
extends RefCounted

const Apps := preload("res://scripts/apps.gd")

const FIELD_CODES := ["%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k", "%v", "%m"]
const KINDS := {
	"Video": ["AudioVideo", "Video", "TV", "Player"],
	"Music": ["Audio", "Music"],
	"Games": ["Game", "Emulator"],
	"Web": ["WebBrowser", "Network"],
}


static func dirs() -> Array[String]:
	var home := Apps.home_dir()
	var data_home := OS.get_environment("XDG_DATA_HOME")
	if data_home.is_empty():
		data_home = home.path_join(".local/share")
	return [
		data_home.path_join("applications"),
		data_home.path_join("flatpak/exports/share/applications"),
		"/var/lib/flatpak/exports/share/applications",
		"/usr/local/share/applications",
		"/usr/share/applications",
	]


## Every launchable entry, one per desktop file name (the first folder wins),
## sorted by name. Each: {file, name, argv, kind, comment, icon}.
static func scan(folders: Array = []) -> Array:
	if folders.is_empty():
		folders = dirs()
	var seen := {}
	var out := []
	for d in folders:
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
			or keys.get("Hidden", "") == "true" or not keys.has("Name") or not keys.has("Exec"):
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


static func exec_to_argv(exec: String) -> Array[String]:
	var args: Array[String] = []
	var cur := ""
	var quoted := false
	var started := false
	var i := 0
	while i < exec.length():
		var c := exec[i]
		if quoted:
			if c == "\\" and i + 1 < exec.length():
				i += 1
				cur += exec[i]
			elif c == "\"":
				quoted = false
			else:
				cur += c
		elif c == "\"":
			quoted = true
			started = true
		elif c == " " or c == "\t":
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


static func kind_for(categories: String) -> String:
	var cats := categories.split(";", false)
	for kind in KINDS:
		for c in KINDS[kind]:
			if c in cats:
				return kind
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
