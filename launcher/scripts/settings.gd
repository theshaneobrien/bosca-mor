# Settings: a section list on the left and the chosen section on the right.
# Apps edits apps.json (show or hide, reorder, the Browser start page, add
# from installed .desktop entries); Display, Controllers and Startup change
# preferences; Network and Sound open Cinnamon's own panels like an app;
# About shows this device. Navigation per the SPEC table's Settings column:
# Left goes to the section list, Right goes into content, Back goes up one
# level and at the top returns Home.
extends Control

signal closed
signal apps_changed
signal prefs_changed(prefs: Dictionary)
signal launch_panel(app: Dictionary)

const Tokens := preload("res://theme/tokens.gd")
const Glyphs := preload("res://scripts/glyphs.gd")
const UI := preload("res://scripts/ui.gd")
const Apps := preload("res://scripts/apps.gd")
const Prefs := preload("res://scripts/prefs.gd")
const DesktopEntries := preload("res://scripts/desktop_entries.gd")
const Autostart := preload("res://scripts/autostart.gd")
const SystemInfo := preload("res://scripts/system_info.gd")
const HintBar := preload("res://scripts/hint_bar.gd")
const OSK := preload("res://scripts/osk.gd")
const IconResolver := preload("res://scripts/icon_resolver.gd")

const SECTIONS := [
	["apps", "Apps"], ["display", "Display"], ["network", "Network"], ["sound", "Sound"],
	["controllers", "Controllers"], ["startup", "Startup"], ["about", "About"],
]
const HEADS := {
	"apps": ["Apps on Home", "Shown left to right in this order."],
	"picker": ["Add an app", "Apps installed on this device."],
	"display": ["Display", "How the launcher looks on the TV."],
	"network": ["Network", "Wi-Fi and wired connections open in the desktop's own settings."],
	"sound": ["Sound", "Speakers and volume open in the desktop's own settings."],
	"controllers": ["Controllers", "Which button names the hints show for a game pad."],
	"startup": ["Startup", "What happens when this device starts."],
	"about": ["About", "This device and the launcher."],
}
const PANELS := {
	"network": {"id": "network-settings", "name": "Network settings", "argv": ["cinnamon-settings", "network"], "button": "Open network settings"},
	"sound": {"id": "sound-settings", "name": "Sound settings", "argv": ["cinnamon-settings", "sound"], "button": "Open sound settings"},
}
const SCALE_NAMES := {1.0: "100%", 0.95: "95%", 0.9: "90%"}
const GLYPH_NAMES := {"auto": "Automatic", "xbox": "Xbox", "playstation": "PlayStation"}
const ACCENTS := [Tokens.CORAL, Tokens.YELLOW, Tokens.CYAN, Tokens.TEAL]

## Where apps.json is read from and written to. Empty: the user's file
## (read falls back to the bundled default until the first save).
var apps_path := ""
var state_path := ""
var autostart_path := ""
var desktop_dirs: Array = []
var accepting_input := false
## The daemon's last memory warning, for About.
var memory_note := ""

var section := 0
var level := "nav"          # nav, content or picker
var item := 0               # focused content item
var col := 0                # 1: the Browser start page button on an app row
var moving := false
var prefs := {}

var _apps: Array = []       # every valid app, hidden ones too, in file order
var _raw := {}              # id -> entry as written in apps.json
var _invalid := []          # entries that failed to load, kept on save
var _entries: Array = []    # picker: installed apps not yet on Home
var _items: Array = []      # content items for the current level
var _scroll := 0
var _scale := 1.0

var _hints: HBoxContainer
var _nav: VBoxContainer
var _head_title: Label
var _head_sub: Label
var _add: PanelContainer
var _list: VBoxContainer
var _osk: Control


func _ready() -> void:
	size = Tokens.BASE_SIZE
	visible = false
	_build()
	_osk = OSK.new()
	_osk.done.connect(_on_url_done)
	_osk.cancelled.connect(_render)
	add_child(_osk)
	UI.ignore_mouse(self)
	_scale = UI.display_scale(self)


