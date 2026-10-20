# A row of hints, each a key pill and a word, given as [action, word] pairs.
# Key labels follow InputMode: the remote and keyboard share "OK", "Back" and
# "Menu"; pads get their face buttons.
extends HBoxContainer

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const UI := preload("res://scripts/ui.gd")

const KEYS := {
	"remote": {"accept": "OK", "back": "Back", "move": "Menu"},
	"xbox": {"accept": "A", "back": "B", "move": "Y"},
	"playstation": {"accept": "ps-cross", "back": "ps-circle", "move": "ps-triangle"},
}

var style := "remote"
var _hints: Array = []
var _text_size: int
var _key_gap: int
var _keys: Array[PanelContainer] = []
var _scale := 1.0


func _init(hints: Array, text_size: int, gap: int, key_gap: int) -> void:
	_text_size = text_size
	_key_gap = key_gap
	add_theme_constant_override("separation", gap)
	set_hints(hints)


func _ready() -> void:
	var im := get_node_or_null("/root/InputMode")
	if im:
		style = im.hint_style()
		im.hints_changed.connect(set_style)
	_scale = UI.display_scale(self)
	get_viewport().size_changed.connect(_on_size_changed)
	_fill()


func set_hints(hints: Array) -> void:
	if hints == _hints:
		return
	_hints = hints.duplicate()
	for c in get_children():
		c.queue_free()
		remove_child(c)
	_keys.clear()
	for h in hints:
		add_child(_hint(h[0], h[1]))
	UI.ignore_mouse(self)
	if is_inside_tree():
		_fill()


func set_style(s: String) -> void:
	style = s if KEYS.has(s) else "remote"
	_fill()


## The key labels shown, in order.
func labels() -> Array:
	return _hints.map(func(h): return KEYS[style][h[0]])


func words() -> Array:
	return _hints.map(func(h): return h[1])


func _hint(action: String, word: String) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", _key_gap)
	var pill := PanelContainer.new()
	pill.custom_minimum_size = Vector2(Tokens.KEY, Tokens.KEY)
	pill.size_flags_vertical = SIZE_SHRINK_CENTER
	pill.set_meta("action", action)
	var k := UI.label("", Tokens.mono(500, Tokens.KEY_FONT), Tokens.KEY_FONT, Tokens.TEXT)
	k.name = "Text"
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pill.add_child(k)
	var g := TextureRect.new()
	g.name = "Glyph"
	g.custom_minimum_size = Vector2(Tokens.KEY_FONT, Tokens.KEY_FONT)
	g.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	g.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	g.size_flags_horizontal = SIZE_SHRINK_CENTER
	g.size_flags_vertical = SIZE_SHRINK_CENTER
	pill.add_child(g)
	_keys.append(pill)
	h.add_child(pill)
	var t := UI.label(word, Tokens.sans(400, _text_size), _text_size, Tokens.MUTED)
	t.size_flags_vertical = SIZE_SHRINK_CENTER
	h.add_child(t)
	return h


func _fill() -> void:
	var glyphs := style == "playstation"
	for pill in _keys:
		var key: String = KEYS[style][pill.get_meta("action")]
		var sb := UI.box(Tokens.KEY_BG, Tokens.KEY / 2)
		if style == "remote":
			sb.content_margin_left = Tokens.KEY_PAD_KEYBOARD
			sb.content_margin_right = Tokens.KEY_PAD_KEYBOARD
		pill.add_theme_stylebox_override("panel", sb)
		var text: Label = pill.get_node("Text")
		var g: TextureRect = pill.get_node("Glyph")
		text.visible = not glyphs
		g.visible = glyphs
		if glyphs:
			g.texture = Glyphs.texture(key, Tokens.TEXT, Tokens.KEY_FONT, Tokens.STATUS_STROKE, _scale)
		else:
			text.text = key


func _on_size_changed() -> void:
	var s := UI.display_scale(self)
	if not is_equal_approx(s, _scale):
		_scale = s
		_fill()
