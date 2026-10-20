# Tweens for every row of the SPEC motion table. Every tween retargets: a new
# tween on the same object and property kills the old one and starts from the
# current value. Reduce motion halves every duration and drops movement, so
# only fades play.
extends RefCounted

const Tokens := preload("res://theme/tokens.gd")

# name: [seconds, transition, ease]
const SPECS := {
	"tile_focus": [Tokens.T_TILE_FOCUS, Tween.TRANS_BACK, Tween.EASE_OUT],
	"carousel": [Tokens.T_CAROUSEL, Tween.TRANS_QUINT, Tween.EASE_OUT],
	"hero": [Tokens.T_HERO, Tween.TRANS_CUBIC, Tween.EASE_OUT],
	"sidebar_open": [Tokens.T_SIDEBAR_OPEN, Tween.TRANS_QUINT, Tween.EASE_OUT],
	"sidebar_close": [Tokens.T_SIDEBAR_CLOSE, Tween.TRANS_CUBIC, Tween.EASE_IN],
	"confirm": [Tokens.T_CONFIRM, Tween.TRANS_CUBIC, Tween.EASE_OUT],
	"launch": [Tokens.T_LAUNCH, Tween.TRANS_CUBIC, Tween.EASE_IN],
	"return": [Tokens.T_RETURN, Tween.TRANS_CUBIC, Tween.EASE_OUT],
	"bump": [Tokens.T_BUMP, Tween.TRANS_SINE, Tween.EASE_IN_OUT],
}

static var reduce := false
static var _live := {}              # "instance_id:property" -> Tween


static func duration(spec: String) -> float:
	return SPECS[spec][0] * (0.5 if reduce else 1.0)


## Tweens target.property to value. A movement (scale, position) snaps
## instead when reduce motion is on. Returns the tween, or null if it snapped.
static func to(target: CanvasItem, property: String, value, spec: String, movement := false) -> Tween:
	var key := _key(target, property)
	stop(target, property)
	if movement and reduce:
		target.set_indexed(property, value)
		return null
	var s: Array = SPECS[spec]
	var t := target.create_tween()
	t.tween_property(target, property, value, duration(spec)).set_trans(s[1]).set_ease(s[2])
	_live[key] = t
	return t


## A nudge of `offset` and back to `rest`, as one tween on target.property.
static func bump(target: CanvasItem, property: String, rest, offset) -> Tween:
	stop(target, property)
	if reduce:
		target.set_indexed(property, rest)
		return null
	var half := duration("bump") / 2.0
	var t := target.create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(target, property, rest + offset, half)
	t.tween_property(target, property, rest, half)
	_live[_key(target, property)] = t
	return t


static func stop(target: Object, property: String) -> void:
	var key := _key(target, property)
	var old: Tween = _live.get(key)
	if old and old.is_valid():
		old.kill()
	_live.erase(key)


## Live tweens by key, dropping finished ones. Tests use it.
static func live() -> Dictionary:
	for k in _live.keys():
		if not (_live[k].is_valid() and _live[k].is_running()):
			_live.erase(k)
	return _live


static func _key(target: Object, property: String) -> String:
	return "%d:%s" % [target.get_instance_id(), property]