func open() -> void:
	_load_apps()
	prefs = Prefs.load_prefs(state_path)
	section = 0
	level = "nav"
	item = 0
	col = 0
	moving = false
	_scroll = 0
	visible = true
	_render()


func close() -> void:
	visible = false
	_osk.close()


func section_id() -> String:
	return SECTIONS[section][0]


func hint_words() -> Array:
	return _hints.words()


func osk() -> Control:
	return _osk


# Input ------------------------------------------------------------------------

func _unhandled_input(ev: InputEvent) -> void:
	if not accepting_input or not visible:
		return
	if handle(ev):
		get_viewport().set_input_as_handled()


## One input event. True if Settings used it (Menu, Home and Power go on to
## the state machine).
func handle(ev: InputEvent) -> bool:
	if _osk.visible:
		return _osk.handle(ev)
	if ev.is_action_pressed("nav_up", true):
		_step(-1)
	elif ev.is_action_pressed("nav_down", true):
		_step(1)
	elif ev.is_action_pressed("nav_left", true):
		_left()
	elif ev.is_action_pressed("nav_right", true):
		_right()
	elif ev.is_action_pressed("accept"):
		_accept()
	elif ev.is_action_pressed("move"):
		if not _move():
			return false
	elif ev.is_action_pressed("back"):
		_back()
	else:
		return false
	_render()
	return true


func _step(d: int) -> void:
	if moving:
		_shift(d)
	elif level == "nav":
		section = clampi(section + d, 0, SECTIONS.size() - 1)
	elif not _items.is_empty():
		item = clampi(item + d, 0, _items.size() - 1)
		col = 0


func _left() -> void:
	if moving:
		return
	if col == 1:
		col = 0
	elif level == "content":
		level = "nav"


func _right() -> void:
	if moving:
		return
	if level == "nav":
		_enter()
	elif level == "content" and col == 0 and _current().get("type") == "app" and _current().app.url_editable:
		col = 1


func _accept() -> void:
	if moving:
		_drop()
		return
	if level == "nav":
		_enter()
		return
	var it := _current()
	match it.get("type", ""):
		"add":
			_open_picker()
		"app":
			if col == 1:
				_osk.open("Browser start page", it.app.url)
			else:
				_toggle_hidden(it.app.id)
		"toggle", "choice":
			_change(it.key)
		"button":
			launch_panel.emit(PANELS[section_id()])
		"entry":
			_add_app(it.entry)


func _move() -> bool:
	if moving:
		_drop()
		return true
	if level == "content" and _current().get("type") == "app":
		moving = true
		col = 0
		return true
	return false


func _back() -> void:
	if moving:
		_drop()
	elif col == 1:
		col = 0
	elif level == "picker":
		level = "content"
		_build_items()
		item = 0
	elif level == "content":
		level = "nav"
	else:
		closed.emit()


func _enter() -> void:
	level = "content"
	item = 0
	col = 0
	_scroll = 0
	_build_items()
	if section_id() == "apps" and _items.size() > 1:
		item = 1


func _current() -> Dictionary:
	return _items[item] if level != "nav" and item < _items.size() else {}


# Apps -------------------------------------------------------------------------

func _read_path() -> String:
	return apps_path if apps_path else Apps.default_source()


func _write_path() -> String:
	return apps_path if apps_path and not apps_path.begins_with("res://") else Apps.user_path()


func _load_apps() -> void:
	var r := Apps.load_file(_read_path())
	_apps = r.apps
	_raw = r.raw
	_invalid = r.invalid


func _save_apps() -> void:
	var entries := []
	for a in _apps:
		entries.append(_raw[a.id])
	entries.append_array(_invalid)
	var path := _write_path()
	var err := Apps.save_file(path, entries)
	if err != OK:
		push_warning("could not write %s: %s" % [path, error_string(err)])
		return
	if apps_path.is_empty():
		apps_path = path
	_load_apps()
	apps_changed.emit()


func _app_index(id: String) -> int:
	for i in _apps.size():
		if _apps[i].id == id:
			return i
	return -1


func _toggle_hidden(id: String) -> void:
	var raw: Dictionary = _raw[id]
	if raw.get("hidden", false):
		raw.erase("hidden")
	else:
		raw["hidden"] = true
	_save_apps()
	_build_items()


