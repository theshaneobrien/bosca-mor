# Home: top bar, hero, tile carousel, hint bar. Built from apps.json.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Apps := preload("res://scripts/apps.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const InputModeScript := preload("res://scripts/input_mode.gd")
const Motion := preload("res://scripts/motion.gd")
const StateFile := preload("res://scripts/state_file.gd")
const HintBar := preload("res://scripts/hint_bar.gd")
const UI := preload("res://scripts/ui.gd")
const Wifi := preload("res://scripts/wifi.gd")

const DAYS := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

## The user picked an app. Launching itself comes with the daemon (step 5).
signal launch_requested(app: Dictionary)
## The launch zoom and fade to black finished; the window can hide.
signal launch_faded

## Leave empty to read the user's apps.json (or the bundled default).
@export var apps_path := ""
## Leave empty to read the user's state.json.
@export var state_path := ""

## Main turns this off while another screen is on top.
var accepting_input := true
var apps: Array = []
var focus := 0
var tiles: Array[Control] = []

var _scale := 1.0
var _date: Label
var _clock: Label
var _wifi: TextureRect
var _kind: Label                    # labels of the hero page showing now
var _name: Label
var _desc: Label
var _pages: Array[VBoxContainer] = []
var _page := 0
var _accent := Color()
var _strip: HBoxContainer
var _strip_x := 0.0                 # where the carousel is heading
var _tile_on: Array[bool] = []
var _fade: ColorRect
var _launching := false
var _clock_timer: Timer
var _wifi_timer: Timer
var _wifi_state := "unknown"
## Tests point this at a fixture; empty reads /proc/net/wireless.
var wifi_path := ""
var _hints: HBoxContainer
var _hover := -1                    # tile under the pointer, waiting out the dwell
var _hover_since := 0
var _dwell_timer: Timer


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var loaded := Apps.load_file(apps_path)
	for e in loaded.errors:
		push_warning("apps.json: " + e)
	apps = Apps.visible(loaded.apps)
	Motion.reduce = bool(StateFile.load_file(state_path).get("reduce_motion", false))
	_build()
	UI.ignore_mouse(self)
	_dwell_timer = Timer.new()
	_dwell_timer.one_shot = true
	_dwell_timer.timeout.connect(resolve_dwell)
	add_child(_dwell_timer)
	var im := _input_mode()
	if im:
		im.mode_changed.connect(func(_m): _hover = -1)
	_scale = _display_scale()
	_raster_glyphs()
	get_viewport().size_changed.connect(_on_size_changed)
	set_focus(focus, false)
	_tick_clock()
	_wifi_timer = Timer.new()
	_wifi_timer.wait_time = Tokens.WIFI_POLL
	_wifi_timer.timeout.connect(poll_wifi)
	add_child(_wifi_timer)
	_wifi_timer.start()
	poll_wifi()


## Back from hidden: the clock and Wi-Fi timers were paused, so read both now.
func refresh() -> void:
	_tick_clock()
	poll_wifi()
	_wifi_timer.start()


func poll_wifi() -> void:
	set_wifi(Wifi.state(wifi_path if wifi_path else Wifi.PATH))


## "on" and "unknown" (not Linux) show the icon, "off" shows it struck
## through, "none" (a wired box) hides it.
func set_wifi(state: String) -> void:
	if state == _wifi_state and _wifi.texture != null:
		return
	_wifi_state = state
	_wifi.visible = state != "none"
	if state == "off":
		_wifi.texture = Glyphs.texture("wifi-off", Tokens.MUTED, Tokens.STATUS_ICON, Tokens.STATUS_STROKE, _scale)
	else:
		_wifi.texture = Glyphs.texture("wifi", Tokens.STATUS, Tokens.STATUS_ICON, Tokens.STATUS_STROKE, _scale)


func wifi_state() -> String:
	return _wifi_state


func _unhandled_input(ev: InputEvent) -> void:
	if _launching or not accepting_input:
		return
	if ev is InputEventMouseMotion:
		_on_pointer_move(ev.position)
		return
	if ev.is_action_pressed("nav_left", true):
		move(-1)
	elif ev.is_action_pressed("nav_right", true):
		move(1)
	elif ev.is_action_pressed("accept"):
		if ev is InputEventMouseButton:
			var i := tile_at(ev.position)
			if i < 0:
				return
			set_focus(i)
		launch()
	else:
		return
	get_viewport().set_input_as_handled()


