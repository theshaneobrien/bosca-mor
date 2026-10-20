# Home: top bar, hero, tile carousel, hint bar. Built from apps.json.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Apps := preload("res://scripts/apps.gd")
const Glyphs := preload("res://scripts/glyphs.gd")

const DAYS := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

## Leave empty to read the user's apps.json (or the bundled default).
@export var apps_path := ""

var apps: Array = []
var focus := 0
var tiles: Array[Control] = []

var _scale := 1.0
var _date: Label
var _clock: Label
var _wifi: TextureRect
var _kind: Label
var _name: Label
var _desc: Label
var _strip: HBoxContainer
var _clock_timer: Timer


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var loaded := Apps.load_file(apps_path)
	for e in loaded.errors:
		push_warning("apps.json: " + e)
	apps = Apps.visible(loaded.apps)
	_build()
	_scale = _display_scale()
	_raster_glyphs()
	get_viewport().size_changed.connect(_on_size_changed)
	set_focus(focus)
	_tick_clock()


func set_focus(i: int) -> void:
	if apps.is_empty():
		return
	focus = clampi(i, 0, apps.size() - 1)
	for t in tiles.size():
		_style_tile(t, t == focus)
	var app: Dictionary = apps[focus]
	_kind.text = app.kind.to_upper()
	_kind.add_theme_color_override("font_color", app.accent)
	_name.text = app.name
	_desc.text = app.description
	_strip.position.x = Tokens.PAD_X - maxi(0, focus - Tokens.CAROUSEL_LEAD) * (Tokens.TILE + Tokens.TILE_GAP)


# Build -----------------------------------------------------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Tokens.BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_preset(PRESET_FULL_RECT)
	col.offset_top = Tokens.PAD_TOP
	col.offset_bottom = -Tokens.PAD_BOTTOM
	col.add_theme_constant_override("separation", 0)
	add_child(col)

	col.add_child(_build_top_bar())
	col.add_child(_build_hero())
	col.add_child(_build_row())
	col.add_child(_build_hints())


func _build_top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)

	var title := _label("Home", Tokens.mono(400, Tokens.TOPBAR_LABEL, Tokens.TRACK_LABEL), Tokens.TOPBAR_LABEL, Tokens.MUTED)
	title.text = title.text.to_upper()
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	bar.add_child(title)

	var status := HBoxContainer.new()
	status.add_theme_constant_override("separation", Tokens.TOPBAR_GAP)
	status.alignment = BoxContainer.ALIGNMENT_END
	bar.add_child(status)

	_wifi = TextureRect.new()
	_wifi.custom_minimum_size = Vector2(Tokens.STATUS_ICON, Tokens.STATUS_ICON)
	_wifi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_wifi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_wifi.size_flags_vertical = SIZE_SHRINK_CENTER
	status.add_child(_wifi)

	_date = _label("", Tokens.mono(400, Tokens.TOPBAR_DATE), Tokens.TOPBAR_DATE, Tokens.STATUS)
	_date.size_flags_vertical = SIZE_SHRINK_CENTER
	status.add_child(_date)
	_clock = _label("", Tokens.mono(500, Tokens.TOPBAR_CLOCK), Tokens.TOPBAR_CLOCK, Tokens.TEXT)
	_clock.size_flags_vertical = SIZE_SHRINK_CENTER
	status.add_child(_clock)
	return _margin(bar)


func _build_hero() -> Control:
	var hero := VBoxContainer.new()
	hero.add_theme_constant_override("separation", 0)
	hero.alignment = BoxContainer.ALIGNMENT_END
	hero.size_flags_vertical = SIZE_EXPAND_FILL

	_kind = _label("", Tokens.mono(500, Tokens.HERO_KIND, Tokens.TRACK_LABEL), Tokens.HERO_KIND, Tokens.TEXT)
	hero.add_child(_kind)

	# The hero name is set solid (line-height 1), so its label box is taller
	# than the line; take the overhang out of the gaps either side.
	var name_font := Tokens.sans(700, Tokens.HERO_NAME, Tokens.TRACK_HERO)
	var overhang := (name_font.get_height(Tokens.HERO_NAME) - Tokens.HERO_NAME) / 2.0
	hero.add_child(_spacer(Tokens.HERO_KIND_GAP - overhang))
	_name = _label("", name_font, Tokens.HERO_NAME, Tokens.TEXT)
	hero.add_child(_name)
	hero.add_child(_spacer(Tokens.HERO_DESC_GAP - overhang))
	_desc = _label("", Tokens.sans(400, Tokens.HERO_DESC), Tokens.HERO_DESC, Tokens.MUTED)
	hero.add_child(_desc)

	var m := _margin(hero)
	m.size_flags_vertical = SIZE_EXPAND_FILL
	return m


func _build_row() -> Control:
	var row := Control.new()
	row.custom_minimum_size.y = Tokens.ROW_HEIGHT
	row.clip_contents = true

	_strip = HBoxContainer.new()
	_strip.add_theme_constant_override("separation", Tokens.TILE_GAP)
	_strip.position = Vector2(Tokens.PAD_X, Tokens.ROW_TOP)
	row.add_child(_strip)

	for app in apps:
		_strip.add_child(_build_tile(app))
	return row


