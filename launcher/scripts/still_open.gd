# Still open: after Return to Bosca Mor, the desktop apps that didn't close.
# Show me (focused by default), Close anyway (via a confirm), Back to desktop.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const UI := preload("res://scripts/ui.gd")
const IconResolver := preload("res://scripts/icon_resolver.gd")

const BUTTONS := ["Show me", "Close anyway", "Back to desktop"]
const ACCENTS := [Tokens.CYAN, Tokens.CORAL, Tokens.YELLOW, Tokens.TEAL]

## [{wid, name, icon, asking}] from the daemon.
var apps: Array = []
var focus := 0

var _title: Label
var _list: VBoxContainer
var _buttons: Array[PanelContainer] = []
var _scale := 1.0


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)
	_scale = UI.display_scale(self)


func open(list: Array) -> void:
	apps = list
	_scale = UI.display_scale(self)   # the TV mode may have changed since start
	_title.text = "1 app is still open" if apps.size() == 1 else "%d apps are still open" % apps.size()
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in apps.size():
		_list.add_child(_row(apps[i], ACCENTS[i % ACCENTS.size()]))
	UI.ignore_mouse(_list)
	set_focus(0)
	visible = true


func close() -> void:
	visible = false


func wids() -> Array:
	return apps.map(func(a): return a.wid)


func set_focus(i: int) -> void:
	focus = i
	for j in _buttons.size():
		var on := j == i
		var b := _buttons[j]
		var sb := UI.box(Tokens.TEXT if on else Color(Tokens.TEXT, 0.0), Tokens.BUTTON_RADIUS)
		if not on:
			sb.border_color = Tokens.BUTTON_BORDER
			sb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
		b.add_theme_stylebox_override("panel", sb)
		var l: Label = b.get_node("Label")
		l.add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.STILL_BUTTON_FONT))
		l.add_theme_color_override("font_color", Tokens.BG if on else Tokens.TEXT)


func button_at(pos: Vector2) -> int:
	for i in _buttons.size():
		if _buttons[i].get_global_rect().has_point(pos):
			return i
	return -1


func title() -> String:
	return _title.text


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Tokens.BG
	bg.size = Tokens.BASE_SIZE
	add_child(bg)

	var center := CenterContainer.new()
	center.size = Tokens.BASE_SIZE
	add_child(center)
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = Tokens.STILL_WIDTH
	col.add_theme_constant_override("separation", 0)
	center.add_child(col)

	var title_font := Tokens.sans(700, Tokens.STILL_TITLE, Tokens.TRACK_TITLE)
	var hang := UI.overhang(title_font, Tokens.STILL_TITLE, Tokens.STILL_TITLE * Tokens.STILL_TITLE_LINE)
	_title = UI.label("", title_font, Tokens.STILL_TITLE, Tokens.TEXT)
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_top", -int(round(hang)))
	wrap.add_child(_title)
	col.add_child(wrap)
	col.add_child(UI.spacer(Tokens.STILL_BODY_GAP - hang))
	col.add_child(UI.label("They may be asking to save your work.", Tokens.sans(400, Tokens.STILL_BODY), Tokens.STILL_BODY, Tokens.MUTED))
	col.add_child(UI.spacer(Tokens.STILL_LIST_GAP))

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", Tokens.STILL_ROW_GAP)
	col.add_child(_list)
	col.add_child(UI.spacer(Tokens.STILL_BUTTONS_GAP))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.BUTTON_GAP)
	col.add_child(row)
	for word in BUTTONS:
		var b := PanelContainer.new()
		b.custom_minimum_size.y = Tokens.BUTTON
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		var l := UI.label(word, Tokens.sans(500, Tokens.STILL_BUTTON_FONT), Tokens.STILL_BUTTON_FONT, Tokens.TEXT)
		l.name = "Label"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_child(l)
		row.add_child(b)
		_buttons.append(b)


func _row(app: Dictionary, accent: Color) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size.y = Tokens.STILL_ROW
	var sb := UI.box(Tokens.SURFACE, Tokens.BUTTON_RADIUS)
	sb.border_color = Tokens.BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = Tokens.STILL_ROW_PAD
	sb.content_margin_right = Tokens.STILL_ROW_PAD
	p.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.STILL_ROW_SPACING)
	p.add_child(row)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(Tokens.STILL_ICON_BOX, Tokens.STILL_ICON_BOX)
	box.size_flags_vertical = SIZE_SHRINK_CENTER
	box.add_theme_stylebox_override("panel", UI.box(Tokens.TILE_TINTS["#" + accent.to_html(false)], Tokens.STILL_ICON_RADIUS))
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(Tokens.STILL_ICON, Tokens.STILL_ICON)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_horizontal = SIZE_SHRINK_CENTER
	icon.size_flags_vertical = SIZE_SHRINK_CENTER
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var path := IconResolver.theme_icon(app.get("icon", ""))
	icon.texture = IconResolver.texture(path, roundi(Tokens.STILL_ICON * _scale), "still-" + app.get("icon", "")) if path else null
	if icon.texture == null:
		icon.texture = Glyphs.texture("apps", accent, Tokens.STILL_ICON, Tokens.ROW_GLYPH_STROKE, _scale)
	box.add_child(icon)
	row.add_child(box)

	var name_l := UI.label(app.get("name", ""), Tokens.sans(500, Tokens.STILL_NAME), Tokens.STILL_NAME, Tokens.TEXT)
	name_l.size_flags_horizontal = SIZE_EXPAND_FILL
	name_l.size_flags_vertical = SIZE_SHRINK_CENTER
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_l)
	var asking: bool = app.get("asking", false)
	var status := UI.label("Asking to save" if asking else "Still open", Tokens.sans(400, Tokens.STILL_STATUS), Tokens.STILL_STATUS, Tokens.YELLOW if asking else Tokens.MUTED)
	status.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(status)
	return p