# Move mode swaps the row with its neighbour; the file is written on drop.
func _shift(d: int) -> void:
	var i := item - 1          # item 0 is Add app
	var j := i + d
	if j < 0 or j >= _apps.size():
		return
	var a = _apps[i]
	_apps[i] = _apps[j]
	_apps[j] = a
	item += d
	_build_items()


func _drop() -> void:
	moving = false
	var id: String = _current().app.id
	_save_apps()
	_build_items()
	item = _app_index(id) + 1


func _on_url_done(text: String) -> void:
	var url := text.strip_edges()
	if url.is_empty():
		_render()
		return
	if not url.contains("://"):
		url = "https://" + url
	_raw[_current().app.id]["url"] = url
	_save_apps()
	_build_items()
	_render()


func _open_picker() -> void:
	var have := {}
	for a in _apps:
		have[" ".join(a.argv)] = true
	_entries = DesktopEntries.scan(desktop_dirs).filter(func(e): return not have.has(" ".join(e.argv)))
	level = "picker"
	item = 0
	_scroll = 0
	_build_items()


func _add_app(e: Dictionary) -> void:
	var accent: Color = ACCENTS[_apps.size() % ACCENTS.size()]
	var id := DesktopEntries.id_for(e.file, _raw)
	_raw[id] = {
		"id": id, "name": e.name, "kind": e.kind,
		"description": e.comment if e.comment else "Added from the app menu",
		"tint": "#" + Tokens.TILE_TINTS["#" + accent.to_html(false)].to_html(false),
		"accent": "#" + accent.to_html(false),
		"argv": e.argv,
	}
	_apps.append({"id": id})   # placeholder until the reload
	_save_apps()
	level = "content"
	_build_items()
	item = _items.size() - 1


# Preferences ------------------------------------------------------------------

func _change(key: String) -> void:
	match key:
		"reduce_motion": prefs.reduce_motion = not prefs.reduce_motion
		"ui_scale": prefs.ui_scale = Prefs.next_in(Prefs.UI_SCALES, prefs.ui_scale)
		"glyph_style": prefs.glyph_style = Prefs.next_in(Prefs.GLYPH_STYLES, prefs.glyph_style)
		"autostart":
			Autostart.set_enabled(not Autostart.enabled(autostart_path), autostart_path)
			_build_items()
			return
	Prefs.save({key: prefs[key]}, state_path)
	prefs_changed.emit(prefs)
	_build_items()


# Content model ----------------------------------------------------------------

func _build_items() -> void:
	_items = []
	if level == "picker":
		for e in _entries:
			_items.append({"type": "entry", "entry": e})
		return
	match section_id():
		"apps":
			_items.append({"type": "add"})
			for a in _apps:
				_items.append({"type": "app", "app": a})
		"display":
			_items.append({"type": "choice", "key": "ui_scale", "label": "Screen size", "value": SCALE_NAMES.get(prefs.ui_scale, "100%")})
			_items.append({"type": "toggle", "key": "reduce_motion", "label": "Reduce motion", "on": prefs.reduce_motion})
		"network", "sound":
			_items.append({"type": "button", "label": PANELS[section_id()].button})
		"controllers":
			_items.append({"type": "choice", "key": "glyph_style", "label": "Button names", "value": GLYPH_NAMES[prefs.glyph_style]})
		"startup":
			if Autostart.installed(autostart_path):
				_items.append({"type": "toggle", "key": "autostart", "label": "Open the launcher at login", "on": Autostart.enabled(autostart_path)})
			else:
				_items.append({"type": "info", "label": "Open the launcher at login", "value": "Not set up on this device"})
		"about":
			_items.append({"type": "info", "label": "Version", "value": SystemInfo.version()})
			_items.append({"type": "info", "label": "Device name", "value": SystemInfo.hostname()})
			_items.append({"type": "info", "label": "IP address", "value": SystemInfo.ip_addresses()})
			var mem := SystemInfo.memory()
			_items.append({"type": "info", "label": "Memory", "value": "%s%sLauncher %d MB" % [mem, ", " if mem else "", SystemInfo.launcher_memory_mb()]})
			var session := SystemInfo.session_type()
			var warn := OS.get_name() == "Linux" and session != "x11"
			_items.append({"type": "info", "label": "Session", "value": "%s, window handling needs X11" % session if warn else session, "warn": warn})
			if memory_note:
				_items.append({"type": "info", "label": "Last memory warning", "value": memory_note, "warn": true})


