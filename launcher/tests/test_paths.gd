extends "res://tests/test_case.gd"

# paths.gd: XDG on the box, everything under BOSCAMOR_HOME when it is set.

const Paths := preload("res://scripts/paths.gd")
const Apps := preload("res://scripts/apps.gd")
const StateFile := preload("res://scripts/state_file.gd")
const Autostart := preload("res://scripts/autostart.gd")
const IconResolver := preload("res://scripts/icon_resolver.gd")
const DaemonClient := preload("res://scripts/daemon_client.gd")

const VARS := ["BOSCAMOR_HOME", "BOSCAMOR_RUNTIME_DIR", "HOME", "XDG_CONFIG_HOME",
	"XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"]

var _saved := {}


func _env(values: Dictionary) -> void:
	for v in VARS:
		if not _saved.has(v):    # keep the first value, from before the test
			_saved[v] = OS.get_environment(v) if OS.has_environment(v) else null
		if values.has(v):
			OS.set_environment(v, values[v])
		else:
			OS.unset_environment(v)


func _restore() -> void:
	for v in _saved:
		if _saved[v] == null:
			OS.unset_environment(v)
		else:
			OS.set_environment(v, _saved[v])


func test_xdg_without_boscamor_home() -> void:
	_env({"HOME": "/home/tv", "XDG_CONFIG_HOME": "/x/cfg", "XDG_STATE_HOME": "/x/state",
		"XDG_CACHE_HOME": "/x/cache", "XDG_DATA_HOME": "/x/data", "XDG_RUNTIME_DIR": "/run/user/1000"})
	eq(Paths.dev_home(), "", "dev_home")
	eq(Paths.config_dir(), "/x/cfg/boscamor", "config_dir")
	eq(Paths.apps_json(), "/x/cfg/boscamor/apps.json", "apps_json")
	eq(Paths.state_json(), "/x/state/boscamor/state.json", "state_json")
	eq(Paths.icons_dir(), "/x/cfg/boscamor/icons", "icons_dir")
	eq(Paths.icon_cache_dir(), "/x/cache/boscamor/icons", "icon_cache_dir")
	eq(Paths.profiles_dir(), "/home/tv/.local/share/boscamor/profiles", "profiles_dir")
	eq(Paths.autostart_file(), "/x/cfg/autostart/boscamor.desktop", "autostart_file")
	eq(Paths.runtime_dir(), "/run/user/1000/boscamor", "runtime_dir")
	eq(Paths.desktop_dirs()[0], "/x/data/applications", "desktop_dirs")
	_restore()


func test_xdg_fallbacks_to_home() -> void:
	_env({"HOME": "/home/tv"})
	eq(Paths.apps_json(), "/home/tv/.config/boscamor/apps.json", "apps_json")
	eq(Paths.state_json(), "/home/tv/.local/state/boscamor/state.json", "state_json")
	eq(Paths.icon_cache_dir(), "/home/tv/.cache/boscamor/icons", "icon_cache_dir")
	eq(Paths.autostart_file(), "/home/tv/.config/autostart/boscamor.desktop", "autostart_file")
	eq(Paths.runtime_dir(), "", "no XDG_RUNTIME_DIR, no runtime dir")
	_restore()


