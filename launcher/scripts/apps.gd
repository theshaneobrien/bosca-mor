# Loads apps.json (config). Never writes state here; that is state.json.
extends RefCounted

const DEFAULT_PATH := "res://data/apps.default.json"
const REQUIRED := ["id", "name", "kind", "description", "tint", "accent", "argv"]
const OPTIONAL := {
	"icon": "",
	"glyph": "",
	"url": "",
	"url_editable": false,
	"keep_on_home": false,
	"hidden": false,
	"icon_style": "inset",
}


static func home_dir() -> String:
	var h := OS.get_environment("HOME")
	if h.is_empty():
		h = OS.get_environment("USERPROFILE")
	return h


static func config_dir() -> String:
	var xdg := OS.get_environment("XDG_CONFIG_HOME")
	if xdg.is_empty():
		xdg = home_dir().path_join(".config")
	return xdg.path_join("boscamor")


# The user's apps.json, or the bundled default when there is none yet.
static func default_source() -> String:
	var user := config_dir().path_join("apps.json")
	return user if FileAccess.file_exists(user) else DEFAULT_PATH


# Returns {"apps": Array[Dictionary], "errors": Array[String]}. Bad entries are
# skipped with an error; a bad file gives an empty list, never a crash.
static func load_file(path := "") -> Dictionary:
	if path.is_empty():
		path = default_source()
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {"apps": [], "errors": ["cannot read %s" % path]}
	return parse(text)


static func parse(text: String) -> Dictionary:
	var errors: Array[String] = []
	var apps: Array[Dictionary] = []
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"apps": apps, "errors": ["apps.json line %d: %s" % [json.get_error_line(), json.get_error_message()]]}
	var data = json.data
	if not data is Array:
		return {"apps": apps, "errors": ["apps.json is not a JSON array"]}
	var seen := {}
	for i in data.size():
		var raw = data[i]
		if not raw is Dictionary:
			errors.append("entry %d is not an object" % i)
			continue
		var err := _check(raw)
		if err.is_empty() and seen.has(raw.id):
			err = "duplicate id"
		if not err.is_empty():
			errors.append("entry %d (%s): %s" % [i, raw.get("id", "?"), err])
			continue
		seen[raw.id] = true
		apps.append(_normalise(raw))
	return {"apps": apps, "errors": errors}


static func visible(apps: Array) -> Array:
	return apps.filter(func(a): return not a.hidden)


static func _check(raw: Dictionary) -> String:
	for key in REQUIRED:
		if not raw.has(key):
			return "missing %s" % key
	for key in ["id", "name", "kind", "description"]:
		if not raw[key] is String or raw[key].is_empty():
			return "%s must be a non-empty string" % key
	for key in ["tint", "accent"]:
		if not raw[key] is String or not Color.html_is_valid(raw[key]):
			return "%s must be a hex colour" % key
	if not raw.argv is Array or raw.argv.is_empty():
		return "argv must be a non-empty array"
	for a in raw.argv:
		if not a is String:
			return "argv must hold only strings"
	return ""


static func _normalise(raw: Dictionary) -> Dictionary:
	var app := {}
	for key in REQUIRED:
		app[key] = raw[key]
	for key in OPTIONAL:
		var v = raw.get(key, OPTIONAL[key])
		app[key] = v if typeof(v) == typeof(OPTIONAL[key]) else OPTIONAL[key]
	app.tint = Color(app.tint)
	app.accent = Color(app.accent)
	var home := home_dir()
	var argv: Array[String] = []
	for a in raw.argv:
		argv.append(_expand(a, home))
	app.argv = argv
	app.icon = _expand(app.icon, home)
	return app


# JSON has no "~", so default paths say /home/USER.
static func _expand(s: String, home: String) -> String:
	if home.is_empty():
		return s
	return s.replace("/home/USER", home)
