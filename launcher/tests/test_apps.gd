extends "res://tests/test_case.gd"

const Apps := preload("res://scripts/apps.gd")
const DEFAULT_IDS := ["youtube", "plex", "jellyfin", "netflix", "prime", "browser",
	"spotify", "alarismusic", "moonlight", "retroarch"]


func test_default_loads_ten_in_order() -> void:
	var r := Apps.load_file(Apps.DEFAULT_PATH)
	eq(r.errors.size(), 0, "errors")
	eq(r.apps.map(func(a): return a.id), DEFAULT_IDS, "ids in order")


func test_bundled_default_matches_install_copy() -> void:
	var install := ProjectSettings.globalize_path("res://").path_join("../install/files/apps.default.json")
	if not FileAccess.file_exists(install):
		return
	eq(FileAccess.get_file_as_string(Apps.DEFAULT_PATH), FileAccess.get_file_as_string(install),
		"launcher/data/apps.default.json matches install/files")


func test_missing_optional_fields() -> void:
	var r := Apps.load_file("res://tests/fixtures/apps_minimal.json")
	eq(r.errors.size(), 0, "errors")
	eq(r.apps.size(), 1, "count")
	var a: Dictionary = r.apps[0]
	eq(a.icon, "", "icon default")
	eq(a.url, "", "url default")
	eq(a.keep_on_home, false, "keep_on_home default")
	eq(a.hidden, false, "hidden default")
	eq(a.icon_style, "inset", "icon_style default")


func test_bad_entries_skipped() -> void:
	var r := Apps.load_file("res://tests/fixtures/apps_bad.json")
	eq(r.apps.map(func(a): return a.id), ["ok", "ok2"], "only good entries kept")
	eq(r.errors.size(), 4, "one error per bad entry")


func test_bad_file_gives_empty_list() -> void:
	eq(Apps.parse("{not json").apps.size(), 0, "garbage")
	eq(Apps.parse("{}").apps.size(), 0, "object instead of array")
	eq(Apps.load_file("res://tests/fixtures/nope.json").apps.size(), 0, "missing file")


# A file that is there but won't load is "broken": Settings must not save
# over it (that would keep only what it holds, which is nothing).
func test_a_broken_file_is_flagged() -> void:
	var text := FileAccess.get_file_as_string(Apps.DEFAULT_PATH)
	var at := text.find("},\n")
	var r := Apps.parse(text.left(at + 1) + text.substr(at + 2))    # one comma gone
	check(r.broken, "a missing comma")
	check(r.errors[0].begins_with("apps.json line "), "names the line: %s" % [r.errors])
	check(Apps.parse("{not json").broken, "garbage")
	check(Apps.parse("{}").broken, "not a list")
	check(not Apps.load_file(Apps.DEFAULT_PATH).broken, "the default is fine")
	check(not Apps.load_file("res://tests/fixtures/apps_bad.json").broken, "bad entries alone keep the rest")
	check(not Apps.load_file("res://tests/fixtures/nope.json").broken, "no file is not a broken one")


# A full disk fails inside close(), which Godot doesn't report: the temp
# file is checked before it replaces the real one.
func test_write_atomic_replaces_only_with_a_whole_file() -> void:
	var path := ProjectSettings.globalize_path("user://test-atomic-%d.json" % Time.get_ticks_usec())
	var tmp := path + ".tmp"
	eq(Apps.write_atomic(path, "café\n"), OK, "written")
	eq(FileAccess.get_file_as_string(path), "café\n", "whole")
	check(not FileAccess.file_exists(tmp), "no temp file left")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("caf")
	f.close()
	check(not Apps._landed(tmp, "café\n"), "a short temp file is caught")
	check(Apps._landed(tmp, "caf"), "a whole one passes")
	DirAccess.remove_absolute(tmp)
	DirAccess.make_dir_absolute(tmp)          # the temp file can't be written at all
	check(Apps.write_atomic(path, "new") != OK, "fails")
	eq(FileAccess.get_file_as_string(path), "café\n", "the old file kept")
	DirAccess.remove_absolute(tmp)
	DirAccess.remove_absolute(path)


func test_user_expanded() -> void:
	var r := Apps.parse('[{"id":"x","name":"X","kind":"Web","description":"d","tint":"#000000","accent":"#ffffff","argv":["firefox","--profile","/home/USER/p","{url}"]}]')
	var argv: Array = r.apps[0].argv
	check(not argv[2].contains("/home/USER"), "USER expanded: %s" % argv[2])
	eq(argv[3], "{url}", "{url} left for launch time")


func test_hidden_filtered() -> void:
	var r := Apps.parse('[{"id":"a","name":"A","kind":"Web","description":"d","tint":"#000000","accent":"#ffffff","argv":["a"],"hidden":true},{"id":"b","name":"B","kind":"Web","description":"d","tint":"#000000","accent":"#ffffff","argv":["b"]}]')
	eq(Apps.visible(r.apps).map(func(a): return a.id), ["b"], "visible")


func test_url_filled_into_argv() -> void:
	var r := Apps.load_file(Apps.DEFAULT_PATH)
	var browser: Dictionary = r.apps.filter(func(a): return a.id == "browser")[0]
	var argv := Apps.argv_for(browser)
	eq(argv[argv.size() - 1], "https://www.google.com", "{url} replaced")
	eq(argv[0], "firefox", "rest kept")
	var plex: Dictionary = r.apps.filter(func(a): return a.id == "plex")[0]
	eq(Apps.argv_for(plex), ["flatpak", "run", "tv.plex.PlexHTPC"], "no url")


# Step 10: Jellyfin opens the flatpak's TV fullscreen mode.
func test_jellyfin_tv_fullscreen() -> void:
	var r := Apps.load_file(Apps.DEFAULT_PATH)
	var jf: Dictionary = r.apps.filter(func(a): return a.id == "jellyfin")[0]
	eq(Apps.argv_for(jf), ["flatpak", "run", "org.jellyfin.JellyfinDesktop", "--fullscreen", "--tv"], "TV fullscreen")
	for a in r.apps:
		for arg in a.argv:
			check(not arg.begins_with("["), "%s: no placeholder left: %s" % [a.id, arg])