## Moves focus by one tile; at the ends the row nudges and stays.
func move(step: int) -> void:
	var to := focus + step
	if to < 0 or to >= apps.size():
		Motion.bump(_strip, "position:x", _strip_x, step * Tokens.BUMP)
		return
	set_focus(to)


## Zooms the focused tile while the screen fades to black.
func launch() -> void:
	if apps.is_empty() or _launching:
		return
	_launching = true
	_hover = -1
	launch_requested.emit(apps[focus])
	Motion.to(_tile(focus), "scale", Vector2.ONE * Tokens.LAUNCH_SCALE, "launch", true)
	_fade.visible = true
	Motion.to(_fade, "color:a", 1.0, "launch").finished.connect(launch_faded.emit)


## Back from an app: fade in from black with the same tile focused.
func play_return() -> void:
	_launching = false
	Motion.stop(_tile(focus), "scale")
	_tile(focus).scale = Vector2.ONE * Tokens.TILE_FOCUS_SCALE
	_fade.visible = true
	_fade.color.a = 1.0
	Motion.to(_fade, "color:a", 0.0, "return").finished.connect(func(): _fade.visible = false)


func is_launching() -> bool:
	return _launching


## Index of the tile (with its label) under a viewport position, or -1.
func tile_at(pos: Vector2) -> int:
	for i in tiles.size():
		if tiles[i].get_global_rect().has_point(pos):
			return i
	return -1


# Hover moves focus only in pointer mode, after the pointer rests on a tile.
func _on_pointer_move(pos: Vector2) -> void:
	var im := _input_mode()
	if im == null or im.mode != InputModeScript.Mode.POINTER:
		_hover = -1
		return
	var i := tile_at(pos)
	if i == _hover:
		return
	_hover = i
	_dwell_timer.stop()
	if i >= 0 and i != focus:
		_hover_since = im.now_ms()
		_dwell_timer.start(Tokens.HOVER_DWELL)


func resolve_dwell() -> void:
	var im := _input_mode()
	if _hover < 0 or im == null or im.mode != InputModeScript.Mode.POINTER:
		return
	if im.now_ms() - _hover_since >= int(Tokens.HOVER_DWELL * 1000):
		set_focus(_hover)


func _input_mode() -> Node:
	return get_node_or_null("/root/InputMode")




func set_focus(i: int, animate := true) -> void:
	if apps.is_empty():
		return
	var old := focus
	focus = clampi(i, 0, apps.size() - 1)
	for t in tiles.size():
		if not animate or t >= _tile_on.size() or _tile_on[t] != (t == focus):
			_style_tile(t, t == focus, animate)
	if animate and focus == old:
		return
	_show_hero(apps[focus], animate)
	var strip_x := Tokens.PAD_X - maxi(0, focus - Tokens.CAROUSEL_LEAD) * (Tokens.TILE + Tokens.TILE_GAP)
	var moved := strip_x != _strip_x
	_strip_x = strip_x
	if animate:
		if moved:
			Motion.to(_strip, "position:x", _strip_x, "carousel", true)
	else:
		Motion.stop(_strip, "position:x")
		_strip.position.x = _strip_x


# The outgoing hero page fades out while the incoming one fades in, rising
# into place, its kind label tweening from the old accent to the new one.
func _show_hero(app: Dictionary, animate: bool) -> void:
	var from_accent := _accent
	_accent = app.accent
	if animate:
		Motion.to(_pages[_page], "modulate:a", 0.0, "hero")
		_page = 1 - _page
	var page := _pages[_page]
	page.get_parent().move_child(page, -1)
	_kind = page.get_node("Kind")
	_name = page.get_node("Name")
	_desc = page.get_node("Desc")
	_kind.text = app.kind.to_upper()
	_name.text = app.name
	_desc.text = app.description
	if not animate:
		for p in _pages:
			Motion.stop(p, "modulate:a")
			Motion.stop(p, "position:y")
			p.modulate.a = 1.0 if p == page else 0.0
			p.offset_top = 0.0      # not position: before layout that bakes in a size
			p.offset_bottom = 0.0
		Motion.stop(_kind, "theme_override_colors/font_color")
		_kind.add_theme_color_override("font_color", app.accent)
		return
	page.modulate.a = 0.0
	Motion.to(page, "modulate:a", 1.0, "hero")
	if not Motion.reduce:
		page.position.y = Tokens.HERO_RISE
	Motion.to(page, "position:y", 0.0, "hero", true)
	_kind.add_theme_color_override("font_color", from_accent)
	Motion.to(_kind, "theme_override_colors/font_color", app.accent, "hero")


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

	_fade = ColorRect.new()
	_fade.color = Color(Tokens.BLACK, 0.0)
	_fade.set_anchors_preset(PRESET_FULL_RECT)
	_fade.visible = false
	add_child(_fade)


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
	var hero := Control.new()
	hero.size_flags_vertical = SIZE_EXPAND_FILL
	for i in 2:
		_pages.append(_build_hero_page())
		hero.add_child(_pages[i])
	var m := _margin(hero)
	m.size_flags_vertical = SIZE_EXPAND_FILL
	return m


