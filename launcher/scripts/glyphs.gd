# Built-in line glyphs (24x24 stroke paths, from the design canvas), drawn in
# the app's accent when it has no icon. Rasterised at the display scale.
extends RefCounted

const PATHS := {
	"play-box": "M3 6.5A2.5 2.5 0 0 1 5.5 4h13A2.5 2.5 0 0 1 21 6.5v11a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5zM10 9l5 3-5 3z",
	"chevron": "M9 5l8 7-8 7",
	"film": "M4 4h16v16H4zM8 4v16M16 4v16M4 9h4M4 15h4M16 9h4M16 15h4",
	"tv": "M4 10h16v10H4zM4 10l1.5-5.5h15L19 10M9.5 4.5L8 10M15 4.5L13.5 10",
	"play-circle": "M12 21a9 9 0 1 0 0-18a9 9 0 1 0 0 18M10 8.5l5 3.5-5 3.5z",
	"globe": "M12 21a9 9 0 1 0 0-18a9 9 0 1 0 0 18M3 12h18M12 3c2.5 2.5 3.5 5.5 3.5 9s-1 6.5-3.5 9c-2.5-2.5-3.5-5.5-3.5-9s1-6.5 3.5-9",
	"music": "M9 18V6l10-2v12M9 18a3 3 0 1 1-6 0a3 3 0 1 1 6 0M19 16a3 3 0 1 1-6 0a3 3 0 1 1 6 0",
	"speaker": "M6 3h12v18H6zM12 17a3 3 0 1 0 0-6a3 3 0 1 0 0 6M11 7h2",
	"stream": "M3 4h18v12H3zM8 20h8M12 16v4M10 7.5l4.5 2.5-4.5 2.5z",
	"gamepad": "M6 8h12a4 4 0 0 1 4 4v1a4 4 0 0 1-7 2.6L14 15h-4l-1 .6A4 4 0 0 1 2 13v-1a4 4 0 0 1 4-4zM7 10.5v3M5.5 12h3M16 11h.01M18 13h.01",
	"apps": "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
	"home": "M3 11l9-8 9 8M5 9.5V21h5v-6h4v6h5V9.5",
	"settings": "M12 15a3 3 0 1 0 0-6a3 3 0 1 0 0 6M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9L7 7M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1",
	"desktop": "M3 4h18v12H3zM8 20h8M12 16v4",
	"restart": "M3 12a9 9 0 1 0 9-9a9.75 9.75 0 0 0-6.74 2.74L3 8M3 3v5h5",
	"power": "M12 2v10M18.4 6.6a9 9 0 1 1-12.77.04",
	"ps-cross": "M6 6l12 12M18 6L6 18",
	"ps-triangle": "M12 4.5l8 14H4z",
	"close": "M6 6l12 12M18 6L6 18",
	"plus": "M12 5v14M5 12h14",
	"grip": "M5 9h14M5 15h14",
	"ps-circle": "M12 20a8 8 0 1 0 0-16a8 8 0 1 0 0 16",
	"wifi-off": "M2 9a14 14 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 19.5h.01M3 3l18 18",
	"wifi": "M2 9a14 14 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 19.5h.01",
}

# Glyph for each default app, used when apps.json names none.
const BY_ID := {
	"youtube": "play-box",
	"plex": "chevron",
	"jellyfin": "film",
	"netflix": "tv",
	"prime": "play-circle",
	"browser": "globe",
	"spotify": "music",
	"alarismusic": "speaker",
	"moonlight": "stream",
	"retroarch": "gamepad",
}

const FALLBACK := "apps"


static func name_for(app: Dictionary) -> String:
	var g: String = app.get("glyph", "")
	if PATHS.has(g):
		return g
	return BY_ID.get(app.get("id", ""), FALLBACK)


# A texture `size` logical px square, rendered at `scale` device px per px.
static func texture(glyph: String, color: Color, size: int, stroke: float, scale: float) -> Texture2D:
	var svg := (
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 24 24" fill="none" stroke="#%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"><path d="%s"/></svg>'
		% [size, size, color.to_html(false), stroke, PATHS.get(glyph, PATHS[FALLBACK])]
	)
	var img := Image.new()
	if img.load_svg_from_string(svg, maxf(scale, 0.25)) != OK:
		return null
	return ImageTexture.create_from_image(img)
