# The sidebar: a 560 px panel over a blurred, dimmed Home. The blur is
# Home captured once into a quarter-size texture and blurred by a shader; it
# is freed when the sidebar closes.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const Motion := preload("res://scripts/motion.gd")
const UI := preload("res://scripts/ui.gd")
const HintBar := preload("res://scripts/hint_bar.gd")

const DAYS := ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS := ["January", "February", "March", "April", "May", "June", "July",
	"August", "September", "October", "November", "December"]

# id, label, glyph. A divider sits between DIVIDER_AT - 1 and DIVIDER_AT.
const ITEMS := [
	["home", "Home", "home"],
	["settings", "Settings", "settings"],
	["desktop", "Desktop", "desktop"],
	["restart", "Restart", "restart"],
	["poweroff", "Power off", "power"],
]
const DIVIDER_AT := 3

const BLUR_SHADER := """
shader_type canvas_item;
uniform float radius = 3.0;
void fragment() {
	vec2 step = TEXTURE_PIXEL_SIZE * radius * 0.5;
	vec4 sum = vec4(0.0);
	float total = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			float w = exp(-float(x * x + y * y) / 4.0);
			sum += texture(TEXTURE, UV + vec2(float(x), float(y)) * step) * w;
			total += w;
		}
	}
	COLOR = sum / total;
}
"""

var is_open := false
var focus := 0

var _home: Control
var _blur: TextureRect
var _dim: ColorRect
var _panel: PanelContainer
var _items: Array[PanelContainer] = []
var _clock: Label
var _date: Label
var _clock_timer: Timer
var _scale := 1.0


func _init(home: Control) -> void:
	_home = home


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)
	_scale = UI.display_scale(self)
	get_viewport().size_changed.connect(_on_size_changed)
	set_focus(0)


# The TV mode can change after start (D79): draw the glyphs again for it.
func _on_size_changed() -> void:
	var s := UI.display_scale(self)
	if not is_equal_approx(s, _scale):
		_scale = s
		set_focus(focus)


func has_capture() -> bool:
	return _blur.texture != null


