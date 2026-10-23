# The power confirm: "Power off this device?" or "Restart this device?" with
# Cancel and the action. Cancel always has focus when it opens.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const Motion := preload("res://scripts/motion.gd")
const UI := preload("res://scripts/ui.gd")

const COPY := {
	"poweroff": {"title": "Power off this device?", "body": "Anything playing will stop.", "verb": "Power off", "glyph": "power"},
	"restart": {"title": "Restart this device?", "body": "The launcher opens again once it is back.", "verb": "Restart", "glyph": "restart"},
	"forceclose": {"title": "Close %d apps?", "one": "Close 1 app?", "body": "Unsaved work will be lost.", "verb": "Close anyway", "glyph": "close"},
	"remove": {"title": "Remove %s?", "body": "It comes off Home. You can add it again from Add app.", "verb": "Remove", "glyph": "close"},
	"picture": {"title": "Keep this picture?", "body": "It goes back to the last one in %d seconds.", "verb": "Keep", "glyph": "desktop"},
}

var is_open := false
var kind := "poweroff"
var focus := 0

var _dialog: PanelContainer
var _icon: TextureRect
var _title: Label
var _body: Label
var _buttons: Array[PanelContainer] = []
var _scale := 1.0


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)
	_scale = UI.display_scale(self)


## count: how many apps a force-close would close. subject: the app to remove.
func open(k: String, animate: bool, count := 0, subject := "") -> void:
	kind = k
	var copy: Dictionary = COPY[k]
	_icon.texture = Glyphs.texture(copy.glyph, Tokens.CORAL, Tokens.DIALOG_ICON, Tokens.STATUS_STROKE, _scale)
	if copy.title.contains("%s"):
		_title.text = copy.title % subject
	else:
		_title.text = copy.one if count == 1 and copy.has("one") else (copy.title % count if copy.title.contains("%d") else copy.title)
	_body.text = copy.body % int(Tokens.PICTURE_KEEP) if copy.body.contains("%d") else copy.body
	_buttons[1].get_node("Label").text = copy.verb
	set_focus(0)
	_dialog.reset_size()
	_dialog.position = ((Vector2(Tokens.BASE_SIZE) - _dialog.size) / 2.0).round()
	_dialog.pivot_offset = _dialog.size / 2.0
	var showing := visible     # mid-close: carry on from where the fade is
	is_open = true
	visible = true
	if not animate:
		Motion.stop(self, "modulate:a")
		Motion.stop(_dialog, "scale")
		modulate.a = 1.0
		_dialog.scale = Vector2.ONE
		return
	if not showing:
		modulate.a = 0.0
		if not Motion.reduce:
			_dialog.scale = Vector2.ONE * Tokens.CONFIRM_SCALE_FROM
	Motion.to(self, "modulate:a", 1.0, "confirm")
	Motion.to(_dialog, "scale", Vector2.ONE, "confirm", true)


func close(animate: bool) -> void:
	if not is_open:
		return
	is_open = false
	if not animate:
		Motion.stop(self, "modulate:a")
		visible = false
		return
	Motion.to(self, "modulate:a", 0.0, "confirm").finished.connect(
		func(): if not is_open: visible = false)


func set_focus(i: int) -> void:
	focus = i
	for j in _buttons.size():
		_style_button(j, j == i)


## 0 for Cancel, 1 for the action, -1 for neither.
func button_at(pos: Vector2) -> int:
	for i in _buttons.size():
		if _buttons[i].get_global_rect().has_point(pos):
			return i
	return -1


func title() -> String:
	return _title.text


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.size = Tokens.BASE_SIZE
	scrim.color = Color(Tokens.SCRIM, Tokens.CONFIRM_DIM)
	add_child(scrim)

	var title_font := Tokens.sans(700, Tokens.DIALOG_TITLE)
	var hang := UI.overhang(title_font, Tokens.DIALOG_TITLE, Tokens.DIALOG_TITLE * Tokens.DIALOG_TITLE_LINE)

	_dialog = PanelContainer.new()
	_dialog.custom_minimum_size.x = Tokens.DIALOG_WIDTH
	var sb := UI.box(Tokens.DIALOG_BG, Tokens.DIALOG_RADIUS)
	sb.border_color = Tokens.DIALOG_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_top = Tokens.DIALOG_PAD_TOP
	sb.content_margin_left = Tokens.DIALOG_PAD
	sb.content_margin_right = Tokens.DIALOG_PAD
	sb.content_margin_bottom = Tokens.DIALOG_PAD
	_dialog.add_theme_stylebox_override("panel", sb)
	add_child(_dialog)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	_dialog.add_child(col)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(Tokens.DIALOG_ICON, Tokens.DIALOG_ICON)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.size_flags_horizontal = SIZE_SHRINK_CENTER
	col.add_child(_icon)
	col.add_child(UI.spacer(Tokens.DIALOG_TITLE_GAP - hang))
	_title = UI.label("", title_font, Tokens.DIALOG_TITLE, Tokens.TEXT)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)
	col.add_child(UI.spacer(Tokens.DIALOG_BODY_GAP - hang))
	_body = UI.label("", Tokens.sans(400, Tokens.DIALOG_BODY), Tokens.DIALOG_BODY, Tokens.MUTED)
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_body)
	col.add_child(UI.spacer(Tokens.DIALOG_BUTTONS_GAP))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.BUTTON_GAP)
	col.add_child(row)
	for word in ["Cancel", ""]:
		var b := PanelContainer.new()
		b.custom_minimum_size.y = Tokens.BUTTON
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.size_flags_stretch_ratio = 1.0
		var l := UI.label(word, Tokens.sans(500, Tokens.BUTTON_FONT), Tokens.BUTTON_FONT, Tokens.TEXT)
		l.name = "Label"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_child(l)
		row.add_child(b)
		_buttons.append(b)


# Focused: filled and bold. The other: outlined.
func _style_button(i: int, on: bool) -> void:
	var b := _buttons[i]
	var sb := UI.box(Tokens.TEXT if on else Color(Tokens.TEXT, 0.0), Tokens.BUTTON_RADIUS)
	if not on:
		sb.border_color = Tokens.BUTTON_BORDER
		sb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
	b.add_theme_stylebox_override("panel", sb)
	var l: Label = b.get_node("Label")
	l.add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.BUTTON_FONT))
	l.add_theme_color_override("font_color", Tokens.BG if on else Tokens.TEXT)
