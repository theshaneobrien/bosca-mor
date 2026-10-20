extends "res://tests/test_case.gd"

const IconResolver := preload("res://scripts/icon_resolver.gd")
const HomeScene := preload("res://scenes/home.tscn")
const Apps := preload("res://scripts/apps.gd")
const Tokens := preload("res://theme/tokens.gd")

const SVG := '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><rect width="48" height="48" fill="#e50914"/></svg>'

var root: String


# Each fallback level gets its own temp folder.
func _setup() -> void:
	root = ProjectSettings.globalize_path("user://test-icons-%d" % Time.get_ticks_usec())
	for d in ["dropin", "flatpak", "theme", "pixmaps", "desktop", "cache", "own"]:
		DirAccess.make_dir_recursive_absolute(root.path_join(d))
	IconResolver.reset()
	IconResolver.roots = {
		"dropin": root.path_join("dropin"),
		"flatpak": [root.path_join("flatpak")],
		"themes": [root.path_join("theme")],
		"pixmaps": [root.path_join("pixmaps")],
		"desktop": [root.path_join("desktop")],
		"cache": root.path_join("cache"),
	}


func _teardown() -> void:
	IconResolver.reset()
	_rm(root)


func _rm(path: String) -> void:
	for d in DirAccess.get_directories_at(path):
		_rm(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> String:
	path = root.path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func _png(path: String, px: int) -> String:
	path = root.path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	Image.create(px, px, false, Image.FORMAT_RGBA8).save_png(path)
	return path


func _app(id: String, argv: Array, extra := {}) -> Dictionary:
	var a := {"id": id, "argv": argv, "icon": "", "url": "", "icon_style": "inset"}
	a.merge(extra, true)
	return a


func test_order_of_lookup() -> void:
	_setup()
	var plex := _app("plex", ["flatpak", "run", "--branch=stable", "tv.plex.PlexHTPC"])
	eq(IconResolver.find(plex), {}, "4. nothing found: the glyph")

	_png("flatpak/64x64/apps/tv.plex.PlexHTPC.png", 64)
	var big := _png("flatpak/512x512/apps/tv.plex.PlexHTPC.png", 512)
	_png("flatpak/256x256/apps/tv.plex.PlexHTPC.png", 256)
	eq(IconResolver.find(plex), {"path": big, "source": "installed"}, "3. flatpak: the largest PNG")
	var scalable := _write("flatpak/scalable/apps/tv.plex.PlexHTPC.svg", SVG)
	eq(IconResolver.find(plex), {"path": scalable, "source": "installed"}, "3. flatpak: scalable SVG first")

	var drop_png := _png("dropin/plex.png", 600)
	eq(IconResolver.find(plex), {"path": drop_png, "source": "drop-in"}, "2. drop-in PNG")
	var drop_svg := _write("dropin/plex.svg", SVG)
	eq(IconResolver.find(plex), {"path": drop_svg, "source": "drop-in"}, "2. drop-in SVG before PNG")

	var own := _png("own/plex-logo.png", 600)
	plex.icon = own
	eq(IconResolver.find(plex), {"path": own, "source": "apps.json"}, "1. the icon path in apps.json")
	plex.icon = root.path_join("own/missing.png")
	eq(IconResolver.find(plex).source, "drop-in", "a missing icon path falls through")
	_teardown()


func test_native_app_theme_icon() -> void:
	_setup()
	_write("desktop/kodi.desktop", "[Desktop Entry]\nType=Application\nName=Kodi\nExec=/usr/bin/kodi --standalone %U\nIcon=kodi\n")
	var kodi := _app("tv", ["kodi"])
	eq(IconResolver.find(kodi), {}, "no theme icon yet")
	var png := _png("theme/256x256/apps/kodi.png", 256)
	eq(IconResolver.find(kodi), {"path": png, "source": "installed"}, "theme icon from the .desktop file")
	var pix := _write("pixmaps/spotify.png", "x")
	_write("desktop/spotify.desktop", "[Desktop Entry]\nType=Application\nName=Spotify\nExec=spotify %U\nIcon=spotify\n")
	IconResolver.reset_entries()
	eq(IconResolver.find(_app("spotify", ["spotify"])).get("path"), pix, "pixmaps last")
	_teardown()


func test_web_tiles_skip_the_browser_icon() -> void:
	_setup()
	_write("desktop/firefox.desktop", "[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\nIcon=firefox\n")
	_write("theme/scalable/apps/firefox.svg", SVG)
	var netflix := _app("netflix", ["firefox", "--kiosk", "{url}"], {"url": "https://www.netflix.com"})
	eq(IconResolver.find(netflix), {}, "Netflix does not get the Firefox logo")
	var drop := _write("dropin/netflix.svg", SVG)
	eq(IconResolver.find(netflix).get("path"), drop, "a drop-in still works")
	_teardown()


func test_svg_cache() -> void:
	_setup()
	var svg := _write("dropin/plex.svg", SVG)
	var tex := IconResolver.texture(svg, 291, "plex")
	eq(tex.get_width(), 291, "rasterised at the drawn size")
	var cached := DirAccess.get_files_at(root.path_join("cache"))
	eq(cached.size(), 1, "one cache file")
	check(cached[0].begins_with("plex-") and cached[0].ends_with(".png"), "named by id: %s" % [cached])
	eq(IconResolver.texture(svg, 291, "plex").get_width(), 291, "second load")
	eq(DirAccess.get_files_at(root.path_join("cache")), cached, "served from the cache")
	IconResolver.texture(svg, 582, "plex")
	var at_4k := DirAccess.get_files_at(root.path_join("cache"))
	eq(at_4k.size(), 1, "a new scale replaces the old file")
	check(at_4k != cached, "redone for the new scale")
	_write("dropin/plex.svg", SVG.replace("<rect", "<rect rx=\"4\""))
	IconResolver.texture(svg, 582, "plex")
	check(DirAccess.get_files_at(root.path_join("cache")) != at_4k, "redone when the file changes")
	_teardown()


func test_png_keeps_its_size() -> void:
	_setup()
	var png := _png("dropin/plex.png", 600)
	var tex := IconResolver.texture(png, 291, "plex")
	eq(tex.get_width(), 600, "PNG loaded as supplied, mipmapped down")
	check(tex.get_image().has_mipmaps(), "mipmaps")
	_teardown()


func test_home_draws_inset_and_full() -> void:
	_setup()
	_write("dropin/youtube.svg", SVG)
	_png("dropin/plex.png", 600)
	var dir := root.path_join("apps")
	DirAccess.make_dir_recursive_absolute(dir)
	var entries: Array = JSON.parse_string(FileAccess.get_file_as_string(Apps.DEFAULT_PATH))
	entries[1]["icon_style"] = "full"
	Apps.save_file(dir.path_join("apps.json"), entries)
	var h: Control = HomeScene.instantiate()
	h.apps_path = dir.path_join("apps.json")
	tree.root.add_child(h)
	var yt: Control = h._tile(0)
	check(yt.get_node("Icon").visible and not yt.get_node("Glyph").visible, "inset logo instead of the glyph")
	eq(yt.get_node("Icon").size, Vector2.ONE * Tokens.TILE * Tokens.ICON_INSET, "60% of the tile")
	eq((yt.get_theme_stylebox("panel") as StyleBoxFlat).bg_color, h.apps[0].tint, "inset keeps the tint")
	var plex: Control = h._tile(1)
	check(plex.get_node("Clip").visible and not plex.get_node("Icon").visible, "full fills the tile")
	eq(plex.get_node("Clip").clip_children, CanvasItem.CLIP_CHILDREN_ONLY, "clipped to the rounded tile")
	eq((plex.get_theme_stylebox("panel") as StyleBoxFlat).bg_color.a, 0.0, "full ignores the tint")
	check(h._tile(2).get_node("Glyph").visible, "no icon: the glyph")
	h.free()
	_teardown()