func test_everything_under_boscamor_home() -> void:
	_env({"BOSCAMOR_HOME": "/x/dev", "HOME": "/home/tv", "XDG_CONFIG_HOME": "/x/cfg",
		"XDG_STATE_HOME": "/x/state", "XDG_CACHE_HOME": "/x/cache", "XDG_RUNTIME_DIR": "/run/user/1000"})
	eq(Paths.dev_home(), "/x/dev", "dev_home")
	eq(Paths.apps_json(), "/x/dev/config/apps.json", "apps_json")
	eq(Paths.state_json(), "/x/dev/state/state.json", "state_json")
	eq(Paths.icons_dir(), "/x/dev/config/icons", "icons_dir")
	eq(Paths.icon_cache_dir(), "/x/dev/cache/icons", "icon_cache_dir")
	eq(Paths.profiles_dir(), "/x/dev/profiles", "profiles_dir")
	eq(Paths.autostart_file(), "/x/dev/autostart/boscamor.desktop", "autostart_file")
	eq(Paths.runtime_dir(), "/x/dev/runtime", "runtime_dir")
	# The callers follow.
	eq(StateFile.default_path(), "/x/dev/state/state.json", "StateFile")
	eq(Autostart.default_path(), "/x/dev/autostart/boscamor.desktop", "Autostart")
	var roots := IconResolver.roots
	IconResolver.roots = {}
	eq(IconResolver.dropin_dir(), "/x/dev/config/icons", "IconResolver drop-in")
	eq(IconResolver.cache_dir(), "/x/dev/cache/icons", "IconResolver cache")
	IconResolver.roots = roots
	_restore()


func test_relative_boscamor_home_is_under_the_repo() -> void:
	_env({"BOSCAMOR_HOME": "dev-home"})
	var root := Paths.repo_root()
	check(FileAccess.file_exists(root.path_join("launcher/project.godot")), "repo root %s" % root)
	eq(Paths.dev_home(), root.path_join("dev-home"), "dev_home")
	eq(Paths.apps_json(), root.path_join("dev-home/config/apps.json"), "apps_json")
	_restore()


func test_runtime_dir_override_wins() -> void:
	_env({"BOSCAMOR_HOME": "/x/dev", "BOSCAMOR_RUNTIME_DIR": "/x/rt"})
	eq(Paths.runtime_dir(), "/x/rt", "BOSCAMOR_RUNTIME_DIR (D29)")
	_restore()


func test_profiles_follow_boscamor_home() -> void:
	var entry := '[{"id":"n","name":"N","kind":"Web","description":"d","tint":"#000000","accent":"#ffffff","argv":["firefox","--profile","/home/USER/.local/share/boscamor/profiles/netflix","{url}"]}]'
	_env({"HOME": "/home/tv"})
	eq(Apps.parse(entry).apps[0].argv[2], "/home/tv/.local/share/boscamor/profiles/netflix", "box")
	_env({"HOME": "/home/tv", "BOSCAMOR_HOME": "/x/dev"})
	eq(Apps.parse(entry).apps[0].argv[2], "/x/dev/profiles/netflix", "dev")
	_restore()


func test_seed_dev_home_copies_defaults_once() -> void:
	var dir := OS.get_cache_dir().path_join("boscamor-paths-%d" % Time.get_ticks_usec())
	_env({"HOME": "/home/tv"})
	eq(Apps.seed_dev_home(), false, "no BOSCAMOR_HOME, no seeding")
	_env({"BOSCAMOR_HOME": dir})
	eq(Apps.default_source(), Apps.DEFAULT_PATH, "bundled default before seeding")
	eq(Apps.seed_dev_home(), true, "first run seeds")
	eq(FileAccess.get_file_as_string(Paths.apps_json()), FileAccess.get_file_as_string(Apps.DEFAULT_PATH),
		"seeded from apps.default.json")
	eq(Apps.default_source(), Paths.apps_json(), "then reads the seeded copy")
	eq(Apps.seed_dev_home(), false, "second run leaves it alone")
	DirAccess.remove_absolute(Paths.apps_json())
	DirAccess.remove_absolute(Paths.config_dir())
	DirAccess.remove_absolute(dir)
	_restore()


func test_parse_ipc() -> void:
	eq(DaemonClient.parse_ipc("47800:abc123"), {"port": 47800, "token": "abc123"}, "good")
	eq(DaemonClient.parse_ipc(" 47800 : abc123 \n"), {"port": 47800, "token": "abc123"}, "spaces")
	for bad in ["", "47800", "47800:", ":abc", "x:abc", "0:abc", "70000:abc"]:
		eq(DaemonClient.parse_ipc(bad), {}, "bad %s" % bad)