# Build ------------------------------------------------------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Tokens.BG
	bg.size = Tokens.BASE_SIZE
	add_child(bg)

	var root := VBoxContainer.new()
	root.position = Vector2(Tokens.PAD_X, Tokens.PAD_TOP)
	root.size = Vector2(Tokens.BASE_SIZE.x - 2 * Tokens.PAD_X, Tokens.BASE_SIZE.y - Tokens.PAD_TOP - Tokens.PAD_BOTTOM)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var title_font := Tokens.sans(700, Tokens.SETTINGS_TITLE, Tokens.TRACK_TITLE)
	var hang := UI.overhang(title_font, Tokens.SETTINGS_TITLE, Tokens.SETTINGS_TITLE)
	var header := HBoxContainer.new()
	var title := UI.label("Settings", title_font, Tokens.SETTINGS_TITLE, Tokens.TEXT)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	_hints = HintBar.new([["accept", "Open"], ["back", "Back"]], Tokens.SIDEBAR_HINT, Tokens.SETTINGS_HINT_GAP, Tokens.SIDEBAR_HINT_KEY_GAP)
	_hints.size_flags_vertical = SIZE_SHRINK_CENTER
	header.add_child(_hints)
	# The title is set solid; pull the header up by its overhang.
	var head_wrap := MarginContainer.new()
	head_wrap.add_theme_constant_override("margin_top", -int(round(hang)))
	head_wrap.add_theme_constant_override("margin_bottom", -int(round(hang)))
	head_wrap.add_child(header)
	root.add_child(head_wrap)
	root.add_child(UI.spacer(Tokens.SETTINGS_BODY_GAP))

	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Tokens.SETTINGS_COL_GAP)
	root.add_child(body)

	_nav = VBoxContainer.new()
	_nav.custom_minimum_size.x = Tokens.NAV_WIDTH
	_nav.add_theme_constant_override("separation", Tokens.NAV_ITEM_GAP)
	body.add_child(_nav)
	for s in SECTIONS:
		var p := PanelContainer.new()
		p.custom_minimum_size.y = Tokens.NAV_ITEM
		var l := UI.label(s[1], Tokens.sans(500, Tokens.NAV_ITEM_FONT), Tokens.NAV_ITEM_FONT, Tokens.STATUS)
		l.name = "Label"
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p.add_child(l)
		_nav.add_child(p)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 0)
	body.add_child(content)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Tokens.LIST_TOP)
	content.add_child(head)
	var head_text := VBoxContainer.new()
	head_text.size_flags_horizontal = SIZE_EXPAND_FILL
	head_text.add_theme_constant_override("separation", 0)
	head.add_child(head_text)
	var h2 := Tokens.sans(700, Tokens.SECTION_TITLE)
	var h2_hang := UI.overhang(h2, Tokens.SECTION_TITLE, Tokens.SECTION_TITLE * Tokens.SECTION_TITLE_LINE)
	_head_title = UI.label("", h2, Tokens.SECTION_TITLE, Tokens.TEXT)
	var t_wrap := MarginContainer.new()
	t_wrap.add_theme_constant_override("margin_top", -int(round(h2_hang)))
	t_wrap.add_theme_constant_override("margin_bottom", -int(round(h2_hang)))
	t_wrap.add_child(_head_title)
	head_text.add_child(t_wrap)
	head_text.add_child(UI.spacer(Tokens.SECTION_SUB_GAP))
	_head_sub = UI.label("", Tokens.sans(400, Tokens.SECTION_SUB), Tokens.SECTION_SUB, Tokens.MUTED)
	head_text.add_child(_head_sub)

	_add = PanelContainer.new()
	_add.custom_minimum_size.y = Tokens.ADD_BUTTON
	_add.size_flags_vertical = SIZE_SHRINK_END
	var add_row := HBoxContainer.new()
	add_row.name = "Row"
	add_row.add_theme_constant_override("separation", Tokens.ADD_ICON_GAP)
	var plus := TextureRect.new()
	plus.name = "Icon"
	plus.custom_minimum_size = Vector2(Tokens.ADD_ICON, Tokens.ADD_ICON)
	plus.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plus.size_flags_vertical = SIZE_SHRINK_CENTER
	add_row.add_child(plus)
	var add_l := UI.label("Add app", Tokens.sans(500, Tokens.SECTION_SUB), Tokens.SECTION_SUB, Tokens.TEXT)
	add_l.name = "Label"
	add_l.size_flags_vertical = SIZE_SHRINK_CENTER
	add_row.add_child(add_l)
	_add.add_child(add_row)
	head.add_child(_add)

	content.add_child(UI.spacer(Tokens.LIST_TOP))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", Tokens.ROW_GAP)
	content.add_child(_list)


