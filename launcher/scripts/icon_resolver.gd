# Finds each app's icon (SPEC Icons), first that exists:
#   1. the `icon` path in apps.json
#   2. a drop-in, <id>.svg or .png in Paths.icons_dir()
#   3. the icon the app installed: a flatpak's hicolor export (scalable SVG,
#      then the largest PNG), or the theme icon named in a native app's
#      .desktop file. Not for web tiles (a `url`): Netflix runs Firefox, but
#      Firefox's logo isn't Netflix's (D41)
#   4. none: the caller draws the built-in line glyph
# SVGs are rasterised at the size they are drawn and cached under
# Paths.icon_cache_dir(), redone when the file or the size changes. A PNG
# bigger than the drawn size is scaled down to it.
extends RefCounted

const Paths := preload("res://scripts/paths.gd")
const DesktopEntries := preload("res://scripts/desktop_entries.gd")

## Where each search looks. Tests point these at temp folders.
static var roots := {}
static var _entries = null          # .desktop scan, read once


static func reset() -> void:
	roots = {}
	_entries = null


## Forget the .desktop scan (it is read once per run).
static func reset_entries() -> void:
	_entries = null


static func dropin_dir() -> String:
	return roots.get("dropin", Paths.icons_dir())


static func cache_dir() -> String:
	return roots.get("cache", Paths.icon_cache_dir())


static func flatpak_dirs() -> Array:
	return roots.get("flatpak", Paths.flatpak_icon_dirs())


static func theme_dirs() -> Array:
	return roots.get("themes", Paths.theme_icon_dirs())


static func pixmap_dirs() -> Array:
	return roots.get("pixmaps", Paths.pixmap_dirs())


## The icon file for an app: {"path", "source"}, source being "apps.json",
## "drop-in" or "installed". {} when the glyph should be drawn.
static func find(app: Dictionary) -> Dictionary:
	var icon: String = app.get("icon", "")
	if icon and FileAccess.file_exists(icon):
		return {"path": icon, "source": "apps.json"}
	for ext in ["svg", "png"]:
		var p := dropin_dir().path_join("%s.%s" % [app.id, ext])
		if FileAccess.file_exists(p):
			return {"path": p, "source": "drop-in"}
	var installed := "" if app.get("url", "") else _installed(app)
	if installed:
		return {"path": installed, "source": "installed"}
	return {}


static func _installed(app: Dictionary) -> String:
	var argv: Array = app.get("argv", [])
	var fp := flatpak_id(argv)
	if fp:
		for d in flatpak_dirs():
			var p := _in_hicolor(d, fp)
			if p:
				return p
		return ""
	if argv.is_empty():
		return ""
	var exe: String = argv[0].get_file()
	for e in _desktop_entries():
		if e.file.trim_suffix(".desktop") == app.id or (e.argv and e.argv[0].get_file() == exe):
			return theme_icon(e.icon)
	return ""


## The app id in `flatpak run [options] <id> ...`, or "".
static func flatpak_id(argv: Array) -> String:
	if argv.size() < 3 or argv[0].get_file() != "flatpak" or argv[1] != "run":
		return ""
	for a in argv.slice(2):
		if not a.begins_with("-"):
			return a
	return ""


## A theme icon by name (or an absolute path) as a file, or "".
static func theme_icon(name: String) -> String:
	if name.is_empty():
		return ""
	if name.is_absolute_path():
		return name if FileAccess.file_exists(name) else ""
	for d in theme_dirs():
		var p := _in_hicolor(d, name)
		if p:
			return p
	for d in pixmap_dirs():
		for ext in ["svg", "png"]:
			var p: String = d.path_join("%s.%s" % [name, ext])
			if FileAccess.file_exists(p):
				return p
	return ""


