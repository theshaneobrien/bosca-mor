# The screen state machine. The navigation table from SPEC "Screens and
# navigation" is the TABLE below; Home's own moves and launches stay in Home.
extends RefCounted

enum Screen { HOME, SIDEBAR, CONFIRM, DESKTOP, OFF, SETTINGS, STILL_OPEN }

const ITEMS := ["home", "settings", "desktop", "restart", "poweroff"]
const ACTIONS := ["nav_left", "nav_right", "nav_up", "nav_down", "accept", "back", "menu", "home", "power"]

# screen -> action -> step. "" consumes the action and does nothing; an
# action that is missing is left for the screen itself (Home's moves,
# Settings' moves, accept and back).
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
	Screen.SETTINGS: {"menu": "", "home": "close_all", "power": "ask_poweroff"},
	# Not in the SPEC table (D43): Left and Right move between the three
	# buttons, Back is "Back to desktop", Home shows Home and leaves the apps.
	Screen.STILL_OPEN: {
		"nav_left": "still_left", "nav_right": "still_right", "nav_up": "", "nav_down": "",
		"accept": "still_run", "back": "still_back", "menu": "", "home": "close_all", "power": "ask_poweroff",
	},
	Screen.DESKTOP: {},
	Screen.OFF: {},
}

signal changed(screen: Screen, from: Screen)
signal sidebar_focus_changed(i: int)
signal confirm_focus_changed(i: int)
signal still_focus_changed(i: int)
## Close anyway was confirmed: force-close the windows Still open listed.
signal force_close_confirmed
## Remove was confirmed for the app Settings asked about.
signal remove_confirmed
## Keep was chosen for the picture Settings is trying (D79).
signal picture_kept

var screen := Screen.HOME
var sidebar_focus := 0
var confirm_kind := "poweroff"     # or "restart", "forceclose", "remove", "picture", "update"
var confirm_focus := 0              # 0 Cancel, 1 the action
var still_focus := 0                # 0 Show me, 1 Close anyway, 2 Back to desktop
## Why the desktop is showing: "menu" (sidebar Desktop: notify), "show_me"
## (raise a window that is still open) or "back" (Back to desktop).
var desktop_reason := "menu"


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
		"settings": go(Screen.SETTINGS)
		"desktop": to_desktop("menu")
		"restart": ask("restart")
		"poweroff": ask("poweroff")


func to_desktop(reason: String) -> void:
	desktop_reason = reason
	go(Screen.DESKTOP)


## The daemon found windows that didn't close.
func show_still_open() -> void:
	still_focus = 0
	still_focus_changed.emit(0)
	go(Screen.STILL_OPEN)


func set_still_focus(i: int) -> void:
	i = clampi(i, 0, 2)
	if i != still_focus:
		still_focus = i
		still_focus_changed.emit(i)


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
		_to_sidebar()
	elif confirm_kind == "forceclose":
		force_close_confirmed.emit()
		go(Screen.HOME)
	elif confirm_kind == "remove":
		remove_confirmed.emit()
		go(Screen.SETTINGS)
	elif confirm_kind == "picture":
		picture_kept.emit()
		go(Screen.SETTINGS)
	else:
		go(Screen.OFF)


# Cancel or Back: the force-close confirm returns to Still open, the remove,
# picture and update confirms to Settings (D73, D79, D103), the power
# confirms to the sidebar.
func _to_sidebar() -> void:
	match confirm_kind:
		"forceclose": go(Screen.STILL_OPEN)
		"remove", "picture", "update": go(Screen.SETTINGS)
		_: go(Screen.SIDEBAR)


## "Updating" on black, as for a power action (D103): the idle launcher
## installing a ready update, or restarting into one.
func start_update() -> void:
	confirm_kind = "update"
	go(Screen.OFF)


## What Cancel does, without a press: the picture confirm ran out of time.
func cancel_confirm() -> void:
	if screen == Screen.CONFIRM:
		_to_sidebar()


func _still_left() -> void:
	set_still_focus(still_focus - 1)


func _still_right() -> void:
	set_still_focus(still_focus + 1)


func _still_run() -> void:
	match still_focus:
		0: to_desktop("show_me")
		1: ask("forceclose")
		2: to_desktop("back")


func _still_back() -> void:
	to_desktop("back")


func _close_all() -> void:
	go(Screen.HOME)