## Rows that fit below the section heading.
func _visible_rows() -> int:
	var head := Tokens.SECTION_TITLE * Tokens.SECTION_TITLE_LINE + Tokens.SECTION_SUB_GAP \
		+ Tokens.sans(400, Tokens.SECTION_SUB).get_height(Tokens.SECTION_SUB)
	var avail := Tokens.BASE_SIZE.y - Tokens.PAD_TOP - Tokens.PAD_BOTTOM - Tokens.SETTINGS_TITLE \
		- Tokens.SETTINGS_BODY_GAP - head - Tokens.LIST_TOP
	return int((avail + Tokens.ROW_GAP) / (Tokens.ROW + Tokens.ROW_GAP))


func _render() -> void:
	if _items.is_empty() and level != "nav":
		_build_items()
	if level == "nav":
		_build_items()
	for i in _nav.get_child_count():
		# The current section stays filled, as in the design, wherever focus is.
		var on := i == section
		var strong := on
		var p: PanelContainer = _nav.get_child(i)
		var sb := UI.box(Tokens.TEXT if strong else Color(Tokens.TEXT, 0.0), Tokens.MENU_ITEM_RADIUS)
		sb.content_margin_left = Tokens.NAV_ITEM_PAD
		sb.content_margin_right = Tokens.NAV_ITEM_PAD
		p.add_theme_stylebox_override("panel", sb)
		var l: Label = p.get_node("Label")
		l.add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.NAV_ITEM_FONT))
		l.add_theme_color_override("font_color", Tokens.BG if strong else (Tokens.TEXT if on else Tokens.STATUS))

	var head: Array = HEADS["picker" if level == "picker" else section_id()]
	_head_title.text = head[0]
	_head_sub.text = head[1]
	var show_add := level != "picker" and section_id() == "apps"
	_add.visible = show_add
	if show_add:
		_style_add(level == "content" and item == 0)

	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var rows := _visible_rows()
	var first := 1 if show_add else 0     # Add app sits in the heading, not the list
	var listed := _items.size() - first
	var focus_row := item - first
	if level != "nav" and focus_row >= 0:
		if focus_row < _scroll:
			_scroll = focus_row
		elif focus_row >= _scroll + rows:
			_scroll = focus_row - rows + 1
	_scroll = clampi(_scroll, 0, maxi(listed - rows, 0))
	for i in range(first + _scroll, mini(_items.size(), first + _scroll + rows)):
		_list.add_child(_row(_items[i], level != "nav" and i == item))
	UI.ignore_mouse(_list)
	_hints.set_hints(_hint_pairs())


func _hint_pairs() -> Array:
	if _osk.visible:
		return [["accept", "Press"], ["back", "Cancel"]]
	if moving:
		return [["move", "Put it here"]]
	if level == "nav":
		return [["accept", "Open"], ["back", "Back"]]
	match _current().get("type", ""):
		"app":
			if col == 1:
				return [["accept", "Edit"], ["back", "Back"]]
			return [["accept", "Show or hide"], ["move", "Move"], ["back", "Back"]]
		"add":
			return [["accept", "Add app"], ["back", "Back"]]
		"entry":
			return [["accept", "Add"], ["back", "Back"]]
		"toggle", "choice":
			return [["accept", "Change"], ["back", "Back"]]
		"button":
			return [["accept", "Open"], ["back", "Back"]]
	return [["back", "Back"]]


