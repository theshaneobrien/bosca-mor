extends "res://tests/test_case.gd"

const HomeScene := preload("res://scenes/home.tscn")
const Apps := preload("res://scripts/apps.gd")


func _home() -> Control:
	var h: Control = HomeScene.instantiate()
	h.apps_path = Apps.DEFAULT_PATH
	h.state_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(h)
	return h


func test_ten_tiles_in_order() -> void:
	var h := _home()
	eq(h.tiles.size(), 10, "tiles")
	var labels = h.tiles.map(func(t): return t.get_node("Label").text)
	eq(labels, ["YouTube", "Plex", "Jellyfin", "Netflix", "Prime Video", "Browser",
		"Spotify", "Alaris Music", "Moonlight", "RetroArch"], "labels in order")
	h.free()


func test_hero_follows_focus() -> void:
	var h := _home()
	h.set_focus(7)
	eq(h._name.text, "Alaris Music", "hero name")
	eq(h._kind.text, "MUSIC", "hero kind")
	h.set_focus(99)
	eq(h.focus, 9, "focus clamps")
	h.free()


func test_glyphs_rasterise() -> void:
	var h := _home()
	for t in h.tiles:
		check(t.get_node("Holder/Tile/Glyph").texture != null, "glyph for %s" % t.get_node("Label").text)
	h.free()


func test_empty_config_does_not_crash() -> void:
	var h: Control = HomeScene.instantiate()
	h.apps_path = "res://tests/fixtures/nope.json"
	tree.root.add_child(h)
	eq(h.tiles.size(), 0, "no tiles")
	h.free()


func test_hero_pages_fill_hero_area() -> void:
	var h := _home()
	await tree.process_frame
	await tree.process_frame
	for p in h._pages:
		eq(p.get_rect(), Rect2(Vector2.ZERO, p.get_parent().size), "hero page rect")
	check(h._pages[0].get_parent().size.y > 300, "hero area has height: %s" % h._pages[0].get_parent().size)
	h.free()
