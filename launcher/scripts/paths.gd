# The one place the launcher builds config, state, cache, icon, profile and
# runtime paths (Law 13). On the box they follow XDG. When BOSCAMOR_HOME is
# set (the Windows dev machine), they all sit under it instead; a relative
# value resolves against the repo root, so BOSCAMOR_HOME=dev-home means the
# repo's gitignored dev-home/. The daemon's paths() mirrors this layout.
extends RefCounted

## Default configs write browser profiles here; apps.gd swaps in profiles_dir().
const PROFILES_IN_CONFIG := "/home/USER/.local/share/boscamor/profiles"


## BOSCAMOR_HOME as an absolute path, or "" when unset.
static func dev_home() -> String:
	var h := OS.get_environment("BOSCAMOR_HOME").strip_edges()
	if h.is_empty():
		return ""
	h = h.replace("\\", "/")
	if not h.is_absolute_path():
		h = repo_root().path_join(h)
	return h.simplify_path()


## The folder above launcher/. Only used to resolve a relative BOSCAMOR_HOME.
static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


## The user's home folder: $HOME, or %USERPROFILE% on Windows.
static func user_home() -> String:
	var h := OS.get_environment("HOME")
	if h.is_empty():
		h = OS.get_environment("USERPROFILE")
	return h


static func _xdg(var_name: String, fallback: String) -> String:
	var d := OS.get_environment(var_name)
	return d if not d.is_empty() else user_home().path_join(fallback)


static func config_dir() -> String:
	var h := dev_home()
	return h.path_join("config") if h else _xdg("XDG_CONFIG_HOME", ".config").path_join("boscamor")


static func apps_json() -> String:
	return config_dir().path_join("apps.json")


static func state_json() -> String:
	var h := dev_home()
	if h:
		return h.path_join("state/state.json")
	return _xdg("XDG_STATE_HOME", ".local/state").path_join("boscamor/state.json")


## Drop-in brand icons (Law 11): <id>.svg or .png.
static func icons_dir() -> String:
	return config_dir().path_join("icons")


## Rasterised SVG icons.
static func icon_cache_dir() -> String:
	var h := dev_home()
	return h.path_join("cache/icons") if h else _xdg("XDG_CACHE_HOME", ".cache").path_join("boscamor/icons")


## One Firefox profile per browser tile lives under here.
static func profiles_dir() -> String:
	var h := dev_home()
	return h.path_join("profiles") if h else user_home().path_join(".local/share/boscamor/profiles")


## The launcher's own XDG autostart entry (Settings > Startup).
static func autostart_file() -> String:
	var h := dev_home()
	if h:
		return h.path_join("autostart/boscamor.desktop")
	return _xdg("XDG_CONFIG_HOME", ".config").path_join("autostart/boscamor.desktop")


## Where the daemon writes its port and token: BOSCAMOR_RUNTIME_DIR (D29),
## then BOSCAMOR_HOME, then $XDG_RUNTIME_DIR/boscamor. "" when none is set.
static func runtime_dir() -> String:
	var d := OS.get_environment("BOSCAMOR_RUNTIME_DIR")
	if not d.is_empty():
		return d
	var h := dev_home()
	if h:
		return h.path_join("runtime")
	var xdg := OS.get_environment("XDG_RUNTIME_DIR")
	return "" if xdg.is_empty() else xdg.path_join("boscamor")


# Where other apps install themselves. These are the system's, not ours, so
# BOSCAMOR_HOME does not move them.

static func data_home() -> String:
	return _xdg("XDG_DATA_HOME", ".local/share")


## Folders holding installed apps' .desktop files, first wins.
static func desktop_dirs() -> Array[String]:
	return [
		data_home().path_join("applications"),
		data_home().path_join("flatpak/exports/share/applications"),
		"/var/lib/flatpak/exports/share/applications",
		"/usr/local/share/applications",
		"/usr/share/applications",
	]


static func flatpak_icon_dirs() -> Array:
	return [
		"/var/lib/flatpak/exports/share/icons/hicolor",
		user_home().path_join(".local/share/flatpak/exports/share/icons/hicolor"),
	]


static func theme_icon_dirs() -> Array:
	return [
		user_home().path_join(".local/share/icons/hicolor"),
		"/usr/share/icons/hicolor",
	]


static func pixmap_dirs() -> Array:
	return ["/usr/share/pixmaps"]
