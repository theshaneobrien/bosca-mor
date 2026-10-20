# The screen state machine. The navigation table from SPEC "Screens and
# navigation" is the TABLE below; Home's own moves and launches stay in Home.
# The Settings column arrives with the Settings screen in step 7.
extends RefCounted

enum Screen { HOME, SIDEBAR, CONFIRM, DESKTOP, OFF }

const ITEMS := ["home", "settings", "desktop", "restart", "poweroff"]
const ACTIONS := ["nav_left", "nav_right", "nav_up", "nav_down", "accept", "back", "menu", "home", "power"]

# screen -> action -> step. "" consumes the action and does nothing; an
# action that is missing is left for the screen itself (Home's moves).
const TABLE := {
	Screen.HOME: {
		"nav_up": "", "nav_down": "",
		"back": "open_sidebar", "menu": "open_sidebar", "home": "", "power": "ask_poweroff",
	},
	Screen.SIDEBAR: {
		"nav_left": "", "nav_right": "", "nav_up": "sidebar_up", "nav_down": "sidebar_down",
		"accept": "sidebar_run", "back": "close_sidebar", "menu": "close_sidebar",
		"home": "close_sidebar", "power": "ask_poweroff",
	},
	Screen.CONFIRM: {
		"nav_left": "confirm_left", "nav_right": "confirm_right", "nav_up": "", "nav_down": "",
		"accept": "confirm_run", "back": "to_sidebar", "menu": "", "home": "close_all", "power": "",
	},
	Screen.DESKTOP: {},
	Screen.OFF: {},
}

signal changed(screen: Screen, from: Screen)
signal sidebar_focus_changed(i: int)
signal confirm_focus_changed(i: int)
signal settings_requested

var screen := Screen.HOME
var sidebar_focus := 0
var confirm_kind := "poweroff"     # or "restart"
var confirm_focus := 0              # 0 Cancel, 1 the action


## Runs one action. Returns false when the current screen leaves it to Home.
func handle(action: String) -> bool:
	var row: Dictionary = TABLE[screen]
	if screen in [Screen.DESKTOP, Screen.OFF]:
		return true
	if not row.has(action):
		return false
	var step: String = row[action]
	if not step.is_empty():
		call("_" + step)
	return true


func go(to: Screen) -> void:
	var from := screen
	screen = to
	changed.emit(to, from)


## The daemon asked for Home (Home or Guide pressed, or the app went away).
func show_home() -> void:
	go(Screen.HOME)


func set_sidebar_focus(i: int) -> void:
	i = clampi(i, 0, ITEMS.size() - 1)
	if i != sidebar_focus:
		sidebar_focus = i
		sidebar_focus_changed.emit(i)


func set_confirm_focus(i: int) -> void:
	i = clampi(i, 0, 1)
	if i != confirm_focus:
		confirm_focus = i
		confirm_focus_changed.emit(i)


func run_item(item: String) -> void:
	match item:
		"home": go(Screen.HOME)
		"settings": settings_requested.emit()
		"desktop": go(Screen.DESKTOP)
		"restart": ask("restart")
		"poweroff": ask("poweroff")


## Opens the confirm with Cancel focused.
func ask(kind: String) -> void:
	confirm_kind = kind
	confirm_focus = 0
	confirm_focus_changed.emit(0)
	go(Screen.CONFIRM)


func _open_sidebar() -> void:
	sidebar_focus = 0
	sidebar_focus_changed.emit(0)
	go(Screen.SIDEBAR)


func _close_sidebar() -> void:
	go(Screen.HOME)


func _ask_poweroff() -> void:
	ask("poweroff")


func _sidebar_up() -> void:
	set_sidebar_focus(sidebar_focus - 1)


func _sidebar_down() -> void:
	set_sidebar_focus(sidebar_focus + 1)


func _sidebar_run() -> void:
	run_item(ITEMS[sidebar_focus])


func _confirm_left() -> void:
	set_confirm_focus(0)


func _confirm_right() -> void:
	set_confirm_focus(1)


func _confirm_run() -> void:
	if confirm_focus == 0:
		go(Screen.SIDEBAR)
	else:
		go(Screen.OFF)


func _to_sidebar() -> void:
	go(Screen.SIDEBAR)


func _close_all() -> void:
	go(Screen.HOME)