func _style_add(on: bool) -> void:
	var sb := UI.box(Tokens.TEXT if on else Color(Tokens.TEXT, 0.0), Tokens.ADD_BUTTON_RADIUS)
	if not on:
		sb.border_color = Tokens.BUTTON_BORDER
		sb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
	sb.content_margin_left = Tokens.ADD_BUTTON_PAD
	sb.content_margin_right = Tokens.ADD_BUTTON_PAD
	_add.add_theme_stylebox_override("panel", sb)
	var color := Tokens.BG if on else Tokens.TEXT
	_add.get_node("Row/Label").add_theme_color_override("font_color", color)
	_add.get_node("Row/Label").add_theme_font_override("font", Tokens.sans(700 if on else 500, Tokens.SECTION_SUB))
	_add.get_node("Row/Icon").texture = Glyphs.texture("plus", color, Tokens.ADD_ICON, Tokens.ADD_ICON_STROKE, _scale)


func _row(it: Dictionary, on: bool) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size.y = Tokens.ROW
	var ring_on: bool = on and not (it.type == "app" and col == 1)
	var sb := UI.box(Tokens.ROW_FOCUS_BG if on else Color(Tokens.BG, 0.0), Tokens.ROW_RADIUS)
	if ring_on:
		sb.border_color = Tokens.TEAL if moving else Tokens.TEXT
		sb.set_border_width_all(Tokens.ROW_RING)
	sb.content_margin_left = Tokens.ROW_PAD_LEFT
	sb.content_margin_right = Tokens.ROW_PAD_RIGHT
	p.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.ROW_SPACING)
	p.add_child(row)

	match it.type:
		"app":
			var app: Dictionary = it.app
			row.add_child(_icon("grip", Tokens.GRIP, Tokens.GRIP_ICON, Tokens.STATUS_STROKE))
			var tile := PanelContainer.new()
			tile.custom_minimum_size = Vector2(Tokens.ROW_TILE, Tokens.ROW_TILE)
			tile.size_flags_vertical = SIZE_SHRINK_CENTER
			tile.add_theme_stylebox_override("panel", UI.box(app.tint, Tokens.ROW_TILE_RADIUS))
			var found := IconResolver.find(app)
			var g: TextureRect
			if found:
				g = _icon("apps", app.accent, Tokens.ROW_GLYPH, Tokens.ROW_GLYPH_STROKE)
				g.texture = IconResolver.texture(found.path, roundi(Tokens.ROW_TILE * Tokens.ICON_INSET * _scale), app.id + "-row")
				g.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			else:
				g = _icon(Glyphs.name_for(app), app.accent, Tokens.ROW_GLYPH, Tokens.ROW_GLYPH_STROKE)
			g.size_flags_horizontal = SIZE_SHRINK_CENTER
			tile.add_child(g)
			row.add_child(tile)
			var title := UI.label(app.name, Tokens.sans(500, Tokens.ROW_FONT), Tokens.ROW_FONT, Tokens.DIM if app.hidden else Tokens.TEXT)
			title.size_flags_horizontal = SIZE_EXPAND_FILL
			title.size_flags_vertical = SIZE_SHRINK_CENTER
			row.add_child(title)
			# Where the logo came from; the built-in glyph speaks for itself (D42).
			if found:
				var src := UI.label(IconResolver.source_label(found.source), Tokens.mono(400, Tokens.URL_FONT), Tokens.URL_FONT, Tokens.DIM)
				src.size_flags_vertical = SIZE_SHRINK_CENTER
				row.add_child(src)
			if app.url_editable:
				row.add_child(_url_button(app.url, on and col == 1))
			row.add_child(_kind(app.kind))
			row.add_child(_toggle(not app.hidden))
		"entry":
			var e: Dictionary = it.entry
			var n := UI.label(e.name, Tokens.sans(500, Tokens.ROW_FONT), Tokens.ROW_FONT, Tokens.TEXT)
			n.size_flags_horizontal = SIZE_EXPAND_FILL
			n.size_flags_vertical = SIZE_SHRINK_CENTER
			row.add_child(n)
			row.add_child(_kind(e.kind))
		_:
			var l := UI.label(it.label, Tokens.sans(500, Tokens.ROW_FONT), Tokens.ROW_FONT, Tokens.TEXT)
			l.size_flags_horizontal = SIZE_EXPAND_FILL
			l.size_flags_vertical = SIZE_SHRINK_CENTER
			row.add_child(l)
			match it.type:
				"toggle":
					row.add_child(_toggle(it.on))
				"choice", "info":
					var v := UI.label(it.value, Tokens.mono(400, Tokens.KIND_FONT), Tokens.KIND_FONT, Tokens.CORAL if it.get("warn", false) else Tokens.MUTED)
					v.size_flags_vertical = SIZE_SHRINK_CENTER
					row.add_child(v)
	return p