## Grabs what is on screen now (Home) into the quarter-size blur texture.
func capture() -> void:
	_blur.texture = null
	if DisplayServer.get_name() == "headless":
		return
	var tex := get_viewport().get_texture()
	var img := tex.get_image() if tex else null
	if img == null or img.is_empty():
		return
	# Main is scaled by Screen size (D33) and _blur is drawn inside it, so keep
	# only the part of the screen this panel covers, or Home is scaled twice.
	var r := capture_rect(img.get_size())
	if r.has_area() and r.size != img.get_size():
		img = img.get_region(r)
	for i in 2:   # two halvings average 2x2 blocks, so nothing aliases
		img.resize(maxi(img.get_width() / 2, 1), maxi(img.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
	_blur.texture = ImageTexture.create_from_image(img)


## The part of the viewport's picture (img_size pixels) that this sidebar,
## and so the blur, covers.
func capture_rect(img_size: Vector2i) -> Rect2i:
	var xf := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	var on_screen := (xf * Rect2(Vector2.ZERO, size)).abs()
	var r := Rect2i(Vector2i(on_screen.position.round()), Vector2i(on_screen.size.round()))
	return r.intersection(Rect2i(Vector2i.ZERO, img_size))


func open(animate: bool) -> void:
	is_open = true
	visible = true
	_tick_clock()
	_home.pivot_offset = _home.size / 2.0
	if not animate:
		for p in [[_panel, "position:x"], [_dim, "color:a"], [_blur, "modulate:a"], [_blur, "scale"], [_home, "scale"]]:
			Motion.stop(p[0], p[1])
		_panel.position.x = 0.0
		_dim.color.a = Tokens.SIDEBAR_DIM
		_blur.modulate.a = 1.0
		_blur.scale = Vector2.ONE * Tokens.SIDEBAR_HOME_SCALE
		_home.scale = Vector2.ONE * Tokens.SIDEBAR_HOME_SCALE
		return
	Motion.to(_panel, "position:x", 0.0, "sidebar_open", true)
	Motion.to(_dim, "color:a", Tokens.SIDEBAR_DIM, "sidebar_open")
	Motion.to(_blur, "modulate:a", 1.0, "sidebar_open")
	Motion.to(_blur, "scale", Vector2.ONE * Tokens.SIDEBAR_HOME_SCALE, "sidebar_open", true)
	Motion.to(_home, "scale", Vector2.ONE * Tokens.SIDEBAR_HOME_SCALE, "sidebar_open", true)


## Slides the panel out. keep_capture holds the blur for a return from the
## power confirm; otherwise the texture is freed.
func close(animate: bool, keep_capture := false) -> void:
	if not is_open and not visible:
		if not keep_capture:
			_blur.texture = null
		return
	is_open = false
	if _clock_timer:
		_clock_timer.stop()
	if not animate:
		for p in [[_panel, "position:x"], [_dim, "color:a"], [_blur, "modulate:a"], [_blur, "scale"], [_home, "scale"]]:
			Motion.stop(p[0], p[1])
		_home.scale = Vector2.ONE
		_finish_close(keep_capture)
		return
	Motion.to(_panel, "position:x", -float(Tokens.SIDEBAR_WIDTH), "sidebar_close", true)
	Motion.to(_blur, "modulate:a", 0.0, "sidebar_close")
	Motion.to(_blur, "scale", Vector2.ONE, "sidebar_close", true)
	Motion.to(_home, "scale", Vector2.ONE, "sidebar_close", true)
	Motion.to(_dim, "color:a", 0.0, "sidebar_close").finished.connect(
		func(): if not is_open: _finish_close(keep_capture))


func _finish_close(keep_capture: bool) -> void:
	visible = false
	_panel.position.x = -Tokens.SIDEBAR_WIDTH
	_dim.color.a = 0.0
	_blur.modulate.a = 0.0
	_blur.scale = Vector2.ONE
	if not keep_capture:
		_blur.texture = null


func set_focus(i: int) -> void:
	focus = i
	for j in _items.size():
		_style_item(j, j == i)


## Index of the item under a canvas position, or -1.
func item_at(pos: Vector2) -> int:
	for i in _items.size():
		if _items[i].get_global_rect().has_point(pos):
			return i
	return -1


## True anywhere outside the panel: the dimmed area beside it, or the border
## round a UI shrunk by Screen size. The panel's global rect carries Main's
## scale, as item_at does.
func is_on_dim(pos: Vector2) -> bool:
	return not _panel.get_global_rect().has_point(pos)


# Build -----------------------------------------------------------------------

func _build() -> void:
	_blur = TextureRect.new()
	_blur.size = Tokens.BASE_SIZE
	_blur.pivot_offset = Vector2(Tokens.BASE_SIZE) / 2.0
	_blur.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_blur.stretch_mode = TextureRect.STRETCH_SCALE
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = BLUR_SHADER
	mat.set_shader_parameter("radius", Tokens.BLUR_RADIUS)
	_blur.material = mat
	_blur.modulate.a = 0.0
	add_child(_blur)

	_dim = ColorRect.new()
	_dim.size = Tokens.BASE_SIZE
	_dim.color = Color(Tokens.SCRIM, 0.0)
	add_child(_dim)

	var clock_font := Tokens.mono(500, Tokens.SIDEBAR_CLOCK)
	var clock_hang := UI.overhang(clock_font, Tokens.SIDEBAR_CLOCK, Tokens.SIDEBAR_CLOCK)

	_panel = PanelContainer.new()
	_panel.size = Vector2(Tokens.SIDEBAR_WIDTH, Tokens.BASE_SIZE.y)
	_panel.position.x = -Tokens.SIDEBAR_WIDTH
	var sb := UI.box(Tokens.SURFACE, 0)
	sb.border_color = Tokens.BORDER
	sb.border_width_right = 1
	sb.content_margin_top = Tokens.SIDEBAR_PAD_TOP - clock_hang
	sb.content_margin_left = Tokens.SIDEBAR_PAD_X
	sb.content_margin_right = Tokens.SIDEBAR_PAD_X - 1
	sb.content_margin_bottom = Tokens.SIDEBAR_PAD_BOTTOM
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	_panel.add_child(col)

	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	_clock = UI.label("", clock_font, Tokens.SIDEBAR_CLOCK, Tokens.TEXT)
	head.add_child(_clock)
	head.add_child(UI.spacer(Tokens.SIDEBAR_DATE_GAP - clock_hang))
	_date = UI.label("", Tokens.sans(400, Tokens.SIDEBAR_DATE), Tokens.SIDEBAR_DATE, Tokens.MUTED)
	head.add_child(_date)
	col.add_child(_inset(head))

	col.add_child(UI.spacer(Tokens.SIDEBAR_ITEMS_GAP))
	var top := VBoxContainer.new()
	top.add_theme_constant_override("separation", Tokens.MENU_ITEM_GAP)
	col.add_child(top)

	var push := Control.new()
	push.size_flags_vertical = SIZE_EXPAND_FILL
	col.add_child(push)

	var rule := ColorRect.new()
	rule.color = Tokens.BORDER
	rule.custom_minimum_size.y = 1
	col.add_child(rule)
	col.add_child(UI.spacer(Tokens.MENU_DIVIDER_PAD))
	var bottom := VBoxContainer.new()
	bottom.add_theme_constant_override("separation", Tokens.MENU_ITEM_GAP)
	col.add_child(bottom)

	for i in ITEMS.size():
		(top if i < DIVIDER_AT else bottom).add_child(_item(ITEMS[i]))

	col.add_child(UI.spacer(Tokens.SIDEBAR_FOOTER_GAP))
	var hints := HintBar.new([["accept", "Select"], ["back", "Back"]], Tokens.SIDEBAR_HINT, Tokens.SIDEBAR_FOOTER_GAP, Tokens.SIDEBAR_HINT_KEY_GAP)
	col.add_child(_inset(hints))


func _item(item: Array) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = item[0]
	p.custom_minimum_size.y = Tokens.MENU_ITEM
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", Tokens.MENU_ICON_GAP)
	p.add_child(row)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(Tokens.MENU_ICON, Tokens.MENU_ICON)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = SIZE_SHRINK_CENTER
	icon.set_meta("glyph", item[2])
	row.add_child(icon)
	var l := UI.label(item[1], Tokens.sans(500, Tokens.MENU_ITEM_FONT), Tokens.MENU_ITEM_FONT, Tokens.STATUS)
	l.name = "Label"
	l.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(l)
	_items.append(p)
	return p


func _style_item(i: int, on: bool) -> void:
	var p := _items[i]
	var sb := UI.box(Tokens.TEXT if on else Color(Tokens.TEXT, 0.0), Tokens.MENU_ITEM_RADIUS)
	sb.content_margin_left = Tokens.SIDEBAR_INSET
	sb.content_margin_right = Tokens.SIDEBAR_INSET
	p.add_theme_stylebox_override("panel", sb)
	var color := Tokens.BG if on else Tokens.STATUS
	var icon: TextureRect = p.get_node("Row/Icon")
	icon.texture = Glyphs.texture(icon.get_meta("glyph"), color, Tokens.MENU_ICON, Tokens.STATUS_STROKE, _scale)
	p.get_node("Row/Label").add_theme_color_override("font_color", color)


func _inset(c: Control) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", Tokens.SIDEBAR_INSET)
	m.add_theme_constant_override("margin_right", Tokens.SIDEBAR_INSET)
	m.add_child(c)
	return m


func _tick_clock() -> void:
	var t := Time.get_datetime_dict_from_system()
	_clock.text = "%02d:%02d" % [t.hour, t.minute]
	_date.text = "%s %d %s" % [DAYS[t.weekday], t.day, MONTHS[t.month - 1]]
	if _clock_timer == null:
		_clock_timer = Timer.new()
		_clock_timer.one_shot = true
		_clock_timer.timeout.connect(_tick_clock)
		add_child(_clock_timer)
	_clock_timer.start(60 - t.second)
