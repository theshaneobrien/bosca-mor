# Launcher preferences from Settings, kept in state.json next to the other
# remembered state (D32): reduce motion, UI scale, controller glyph style.
extends RefCounted

const StateFile := preload("res://scripts/state_file.gd")

const DEFAULTS := {"reduce_motion": false, "ui_scale": 1.0, "glyph_style": "auto"}
const UI_SCALES := [1.0, 0.95, 0.9]           # shrink for TVs that overscan (D33)
const GLYPH_STYLES := ["auto", "xbox", "playstation"]


static func load_prefs(path := "") -> Dictionary:
	var saved := StateFile.load_file(path)
	var out := DEFAULTS.duplicate()
	for k in DEFAULTS:
		if saved.has(k) and typeof(saved[k]) == typeof(DEFAULTS[k]):
			out[k] = saved[k]
	if not out.ui_scale in UI_SCALES:
		out.ui_scale = 1.0
	if not out.glyph_style in GLYPH_STYLES:
		out.glyph_style = "auto"
	return out


static func save(changes: Dictionary, path := "") -> Error:
	return StateFile.update(changes, path)


## The next value in a list of choices, wrapping round.
static func next_in(list: Array, value) -> Variant:
	var i := list.find(value)
	return list[(i + 1) % list.size()]