func _build_tile(app: Dictionary) -> Control:
	var cell := VBoxContainer.new()
	cell.custom_minimum_size.x = Tokens.TILE
	cell.add_theme_constant_override("separation", Tokens.TILE_LABEL_GAP)

	# Containers reset scale, so the tile scales inside a plain holder.
	var holder := Control.new()
	holder.name = "Holder"
	holder.custom_minimum_size = Vector2(Tokens.TILE, Tokens.TILE)
	cell.add_child(holder)

	var tile := Panel.new()
	tile.name = "Tile"
	tile.size = Vector2(Tokens.TILE, Tokens.TILE)
	tile.pivot_offset = Vector2(Tokens.TILE / 2.0, Tokens.TILE)
	tile.add_theme_stylebox_override("panel", _box(app.tint, Tokens.TILE_RADIUS))
	holder.add_child(tile)

	var gap := Tokens.RING_GAP
	var outer := Tokens.RING_GAP + Tokens.RING_WIDTH
	tile.add_child(_ring("Gap", gap, Tokens.BG, gap))
	tile.add_child(_ring("Ring", outer, Tokens.RING, Tokens.RING_WIDTH))

	var glyph := TextureRect.new()
	glyph.name = "Glyph"
	glyph.size = Vector2(Tokens.GLYPH, Tokens.GLYPH)
	glyph.position = Vector2(Tokens.TILE - Tokens.GLYPH, Tokens.TILE - Tokens.GLYPH) / 2.0
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_SCALE
	tile.add_child(glyph)

	var label := _label(app.name, Tokens.sans(500, Tokens.TILE_LABEL), Tokens.TILE_LABEL, Tokens.DIM)
	label.name = "Label"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cell.add_child(label)

	tiles.append(cell)
	return cell


func _ring(node_name: String, inset: int, color: Color, width: int) -> Panel:
	var p := Panel.new()
	p.name = node_name
	p.position = Vector2(-inset, -inset)
	p.size = Vector2(Tokens.TILE + inset * 2, Tokens.TILE + inset * 2)
	var sb := _box(color, Tokens.TILE_RADIUS + inset)
	sb.draw_center = false
	sb.set_border_width_all(width)
	sb.border_color = color
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = MOUSE_FILTER_IGNORE
	return p


func _build_hints() -> Control:
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", Tokens.HINT_GAP)
	bar.add_child(_hint("A", "Open"))
	bar.add_child(_hint("B", "Menu"))
	return _margin(bar)


func _hint(key: String, text: String) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Tokens.HINT_KEY_GAP)
	var pill := PanelContainer.new()
	pill.custom_minimum_size = Vector2(Tokens.KEY, Tokens.KEY)
	pill.add_theme_stylebox_override("panel", _box(Tokens.KEY_BG, Tokens.KEY / 2))
	var k := _label(key, Tokens.mono(500, Tokens.KEY_FONT), Tokens.KEY_FONT, Tokens.TEXT)
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pill.add_child(k)
	h.add_child(pill)
	var t := _label(text, Tokens.sans(400, Tokens.HINT), Tokens.HINT, Tokens.MUTED)
	t.size_flags_vertical = SIZE_SHRINK_CENTER
	h.add_child(t)
	return h


# Helpers ---------------------------------------------------------------------

func _label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _box(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	return sb


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = maxf(h, 0.0)
	return c


func _margin(c: Control) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", Tokens.PAD_X)
	m.add_theme_constant_override("margin_right", Tokens.PAD_X)
	m.add_child(c)
	return m


func _style_tile(i: int, on: bool) -> void:
	var cell := tiles[i]
	var tile: Control = cell.get_node("Holder/Tile")
	tile.scale = Vector2.ONE * (Tokens.TILE_FOCUS_SCALE if on else 1.0)
	tile.get_node("Gap").visible = on
	tile.get_node("Ring").visible = on
	var label: Label = cell.get_node("Label")
	label.add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.TILE_LABEL))
	label.add_theme_color_override("font_color", Tokens.TEXT if on else Tokens.DIM)


# Glyphs are rasterised for the focused size at the current display scale.
func _raster_glyphs() -> void:
	var s := _scale * Tokens.TILE_FOCUS_SCALE
	for i in tiles.size():
		var app: Dictionary = apps[i]
		var tr: TextureRect = tiles[i].get_node("Holder/Tile/Glyph")
		tr.texture = Glyphs.texture(Glyphs.name_for(app), app.accent, Tokens.GLYPH, Tokens.GLYPH_STROKE, s)
	_wifi.texture = Glyphs.texture("wifi", Tokens.STATUS, Tokens.STATUS_ICON, Tokens.STATUS_STROKE, _scale)


func _display_scale() -> float:
	var s := get_viewport().get_final_transform().get_scale().y
	return s if s > 0.0 else 1.0


func _on_size_changed() -> void:
	var s := _display_scale()
	if not is_equal_approx(s, _scale):
		_scale = s
		_raster_glyphs()


func _tick_clock() -> void:
	var t := Time.get_datetime_dict_from_system()
	_date.text = "%s %d %s" % [DAYS[t.weekday], t.day, MONTHS[t.month - 1]]
	_clock.text = "%02d:%02d" % [t.hour, t.minute]
	if _clock_timer == null:
		_clock_timer = Timer.new()
		_clock_timer.one_shot = true
		_clock_timer.timeout.connect(_tick_clock)
		add_child(_clock_timer)
	_clock_timer.start(60 - t.second)
