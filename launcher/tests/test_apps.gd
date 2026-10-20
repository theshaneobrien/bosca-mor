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
