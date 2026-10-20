# A one-line notice at the top centre of the screen, over Home, for a few
# seconds. It never takes focus or input. Messages queue and show one at a
# time; while the launcher is hidden they wait, so a notice raised behind an
# app shows the next time the launcher appears (D61).
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const Motion := preload("res://scripts/motion.gd")
const UI := preload("res://scripts/ui.gd")

var queue: Array[String] = []
var text := ""                      # the message on screen, or ""
## Main holds the queue while the launcher is hidden.
var held := false

var _panel: PanelContainer
var _icon: TextureRect
var _label: Label
var _timer: Timer


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = Tokens.TOAST_HOLD
	_timer.timeout.connect(_fade_out)
	add_child(_timer)


func push(message: String) -> void:
	queue.append(message)
	if text.is_empty() and not held:
		_next()


func is_showing() -> bool:
	return not text.is_empty()


## The launcher is hiding: drop the notice on screen (it was seen) and keep
## the rest for later.
func hold() -> void:
	held = true
	_timer.stop()
	Motion.stop(self, "modulate:a")
	text = ""
	visible = false


func release() -> void:
	held = false
	if text.is_empty():
		_next()


func _next() -> void:
	if queue.is_empty():
		visible = false
		return
	text = queue.pop_front()
	_label.text = text
	_icon.texture = Glyphs.texture("alert", Tokens.CORAL, Tokens.TOAST_ICON, Tokens.STATUS_STROKE, UI.display_scale(self))
	_panel.reset_size()
	_panel.position = Vector2(roundf((Tokens.BASE_SIZE.x - _panel.size.x) / 2.0), Tokens.PAD_TOP)
	visible = true
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, "toast")
	_timer.start()


func _fade_out() -> void:
	var t := Motion.to(self, "modulate:a", 0.0, "toast")
	t.finished.connect(_faded)


func _faded() -> void:
	text = ""
	visible = false
	if not held:
		_next()


func _build() -> void:
	_panel = PanelContainer.new()
	var sb := UI.box(Tokens.DIALOG_BG, Tokens.TOAST_RADIUS)
	sb.border_color = Tokens.DIALOG_BORDER
	sb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
	sb.content_margin_left = Tokens.TOAST_PAD
	sb.content_margin_right = Tokens.TOAST_PAD
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size.y = Tokens.TOAST_HEIGHT
	add_child(_panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.TOAST_ICON_GAP)
	_panel.add_child(row)
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(Tokens.TOAST_ICON, Tokens.TOAST_ICON)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(_icon)
	_label = UI.label("", Tokens.sans(500, Tokens.TOAST_FONT), Tokens.TOAST_FONT, Tokens.TEXT)
	_label.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(_label)
