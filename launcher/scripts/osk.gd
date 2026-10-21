# The on-screen keyboard: a D-pad grid of letters, digits, . / : - _, a .com
# key, Delete and Done. A physical keyboard types straight into the field;
# that is the one place characters are read from key events rather than
# actions (D35). Settings forwards input here while it is open.
extends Control

signal done(text: String)
signal cancelled

const Tokens := preload("res://theme/tokens.gd")
const UI := preload("res://scripts/ui.gd")

# Each key is [label, width in key units]. Every row is ten units wide.
const ROWS := [
	[["1", 1], ["2", 1], ["3", 1], ["4", 1], ["5", 1], ["6", 1], ["7", 1], ["8", 1], ["9", 1], ["0", 1]],
	[["q", 1], ["w", 1], ["e", 1], ["r", 1], ["t", 1], ["y", 1], ["u", 1], ["i", 1], ["o", 1], ["p", 1]],
	[["a", 1], ["s", 1], ["d", 1], ["f", 1], ["g", 1], ["h", 1], ["j", 1], ["k", 1], ["l", 1], ["-", 1]],
	[["z", 1], ["x", 1], ["c", 1], ["v", 1], ["b", 1], ["n", 1], ["m", 1], [".", 1], ["/", 1], [":", 1]],
	[["_", 1], ["Space", 3], [".com", 2], ["Delete", 2], ["Done", 2]],
]
const MAX_LENGTH := 200

var text := ""
var row := 0
var col := 0

var _title: Label
var _field: Label
var _keys: Array = []     # [row][col] -> PanelContainer


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)


func open(title: String, value: String) -> void:
	_title.text = title
	text = value
	row = 0
	col = 0
	visible = true
	_refresh()


func close() -> void:
	visible = false


## The key label under focus.
func focused_key() -> String:
	return ROWS[row][col][0]


## Takes one input event while open. True if it was used.
func handle(ev: InputEvent) -> bool:
	if not visible:
		return false
	if ev.is_action_pressed("text_delete", true):
		_delete()
		return true
	if ev is InputEventKey and ev.pressed and ev.unicode >= 32 and not ev.ctrl_pressed and not ev.alt_pressed:
		_type(char(ev.unicode))   # the space bar types a space here, not OK (D35)
		return true
	if ev.is_action_pressed("nav_left", true):
		col = maxi(col - 1, 0)
	elif ev.is_action_pressed("nav_right", true):
		col = mini(col + 1, ROWS[row].size() - 1)
	elif ev.is_action_pressed("nav_up", true):
		_change_row(-1)
	elif ev.is_action_pressed("nav_down", true):
		_change_row(1)
	elif ev.is_action_pressed("accept"):
		press(focused_key())
		return true
	elif ev.is_action_pressed("back"):
		close()
		cancelled.emit()
		return true
	else:
		return false
	_refresh()
	return true


func press(key: String) -> void:
	match key:
		"Delete": _delete()
		"Space": _type(" ")
		"Done":
			close()
			done.emit(text)
		_: _type(key)


func _type(s: String) -> void:
	text = (text + s).left(MAX_LENGTH)
	_refresh()


func _delete() -> void:
	text = text.left(-1)
	_refresh()


# Up and down land on the key whose centre is nearest.
func _change_row(step: int) -> void:
	var to := clampi(row + step, 0, ROWS.size() - 1)
	if to == row:
		return
	var x := _centre(row, col)
	var best := 0
	for c in ROWS[to].size():
		if absf(_centre(to, c) - x) < absf(_centre(to, best) - x):
			best = c
	row = to
	col = best


func _centre(r: int, c: int) -> float:
	var units := 0
	for i in c:
		units += ROWS[r][i][1]
	return units + ROWS[r][c][1] / 2.0


func _key_width(units: int) -> int:
	return units * Tokens.OSK_KEY + (units - 1) * Tokens.OSK_KEY_GAP


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.size = Tokens.BASE_SIZE
	scrim.color = Color(Tokens.SCRIM, Tokens.CONFIRM_DIM)
	add_child(scrim)

	var panel := PanelContainer.new()
	var sb := UI.box(Tokens.DIALOG_BG, Tokens.DIALOG_RADIUS)
	sb.border_color = Tokens.DIALOG_BORDER
	sb.set_border_width_all(1)
	sb.set_content_margin_all(Tokens.DIALOG_PAD)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var col_box := VBoxContainer.new()
	col_box.add_theme_constant_override("separation", Tokens.LIST_TOP)
	panel.add_child(col_box)

	_title = UI.label("", Tokens.sans(700, Tokens.SECTION_TITLE), Tokens.SECTION_TITLE, Tokens.TEXT)
	col_box.add_child(_title)

	var field := PanelContainer.new()
	field.custom_minimum_size.y = Tokens.OSK_FIELD
	var fsb := UI.box(Tokens.SURFACE, Tokens.ROW_RADIUS)
	fsb.border_color = Tokens.BORDER
	fsb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
	fsb.content_margin_left = Tokens.NAV_ITEM_PAD
	fsb.content_margin_right = Tokens.NAV_ITEM_PAD
	field.add_theme_stylebox_override("panel", fsb)
	_field = UI.label("", Tokens.mono(400, Tokens.OSK_FONT), Tokens.OSK_FONT, Tokens.TEXT)
	_field.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_field.clip_text = true
	field.add_child(_field)
	col_box.add_child(field)

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", Tokens.OSK_KEY_GAP)
	col_box.add_child(grid)
	for r in ROWS.size():
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", Tokens.OSK_KEY_GAP)
		grid.add_child(line)
		var keys := []
		for k in ROWS[r]:
			var key := PanelContainer.new()
			key.custom_minimum_size = Vector2(_key_width(k[1]), Tokens.OSK_KEY_H)
			var l := UI.label(k[0], Tokens.sans(500, Tokens.OSK_FONT), Tokens.OSK_FONT, Tokens.TEXT)
			l.name = "Label"
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			key.add_child(l)
			line.add_child(key)
			keys.append(key)
		_keys.append(keys)

	panel.reset_size()
	panel.position = ((Vector2(Tokens.BASE_SIZE) - panel.get_combined_minimum_size()) / 2.0).round()


func _refresh() -> void:
	_field.text = text + "|"
	for r in _keys.size():
		for c in _keys[r].size():
			var on: bool = r == row and c == col
			var key: PanelContainer = _keys[r][c]
			key.add_theme_stylebox_override("panel", UI.box(Tokens.TEXT if on else Tokens.KEY_BG, Tokens.ROW_TILE_RADIUS))
			var l: Label = key.get_node("Label")
			l.add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.OSK_FONT))
			l.add_theme_color_override("font_color", Tokens.BG if on else Tokens.TEXT)
