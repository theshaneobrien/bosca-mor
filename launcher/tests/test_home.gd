extends "res://tests/test_case.gd"

const HomeScene := preload("res://scenes/home.tscn")
const Apps := preload("res://scripts/apps.gd")
const Tokens := preload("res://theme/tokens.gd")
const Sidebar := preload("res://scripts/sidebar.gd")
const UI := preload("res://scripts/ui.gd")
const Glyphs := preload("res://scripts/glyphs.gd")


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


# Review: with every app hidden, the hero kept the last app's name and
# play_return (Desktop, then Home) read tiles[0].
func test_empty_home_clears_the_hero_and_returns() -> void:
	var h := _home()
	h.apps_path = "res://tests/fixtures/nope.json"
	h.reload()
	eq(h.tiles.size(), 0, "no tiles")
	for p in h._pages:
		eq(p.get_node("Name").text, "", "hero name cleared")
		eq(p.get_node("Kind").text, "", "hero kind cleared")
	h.play_return()
	check(h._fade.visible, "the return fade still runs")
	h.free()


# Review: the row clipped the launch zoom flat at its top edge.
func test_launch_zoom_is_not_clipped() -> void:
	var h := _home()
	await tree.process_frame
	await tree.process_frame
	var clip: Control = h._strip.get_parent()
	var row: Control = clip.get_parent()
	eq(h._strip.global_position.y, row.global_position.y + Tokens.ROW_TOP, "tiles sit where they did")
	var tile: Control = h._tile(h.focus)
	tile.scale = Vector2.ONE * Tokens.LAUNCH_SCALE
	var ring: Rect2 = tile.get_node("Focus/Ring").get_global_rect()
	check(clip.clip_contents, "the row still clips sideways")
	check(clip.get_global_rect().position.y <= ring.position.y,
		"zoomed ring top %s inside the clip from %s" % [ring.position.y, clip.get_global_rect().position.y])
	h.free()


# Main scales its whole UI round the centre for Screen size (D33); the
# sidebar is its child.
func _scaled_sidebar(s: float) -> Control:
	var ui := Control.new()
	ui.size = Tokens.BASE_SIZE
	ui.pivot_offset = Vector2(Tokens.BASE_SIZE) / 2.0
	ui.scale = Vector2.ONE * s
	var h := Control.new()
	ui.add_child(h)
	ui.add_child(Sidebar.new(h))
	tree.root.add_child(ui)
	return ui


# Review: at 90% the panel spans x 96 to 600, but a click past x 560 counted
# as the dim and closed it.
func test_sidebar_hit_tests_follow_screen_size() -> void:
	var ui := _scaled_sidebar(0.9)
	var sb = ui.get_child(1)
	sb.open(false)
	await tree.process_frame
	var y: float = sb._items[0].get_global_rect().get_center().y
	eq(sb.item_at(Vector2(590, y)), -1, "beside the item")
	eq(sb.is_on_dim(Vector2(590, y)), false, "the panel's right edge is not the dim")
	check(sb.is_on_dim(Vector2(700, y)), "right of the panel is the dim")
	eq(sb.item_at(sb._items[0].get_global_rect().get_center()), 0, "items still hit")
	ui.free()


# Review: the blur took the whole screen, already scaled, and Main scaled it again.
func test_sidebar_blur_covers_only_the_scaled_ui() -> void:
	var ui := _scaled_sidebar(0.9)
	var sb = ui.get_child(1)
	# The picture is the window's; the stretch maps the 1920x1080 canvas into it.
	var img: Vector2i = tree.root.size
	var on_screen := func(r: Rect2) -> Rect2i:
		var q := (tree.root.get_final_transform() * r).abs()
		return Rect2i(Vector2i(q.position.round()), Vector2i(q.size.round())).intersection(Rect2i(Vector2i.ZERO, img))
	var base := Vector2(Tokens.BASE_SIZE)
	eq(sb.capture_rect(img), on_screen.call(Rect2(base * 0.05, base * 0.9)), "only Main's 90% frame")
	ui.scale = Vector2.ONE
	eq(sb.capture_rect(img), on_screen.call(Rect2(Vector2.ZERO, base)), "at 100% the whole canvas")
	ui.free()


# Review: the sidebar drew its glyphs at the start-up scale for good.
func test_sidebar_glyphs_follow_display_scale() -> void:
	var ui := _scaled_sidebar(1.0)
	var sb = ui.get_child(1)
	sb._scale = 0.5                     # as if it had started on a smaller TV mode
	sb.set_focus(0)
	tree.root.size_changed.emit()
	eq(sb._scale, UI.display_scale(sb), "scale read again")
	var icon: TextureRect = sb._items[0].get_node("Row/Icon")
	var want := Glyphs.texture("home", Tokens.TEXT, Tokens.MENU_ICON, Tokens.STATUS_STROKE, sb._scale)
	eq(icon.texture.get_size(), want.get_size(), "glyphs drawn again at the new scale")
	ui.free()