# scalable/apps/<name>.svg first, then the largest <N>x<N>/apps/<name>.png.
static func _in_hicolor(base: String, name: String) -> String:
	var svg := base.path_join("scalable/apps/%s.svg" % name)
	if FileAccess.file_exists(svg):
		return svg
	var best := ""
	var best_n := 0
	if not DirAccess.dir_exists_absolute(base):
		return ""
	for d in DirAccess.get_directories_at(base):
		var n := d.get_slice("x", 0).to_int()
		var p := base.path_join("%s/apps/%s.png" % [d, name])
		if n > best_n and d == "%dx%d" % [n, n] and FileAccess.file_exists(p):
			best = p
			best_n = n
	return best


static func _desktop_entries() -> Array:
	if _entries == null:
		_entries = DesktopEntries.scan(roots.get("desktop", []))
	return _entries


## The icon as a texture about `px` device pixels across: its long side, or
## its short side when `cover` (full style fills the tile, so the short side
## is the one drawn at px). SVGs go through the cache; a PNG bigger than that
## is scaled down to it, with mipmaps for drawing smaller. Each caller that
## draws at its own size needs its own cache_key.
static func texture(path: String, px: int, cache_key: String, cover := false) -> Texture2D:
	if path.get_extension().to_lower() == "svg":
		return _svg(path, px, cache_key, cover)
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	_shrink(img, px, cover)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _side(img: Image, cover: bool) -> int:
	return mini(img.get_width(), img.get_height()) if cover else maxi(img.get_width(), img.get_height())


# A 4000 px press-kit logo would hold 85 MB with mipmaps, so cut it down to
# the drawn size. Halving first is cheap; Lanczos straight from 4000 px is
# slow. Never scales up. shrink_x2 leaves an image it can't halve as it is
# (1 px thin, or a compressed format, which can't be resized either), so the
# halving stops there or it would never end; the resize does the rest.
static func _shrink(img: Image, px: int, cover: bool) -> void:
	var side := _side(img, cover)
	if px <= 0 or side <= px or img.is_compressed():
		return
	while side >= 2 * px and mini(img.get_width(), img.get_height()) >= 2:
		img.shrink_x2()
		side = _side(img, cover)
	var k := float(px) / side
	img.resize(maxi(1, roundi(img.get_width() * k)), maxi(1, roundi(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)


static func _svg(path: String, px: int, cache_key: String, cover := false) -> Texture2D:
	cache_key = cache_key.validate_filename()   # still_open's key can hold a whole path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var stamp := "%s|%d|%d|%d" % [path, FileAccess.get_modified_time(path), f.get_length(), px]
	if cover:
		stamp += "|cover"
	f.close()
	var cached := cache_dir().path_join("%s-%s.png" % [cache_key, stamp.md5_text().left(12)])
	if FileAccess.file_exists(cached):
		var hit := Image.load_from_file(cached)
		if hit and not hit.is_empty():
			return ImageTexture.create_from_image(hit)
	var buf := FileAccess.get_file_as_bytes(path)
	var probe := Image.new()
	if buf.is_empty() or probe.load_svg_from_buffer(buf, 1.0) != OK:
		return null
	var w := float(probe.get_width())
	var h := float(probe.get_height())
	var scale := float(px) / (minf(w, h) if cover else maxf(w, h))
	var img := Image.new()
	if img.load_svg_from_buffer(buf, scale) != OK:
		return null
	img.generate_mipmaps()
	DirAccess.make_dir_recursive_absolute(cache_dir())
	# An older size or version of this key only, named like this one. A bare
	# prefix would also match "<key>-row-..." or a longer id such as "plex-htpc".
	for old in DirAccess.get_files_at(cache_dir()):
		if old.begins_with(cache_key + "-") and old.length() == cached.get_file().length():
			DirAccess.remove_absolute(cache_dir().path_join(old))
	img.save_png(cached)
	return ImageTexture.create_from_image(img)


## Plain words for Settings > Apps.
static func source_label(source: String) -> String:
	match source:
		"apps.json": return "Icon from apps.json"
		"drop-in": return "Drop-in icon"
		"installed": return "App's own icon"
	return "Built-in icon"
