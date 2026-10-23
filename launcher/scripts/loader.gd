# The loading screen on the black after a launch: the app's tile, "Opening
# <name>", and three dots pulsing in turn. It appears only when the app takes
# longer than LOADER_DELAY, and goes as soon as the app's window is up (D76).
# A Cinnamon panel opened from Settings gets it too, over Settings.
extends Control

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const UI := preload("res://scripts/ui.gd")
const IconResolver := preload("res://scripts/icon_resolver.gd")
const Motion := preload("res://scripts/motion.gd")

## True from start() until stop(), whether or not it has appeared yet.
var active := false

var _tile: Panel
var _icon: TextureRect
var _name: Label
var _dots: Array[Panel] = []
var _delay: Timer
var _pulse: Tween


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	UI.ignore_mouse(self)
	_delay = Timer.new()
	_delay.one_shot = true
	_delay.timeout.connect(reveal)
	add_child(_delay)


## The app is starting: show it if it's still starting after LOADER_DELAY.
func start(app: Dictionary) -> void:
	active = true
	_fill(app)
	_delay.start(Tokens.LOADER_DELAY)


## Shows it now (the delay timer calls this).
func reveal() -> void:
	if not active:
		return
	visible = true
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, "return")
	_start_pulse()


func stop() -> void:
	active = false
	_delay.stop()
	if _pulse and _pulse.is_valid():
		_pulse.kill()
	_pulse = null
	Motion.stop(self, "modulate:a")
	visible = false


func name_text() -> String:
	return _name.text


func _fill(app: Dictionary) -> void:
	_name.text = "Opening %s" % app.get("name", "the app")
	var tint: Color = app.get("tint", Tokens.SURFACE)
	var accent: Color = app.get("accent", Tokens.TEXT)
	_tile.add_theme_stylebox_override("panel", UI.box(tint, Tokens.TILE_RADIUS))
	# The scale now, not at start-up: Settings can change the TV mode since.
	var s := UI.display_scale(self)
	var tex: Texture2D = null
	if app.has("argv"):
		var found := IconResolver.find(app)
		if found:
			tex = IconResolver.texture(found.path, roundi(Tokens.TILE * Tokens.ICON_INSET * s), app.get("id", "app") + "-loader")
	if tex:
		_icon.texture = tex
		_icon.custom_minimum_size = Vector2.ONE * Tokens.TILE * Tokens.ICON_INSET
	else:
		_icon.texture = Glyphs.texture(Glyphs.name_for(app), accent, Tokens.GLYPH, Tokens.GLYPH_STROKE, s)
		_icon.custom_minimum_size = Vector2.ONE * Tokens.GLYPH


# The dots rise and fall one after another, round and round.
func _start_pulse() -> void:
	if _pulse and _pulse.is_valid():
		_pulse.kill()
	for d in _dots:
		d.modulate.a = Tokens.LOADER_DOT_DIM
	_pulse = create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for d in _dots:
		_pulse.tween_property(d, "modulate:a", 1.0, Tokens.LOADER_DOT_STEP)
		_pulse.tween_property(d, "modulate:a", Tokens.LOADER_DOT_DIM, Tokens.LOADER_DOT_STEP)


func _build() -> void:
	# Its own black: over Home's launch fade it changes nothing, and over
	# Settings (a Cinnamon panel opening) it hides what can't be used now.
	var black := ColorRect.new()
	black.size = Tokens.BASE_SIZE
	black.color = Tokens.BLACK
	add_child(black)
	var center := CenterContainer.new()
	center.size = Tokens.BASE_SIZE
	add_child(center)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", Tokens.TILE_LABEL_GAP)
	center.add_child(col)

	_tile = Panel.new()
	_tile.custom_minimum_size = Vector2(Tokens.TILE, Tokens.TILE)
	_tile.size_flags_horizontal = SIZE_SHRINK_CENTER
	col.add_child(_tile)
	var holder := CenterContainer.new()
	holder.size = Vector2(Tokens.TILE, Tokens.TILE)
	_tile.add_child(holder)
	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	holder.add_child(_icon)

	_name = UI.label("", Tokens.sans(500, Tokens.HERO_DESC), Tokens.HERO_DESC, Tokens.MUTED)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_name)

	var dots := HBoxContainer.new()
	dots.alignment = BoxContainer.ALIGNMENT_CENTER
	dots.add_theme_constant_override("separation", Tokens.LOADER_DOT_GAP)
	col.add_child(dots)
	for i in 3:
		var d := Panel.new()
		d.custom_minimum_size = Vector2.ONE * Tokens.LOADER_DOT
		d.add_theme_stylebox_override("panel", UI.box(Tokens.TEXT, Tokens.LOADER_DOT / 2))
		d.modulate.a = Tokens.LOADER_DOT_DIM
		dots.add_child(d)
		_dots.append(d)
