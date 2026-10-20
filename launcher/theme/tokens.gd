# Every colour, size, font and timing the launcher uses. Values come from the
# SPEC token and motion tables; layout values marked "design" come from
# docs/design/Main.dc.html (see DECISIONS D14). Nothing is hard-coded elsewhere.
extends RefCounted

# Base canvas
const BASE_SIZE := Vector2i(1920, 1080)

# Colours
const BG := Color("#0c0c14")
const SURFACE := Color("#13131e")
const BORDER := Color("#262638")
const TEXT := Color("#f2f2f7")
const MUTED := Color("#a3a3b8")
const DIM := Color("#8e8ea6")
const RING := Color("#f2f2f7")
const CORAL := Color("#ff7a6b")
const YELLOW := Color("#ffc94d")
const CYAN := Color("#5fdcea")
const TEAL := Color("#3cc4a8")
const STATUS := Color("#d6d6e0")    # design: top bar icon and date
const KEY_BG := Color("#2a2a3c")    # design: hint key pill
const BLACK := Color("#000000")     # SPEC motion: launch fades to black

# Focus ring: gap in BG colour, then the ring
const RING_GAP := 6
const RING_WIDTH := 5

# Tiles
const TILE := 260
const TILE_RADIUS := 30
const TILE_GAP := 40
const TILE_FOCUS_SCALE := 1.12
const TILE_LABEL_GAP := 28          # design
const GLYPH := 112                  # design
const GLYPH_STROKE := 1.6           # design
const CAROUSEL_LEAD := 3            # design: row shifts once focus passes the fourth tile

# Type sizes
const HERO_NAME := 120
const HERO_DESC := 38
const TILE_LABEL := 30
const HINT := 28
const HERO_KIND := 26               # design
const TOPBAR_LABEL := 24            # design
const TOPBAR_DATE := 26             # design
const TOPBAR_CLOCK := 34            # design
const KEY_FONT := 21                # design

# Letter spacing, in em (design)
const TRACK_LABEL := 0.14
const TRACK_HERO := -0.025

# Screen layout (design)
const PAD_X := 120
const PAD_TOP := 56
const PAD_BOTTOM := 52
const TOPBAR_GAP := 32
const STATUS_ICON := 32
const STATUS_STROKE := 2.0
const HERO_KIND_GAP := 18
const HERO_DESC_GAP := 22
const ROW_HEIGHT := 420
const ROW_TOP := 60
const HINT_GAP := 48
const HINT_KEY_GAP := 14
const KEY := 46
const KEY_PAD_KEYBOARD := 16

# Sidebar (design)
const SCRIM := Color("#06060a")     # dim colour behind the sidebar and confirm
const SIDEBAR_PAD_TOP := 64
const SIDEBAR_PAD_X := 40
const SIDEBAR_PAD_BOTTOM := 52
const SIDEBAR_INSET := 24           # clock, items and footer inner padding
const SIDEBAR_CLOCK := 76
const SIDEBAR_DATE := 28
const SIDEBAR_DATE_GAP := 14
const SIDEBAR_ITEMS_GAP := 72
const MENU_ITEM := 88
const MENU_ITEM_RADIUS := 18
const MENU_ITEM_FONT := 32
const MENU_ITEM_GAP := 8
const MENU_ICON := 36
const MENU_ICON_GAP := 24
const MENU_DIVIDER_PAD := 24
const SIDEBAR_FOOTER_GAP := 40      # above the footer, and between its hints
const SIDEBAR_HINT := 26
const SIDEBAR_HINT_KEY_GAP := 12
const BLUR_RADIUS := 3.0            # in quarter-size texels (D22)

# Power confirm (design)
const CONFIRM_DIM := 0.82
const DIALOG_BG := Color("#161622")
const DIALOG_BORDER := Color("#2a2a40")
const BUTTON_BORDER := Color("#3a3a52")
const DIALOG_WIDTH := 840
const DIALOG_PAD_TOP := 72
const DIALOG_PAD := 64
const DIALOG_RADIUS := 36
const DIALOG_ICON := 80
const DIALOG_TITLE := 60
const DIALOG_TITLE_LINE := 1.1
const DIALOG_TITLE_GAP := 36
const DIALOG_BODY := 32
const DIALOG_BODY_GAP := 18
const DIALOG_BUTTONS_GAP := 60
const BUTTON := 100
const BUTTON_RADIUS := 22
const BUTTON_FONT := 34
const BUTTON_GAP := 24
const BUTTON_BORDER_WIDTH := 2

# Power-off screen (design)
const OFF_TEXT := 32

