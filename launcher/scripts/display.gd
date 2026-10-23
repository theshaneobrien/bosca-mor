# The TV picture, read and set with xrandr (D79). Box test: through the
# active DP to HDMI adapter the box came up at the wrong mode until the cable
# was replugged, so the launcher sets the external output to the chosen mode
# itself. When the TV's mode list didn't come through the adapter, it adds
# the standard CEA timing, and if 1920 x 1080 still fails it falls back to
# 1280 x 720 at 60 Hz.
extends RefCounted

## The Picture choices in Settings, in the order Accept steps through them.
const MODES := ["1920x1080@60", "1280x720@60", "auto"]
const FALLBACK := "1280x720@60"
## CEA-861 timings (pixel clock MHz, then h and v timings), for a TV whose
## own list didn't come through.
const CEA := {
	"1920x1080@60": ["148.50", "1920", "2008", "2052", "2200", "1080", "1084", "1089", "1125", "+hsync", "+vsync"],
	"1280x720@60": ["74.25", "1280", "1390", "1430", "1650", "720", "725", "730", "750", "+hsync", "+vsync"],
}
## Built-in panels, never the TV.
const INTERNAL := ["eDP", "LVDS", "DSI"]
const RATE_MATCH := 0.5          # Hz: 59.94 and 60.00 both count as 60


## xrandr --query (or --current) as a list of outputs:
## [{name, connected, primary, current: {w, h, hz} or {}, modes: [{name, w, h, rates}]}]
## where rates are the strings xrandr printed ("60.00").
static func parse(text: String) -> Array:
	var size_re := RegEx.create_from_string("^(\\d+)x(\\d+)(i?)")
	var outs: Array = []
	var cur := {}
	for line in text.split("\n"):
		if line.strip_edges().is_empty() or line.begins_with("Screen "):
			continue
		if not (line.begins_with(" ") or line.begins_with("\t")):
			var head := line.split(" ", false)
			cur = {}
			if head.size() >= 2 and head[1] in ["connected", "disconnected", "unknown"]:
				cur = {"name": head[0], "connected": head[1] == "connected",
					"primary": head.has("primary"), "current": {}, "modes": []}
				outs.append(cur)
			continue
		if cur.is_empty():
			continue
		var f := line.strip_edges().split(" ", false)
		var m := size_re.search(f[0])
		if m == null or m.get_string(3) == "i":
			continue      # a property line, or an interlaced mode
		var w := m.get_string(1).to_int()
		var h := m.get_string(2).to_int()
		var rates: Array[String] = []
		for i in range(1, f.size()):
			var tok: String = f[i]
			if not tok[0].is_valid_int():
				continue      # a lone "+" marks the rate before it as preferred
			var rate := tok.rstrip("*+")
			if not rate.is_valid_float():
				continue
			rates.append(rate)
			if tok.contains("*"):
				cur.current = {"w": w, "h": h, "hz": rate.to_float()}
		cur.modes.append({"name": f[0], "w": w, "h": h, "rates": rates})
	return outs


## The TV: the primary output if it is an external one, else the first
## connected external output (like `grep " connected" | grep -v eDP`).
static func pick_output(outs: Array) -> Dictionary:
	var external := outs.filter(func(o): return o.connected and not _internal(o.name))
	for o in external:
		if o.primary:
			return o
	return external[0] if external else {}


static func _internal(output_name: String) -> bool:
	for p in INTERNAL:
		if output_name.begins_with(p):
			return true
	return false


## {w, h, hz} from "1920x1080@60"; {} for "auto".
static func split(mode: String) -> Dictionary:
	if not mode.contains("@"):
		return {}
	var size := mode.get_slice("@", 0)
	return {"w": size.get_slice("x", 0).to_int(), "h": size.get_slice("x", 1).to_int(),
		"hz": mode.get_slice("@", 1).to_float()}


## "1920 x 1080 at 60 Hz", or "Automatic".
static func describe(mode) -> String:
	var m: Dictionary = split(mode) if mode is String else mode
	if m.is_empty():
		return "Automatic"
	return "%d x %d at %d Hz" % [m.w, m.h, roundi(m.hz)]


static func is_mode(current: Dictionary, mode: String) -> bool:
	var m := split(mode)
	return not current.is_empty() and not m.is_empty() and current.w == m.w \
		and current.h == m.h and absf(current.hz - m.hz) < RATE_MATCH


## The xrandr commands that put the output on mode, or [] if it already is.
## "auto" hands it back to the TV's preferred mode.
static func plan(out: Dictionary, mode: String) -> Array:
	var o: String = out.name
	if mode == "auto":
		return [["xrandr", "--output", o, "--auto"]]
	if is_mode(out.current, mode):
		return []
	var m := split(mode)
	var best := {}
	var gap := RATE_MATCH
	for entry in out.modes:
		if entry.w != m.w or entry.h != m.h:
			continue
		for r in entry.rates:
			var d := absf(r.to_float() - m.hz)
			if d < gap:
				gap = d
				best = {"name": entry.name, "rate": r}
	if best:
		return [["xrandr", "--output", o, "--mode", best.name, "--rate", best.rate]]
	# Not in the TV's list: add the CEA timing under its own name.
	var mode_name := "%dx%d_%d" % [m.w, m.h, roundi(m.hz)]
	return [["xrandr", "--newmode", mode_name] + CEA[mode],
		["xrandr", "--addmode", o, mode_name],
		["xrandr", "--output", o, "--mode", mode_name]]


## Puts the TV on mode, falling back to 1280 x 720 if 1920 x 1080 fails.
## run(argv) -> {code, out}. probe: --query reads the TV again; --current is
## what X already knows, and quicker.
## Returns {ok, output, mode, changed, fallback, error}.
static func ensure(mode: String, run: Callable, probe := true) -> Dictionary:
	var q: Dictionary = run.call(["xrandr", "--query" if probe else "--current"])
	if q.code != 0:
		return {"ok": false, "error": "xrandr did not run"}
	var out := pick_output(parse(q.out))
	if out.is_empty():
		return {"ok": false, "error": "no screen found"}
	var tries := [mode] if mode == FALLBACK or mode == "auto" else [mode, FALLBACK]
	for want in tries:
		var steps := plan(out, want)
		if steps.is_empty():
			return {"ok": true, "output": out.name, "mode": want, "changed": false, "fallback": want != mode}
		if _run_all(steps, run):
			return {"ok": true, "output": out.name, "mode": want, "changed": true, "fallback": want != mode}
	return {"ok": false, "output": out.name, "error": "the screen did not take it"}


static func _run_all(steps: Array, run: Callable) -> bool:
	for argv in steps:
		var r: Dictionary = run.call(argv)
		# --newmode fails if the mode was made earlier this session; carry on.
		if r.code != 0 and argv[1] != "--newmode":
			return false
	return true
