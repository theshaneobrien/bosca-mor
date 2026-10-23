# Launcher preferences from Settings, kept in state.json next to the other
# remembered state (D32): reduce motion, UI scale, controller glyph style,
# and the TV picture, sound output and start volume (D79, D80).
extends RefCounted

const StateFile := preload("res://scripts/state_file.gd")
const Display := preload("res://scripts/display.gd")
const Sound := preload("res://scripts/sound.gd")

const DEFAULTS := {"reduce_motion": false, "ui_scale": 1.0, "glyph_style": "auto",
	"display_mode": "1920x1080@60", "sound_output": "hdmi", "volume": 100}
const UI_SCALES := [1.0, 0.95, 0.9]           # shrink for TVs that overscan (D33)
const GLYPH_STYLES := ["auto", "xbox", "playstation"]


static func load_prefs(path := "") -> Dictionary:
	var saved := StateFile.load_file(path)
	var out := DEFAULTS.duplicate()
	for k in DEFAULTS:
		if saved.has(k) and typeof(saved[k]) == typeof(DEFAULTS[k]):
			out[k] = saved[k]
	if saved.get("volume") is float:     # JSON numbers come back as floats
		out.volume = int(saved.volume)
	if not out.ui_scale in UI_SCALES:
		out.ui_scale = 1.0
	if not out.glyph_style in GLYPH_STYLES:
		out.glyph_style = "auto"
	if not out.display_mode in Display.MODES:
		out.display_mode = DEFAULTS.display_mode
	if not out.sound_output in Sound.OUTPUTS:
		out.sound_output = DEFAULTS.sound_output
	if not out.volume in Sound.VOLUMES:
		out.volume = DEFAULTS.volume
	return out


static func save(changes: Dictionary, path := "") -> Error:
	return StateFile.update(changes, path)


## The next value in a list of choices, wrapping round.
static func next_in(list: Array, value) -> Variant:
	var i := list.find(value)
	return list[(i + 1) % list.size()]