# Settings (design: Settings.dc.html)
const SETTINGS_TITLE := 60
const TRACK_TITLE := -0.02
const SETTINGS_HINT_GAP := 44
const SETTINGS_BODY_GAP := 48
const SETTINGS_COL_GAP := 64
const NAV_WIDTH := 400
const NAV_ITEM := 76
const NAV_ITEM_GAP := 6
const NAV_ITEM_PAD := 28
const NAV_ITEM_FONT := 30
const SECTION_TITLE := 44
const SECTION_TITLE_LINE := 1.1
const SECTION_SUB := 28
const SECTION_SUB_GAP := 10
const ADD_BUTTON := 72
const ADD_BUTTON_PAD := 32
const ADD_BUTTON_RADIUS := 18
const ADD_ICON := 28
const ADD_ICON_GAP := 14
const ADD_ICON_STROKE := 2.2
const LIST_TOP := 32
const ROW := 64
const ROW_GAP := 4
const ROW_PAD_LEFT := 20
const ROW_PAD_RIGHT := 28
const ROW_RADIUS := 16
const ROW_SPACING := 24
const ROW_RING := 3
const ROW_FOCUS_BG := Color("#1c1c2a")
const GRIP := Color("#6c6c86")
const GRIP_ICON := 28
const ROW_TILE := 46
const ROW_TILE_RADIUS := 12
const ROW_GLYPH := 32
const ROW_GLYPH_STROKE := 1.8
const ROW_FONT := 28
const URL_BUTTON := 44
const URL_PAD := 18
const URL_RADIUS := 12
const URL_FONT := 20
const URL_GAP := 16
const KIND_FONT := 22
const TRACK_KIND := 0.1
const TOGGLE_W := 76
const TOGGLE_H := 42
const TOGGLE_PAD := 5
const TOGGLE_KNOB := 32
const TOGGLE_GAP := 24
const TILE_TINTS := {               # the default set's tint for each accent, for added apps
	"#ff7a6b": Color("#2d1719"),
	"#ffc94d": Color("#2b2513"),
	"#5fdcea": Color("#10262b"),
	"#3cc4a8": Color("#0f2622"),
}

# On-screen keyboard (D34: no design; built from the dialog and row tokens)
const OSK_KEY := 84
const OSK_KEY_H := 72
const OSK_KEY_GAP := 10
const OSK_FONT := 30
const OSK_FIELD := 80

# Motion: seconds
const T_TILE_FOCUS := 0.160
const T_CAROUSEL := 0.220
const T_HERO := 0.180
const T_SIDEBAR_OPEN := 0.240
const T_SIDEBAR_CLOSE := 0.180
const T_CONFIRM := 0.200
const T_LAUNCH := 0.350
const T_RETURN := 0.250
const T_BUMP := 0.160
const HERO_RISE := 12
const BUMP := 12
const LAUNCH_SCALE := 1.3
const SIDEBAR_WIDTH := 560
const SIDEBAR_DIM := 0.74
const SIDEBAR_HOME_SCALE := 0.96
const CONFIRM_SCALE_FROM := 0.96
const REPEAT_DELAY := 0.400
const REPEAT_RATE := 0.110
const LAUNCH_TIMEOUT := 15.0

# Input (SPEC Input model)
const STICK_DEADZONE := 0.5
const POINTER_MOVE := 40.0          # px within POINTER_WINDOW to enter pointer mode
const POINTER_WINDOW := 0.250
const POINTER_HIDE := 3.0           # cursor hides after this long still
const HOVER_DWELL := 0.120

# Resource use (SPEC)
const WIFI_POLL := 30.0
const HIDDEN_SLEEP_USEC := 100000   # low processor sleep while hidden: about 10 wakeups a second

# Fonts. DM Sans comes as static optical-size instances (24pt and 40pt):
# MSDF can't draw the variable font's overlapping contours cleanly.
const SANS_OPSZ_SPLIT := 32         # sizes from here up use the 40pt cut
const SANS_PATHS := {
	24: {400: "res://assets/fonts/DMSans24pt-Regular.ttf", 500: "res://assets/fonts/DMSans24pt-Medium.ttf", 700: "res://assets/fonts/DMSans24pt-Bold.ttf"},
	40: {400: "res://assets/fonts/DMSans40pt-Regular.ttf", 500: "res://assets/fonts/DMSans40pt-Medium.ttf", 700: "res://assets/fonts/DMSans40pt-Bold.ttf"},
}
const MONO_PATHS := {
	400: "res://assets/fonts/DMMono-Regular.ttf",
	500: "res://assets/fonts/DMMono-Medium.ttf",
}

static var _fonts := {}


# DM Sans at 400, 500 or 700. The optical size follows the pixel size the way a
# browser's font-optical-sizing does, so pass the size it is drawn at.
static func sans(weight: int, size: int, track_em := 0.0) -> Font:
	var opsz := 40 if size >= SANS_OPSZ_SPLIT else 24
	return _font(SANS_PATHS[opsz][weight], size, track_em)


# DM Mono at 400 or 500.
static func mono(weight: int, size: int, track_em := 0.0) -> Font:
	return _font(MONO_PATHS[weight], size, track_em)


static func _font(path: String, size: int, track_em: float) -> Font:
	var spacing := roundi(track_em * size)
	if spacing == 0:
		return load(path)
	var key := "%s/%d" % [path, spacing]
	if not _fonts.has(key):
		var f := FontVariation.new()
		f.base_font = load(path)
		f.spacing_glyph = spacing
		_fonts[key] = f
	return _fonts[key]
