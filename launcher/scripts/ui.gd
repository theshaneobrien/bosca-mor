# Small builders shared by the screens.
extends RefCounted


static func label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func box(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	return sb


static func spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = maxf(h, 0.0)
	return c


## How far a label's box overhangs a line set at `line_px` (CSS line-height),
## on each side. Take it out of the gaps above and below.
static func overhang(font: Font, size: int, line_px: float) -> float:
	return (font.get_height(size) - line_px) / 2.0


## Device pixels per canvas pixel for the viewport `n` draws in.
static func display_scale(n: CanvasItem) -> float:
	var s := n.get_viewport().get_final_transform().get_scale().y
	return s if s > 0.0 else 1.0


## Screens hit-test the pointer themselves, so no Control eats mouse events.
static func ignore_mouse(n: Node) -> void:
	if n is Control:
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		ignore_mouse(c)