func _build_hero_page() -> VBoxContainer:
	var hero := VBoxContainer.new()
	hero.set_anchors_preset(PRESET_FULL_RECT)
	hero.add_theme_constant_override("separation", 0)
	hero.alignment = BoxContainer.ALIGNMENT_END

	var kind := _label("", Tokens.mono(500, Tokens.HERO_KIND, Tokens.TRACK_LABEL), Tokens.HERO_KIND, Tokens.TEXT)
	kind.name = "Kind"
	hero.add_child(kind)

	# The hero name is set solid (line-height 1), so its label box is taller
	# than the line; take the overhang out of the gaps either side.
	var name_font := Tokens.sans(700, Tokens.HERO_NAME, Tokens.TRACK_HERO)
	var overhang := (name_font.get_height(Tokens.HERO_NAME) - Tokens.HERO_NAME) / 2.0
	hero.add_child(_spacer(Tokens.HERO_KIND_GAP - overhang))
	var title := _label("", name_font, Tokens.HERO_NAME, Tokens.TEXT)
	title.name = "Name"
	hero.add_child(title)
	hero.add_child(_spacer(Tokens.HERO_DESC_GAP - overhang))
	var desc := _label("", Tokens.sans(400, Tokens.HERO_DESC), Tokens.HERO_DESC, Tokens.MUTED)
	desc.name = "Desc"
	hero.add_child(desc)
	return hero


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
	var ring := Control.new()
	ring.name = "Focus"
	tile.add_child(ring)
	ring.add_child(_ring("Gap", gap, Tokens.BG, gap))
	ring.add_child(_ring("Ring", outer, Tokens.RING, Tokens.RING_WIDTH))

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
	_hints = HintBar.new(["Open", "Menu"], Tokens.HINT, Tokens.HINT_GAP, Tokens.HINT_KEY_GAP)
	_hints.alignment = BoxContainer.ALIGNMENT_END
	return _margin(_hints)


func _set_hint_style(style: String) -> void:
	_hints.set_style(style)


func hint_labels() -> Array:
	return _hints.labels()


# Helpers ---------------------------------------------------------------------

func _label(text: String, font: Font, size: int, color: Color) -> Label:
	return UI.label(text, font, size, color)


func _box(color: Color, radius: int) -> StyleBoxFlat:
	return UI.box(color, radius)


func _spacer(h: float) -> Control:
	return UI.spacer(h)


func _margin(c: Control) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", Tokens.PAD_X)
	m.add_theme_constant_override("margin_right", Tokens.PAD_X)
	m.add_child(c)
	return m


func _tile(i: int) -> Control:
	return tiles[i].get_node("Holder/Tile")


func _style_tile(i: int, on: bool, animate: bool) -> void:
	while _tile_on.size() <= i:
		_tile_on.append(false)
	_tile_on[i] = on
	var cell := tiles[i]
	var tile := _tile(i)
	var ring: Control = tile.get_node("Focus")
	var scale_to := Vector2.ONE * (Tokens.TILE_FOCUS_SCALE if on else 1.0)
	var alpha := 1.0 if on else 0.0
	if animate:
		Motion.to(tile, "scale", scale_to, "tile_focus", true)
		Motion.to(ring, "modulate:a", alpha, "tile_focus")
	else:
		Motion.stop(tile, "scale")
		Motion.stop(ring, "modulate:a")
		tile.scale = scale_to
		ring.modulate.a = alpha
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
	_wifi.texture = null              # set_wifi draws it again at the new scale
	set_wifi(_wifi_state)


func _display_scale() -> float:
	return UI.display_scale(self)


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