func _icon(glyph: String, color: Color, px: int, stroke: float) -> TextureRect:
	var t := TextureRect.new()
	t.custom_minimum_size = Vector2(px, px)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.size_flags_vertical = SIZE_SHRINK_CENTER
	t.texture = Glyphs.texture(glyph, color, px, stroke, _scale)
	return t


func _kind(kind: String) -> Label:
	var k := UI.label(kind.to_upper(), Tokens.mono(400, Tokens.KIND_FONT, Tokens.TRACK_KIND), Tokens.KIND_FONT, Tokens.MUTED)
	k.size_flags_vertical = SIZE_SHRINK_CENTER
	return k


func _url_button(url: String, on: bool) -> Control:
	var b := PanelContainer.new()
	b.custom_minimum_size.y = Tokens.URL_BUTTON
	b.size_flags_vertical = SIZE_SHRINK_CENTER
	var sb := UI.box(Tokens.TEXT if on else Color(Tokens.TEXT, 0.0), Tokens.URL_RADIUS)
	if not on:
		sb.border_color = Tokens.BUTTON_BORDER
		sb.set_border_width_all(Tokens.BUTTON_BORDER_WIDTH)
	sb.content_margin_left = Tokens.URL_PAD
	sb.content_margin_right = Tokens.URL_PAD
	b.add_theme_stylebox_override("panel", sb)
	var shown := url.trim_prefix("https://").trim_prefix("http://").trim_prefix("www.").trim_suffix("/")
	var l := UI.label("Start page: " + shown, Tokens.mono(400, Tokens.URL_FONT), Tokens.URL_FONT, Tokens.BG if on else Tokens.STATUS)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_child(l)
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_right", Tokens.URL_GAP - Tokens.ROW_SPACING)
	wrap.size_flags_vertical = SIZE_SHRINK_CENTER
	wrap.add_child(b)
	return wrap


func _toggle(on: bool) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", Tokens.TOGGLE_GAP - Tokens.ROW_SPACING)
	wrap.size_flags_vertical = SIZE_SHRINK_CENTER
	var track := PanelContainer.new()
	track.custom_minimum_size = Vector2(Tokens.TOGGLE_W, Tokens.TOGGLE_H)
	var sb := UI.box(Tokens.TEAL if on else Tokens.KEY_BG, Tokens.TOGGLE_H / 2)
	sb.set_content_margin_all(Tokens.TOGGLE_PAD)
	track.add_theme_stylebox_override("panel", sb)
	var knob := Panel.new()
	knob.custom_minimum_size = Vector2(Tokens.TOGGLE_KNOB, Tokens.TOGGLE_KNOB)
	knob.size_flags_horizontal = SIZE_SHRINK_END if on else SIZE_SHRINK_BEGIN
	knob.size_flags_vertical = SIZE_SHRINK_CENTER
	knob.add_theme_stylebox_override("panel", UI.box(Tokens.BG if on else Tokens.MUTED, Tokens.TOGGLE_KNOB / 2))
	track.add_child(knob)
	wrap.add_child(track)
	return wrap
