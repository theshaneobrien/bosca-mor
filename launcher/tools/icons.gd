# Renders assets/icon/launcher.svg to the PNG sizes the desktop uses
# (hicolor app icons) and the window icon. Run after changing the SVG:
# godot --headless --path launcher -s res://tools/icons.gd
extends SceneTree

const SRC := "res://assets/icon/launcher.svg"
const SIZES := [16, 24, 32, 48, 64, 128, 256]


func _initialize() -> void:
	var svg := FileAccess.get_file_as_string(SRC)
	var failed := 0
	for px in SIZES:
		var img := Image.new()
		if img.load_svg_from_string(svg, px / 256.0) != OK:
			failed += 1
			continue
		var out := "res://assets/icon/launcher-%d.png" % px
		if img.save_png(ProjectSettings.globalize_path(out)) != OK:
			failed += 1
		else:
			print("wrote %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	quit(failed)
