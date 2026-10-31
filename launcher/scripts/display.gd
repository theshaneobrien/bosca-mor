# The TV picture, read and set with xrandr (D79). Box test: through the
# active DP to HDMI adapter the box came up at the wrong mode until the cable
# was replugged, so the launcher sets the external output to the chosen mode
# itself. When the TV's mode list didn't come through the adapter, it adds
# the standard CEA timing, and if 1920 x 1080 still fails it falls back to
# 1280 x 720 at 60 Hz.
#
# The box's TV lists two 1920x1080 modes at 60.00 Hz with the same timing,
# one with -HSync -VSync that shows nothing and the CEA one with +HSync
# +VSync, and `xrandr --mode 1920x1080 --rate 60` takes the first. So the
# mode is chosen from xrandr --verbose by its exact timing and sync, the CEA
# one first, and set by its id (D83, D101).
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
## The CEA timings as xrandr --verbose shows them: MHz, h total, v total.
const CEA_TOTALS := {"1920x1080@60": [148.5, 2200, 1125], "1280x720@60": [74.25, 1650, 750]}
## Their sync, as xrandr --verbose shows it (D101).
const CEA_SYNC := "+HSync +VSync"
## Built-in panels, never the TV.
const INTERNAL := ["eDP", "LVDS", "DSI"]
const RATE_MATCH := 0.5          # Hz: 59.94 and 60.00 both count as 60
const MIN_RATE := 50.0           # Hz: a TV without the rate asked for may use its own down to this (D101)


## xrandr --query, --current or --verbose as a list of outputs:
## [{name, connected, primary, current: {w, h, hz, id?} or {}, modes: [mode]}]
## A mode is {name, w, h, rates} where rates are the strings xrandr printed
## ("60.00"). From --verbose each mode is one timing, and also has id, mhz,
## htotal, vtotal, sync ("+HSync +VSync") and current.
static func parse(text: String) -> Array:
	var size_re := RegEx.create_from_string("^(\\d+)x(\\d+)(i?)")
	var verbose_re := RegEx.create_from_string("^\\s+(\\S+)\\s+\\((0x[0-9a-fA-F]+)\\)\\s+([\\d.]+)MHz(.*)$")
	var total_re := RegEx.create_from_string("^\\s+([hv]):.*\\stotal\\s+(\\d+).*clock\\s+([\\d.]+)")
	var outs: Array = []
	var cur := {}
	var last := {}            # the --verbose mode its h: and v: lines belong to
	for line in text.split("\n"):
		if line.strip_edges().is_empty() or line.begins_with("Screen "):
			continue
		if not (line.begins_with(" ") or line.begins_with("\t")):
			var head := line.split(" ", false)
			cur = {}
			last = {}
			if head.size() >= 2 and head[1] in ["connected", "disconnected", "unknown"]:
				cur = {"name": head[0], "connected": head[1] == "connected",
					"primary": head.has("primary"), "current": {}, "modes": []}
				outs.append(cur)
			continue
		if cur.is_empty() or line.begins_with("\t"):
			continue          # --verbose properties and EDID
		var vm := verbose_re.search(line)
		if vm:
			last = {}
			var sm := size_re.search(vm.get_string(1))
			if sm == null or vm.get_string(4).contains("Interlace"):
				continue
			var flags := vm.get_string(4).split(" ", false)
			var syncs := PackedStringArray()
			for t in flags:
				if t.ends_with("Sync"):
					syncs.append(t)
			var sync := " ".join(syncs)
			last = {"name": vm.get_string(1), "id": vm.get_string(2), "mhz": vm.get_string(3).to_float(),
				"w": sm.get_string(1).to_int(), "h": sm.get_string(2).to_int(), "rates": [],
				"htotal": 0, "vtotal": 0, "sync": sync, "current": flags.has("*current")}
			cur.modes.append(last)
			continue
		var tm := total_re.search(line)
		if tm:
			if last.is_empty():
				continue
			if tm.get_string(1) == "h":
				last.htotal = tm.get_string(2).to_int()
			else:
				last.vtotal = tm.get_string(2).to_int()
				last.rates.append("%.2f" % tm.get_string(3).to_float())
				if last.current:
					cur.current = {"w": last.w, "h": last.h, "hz": tm.get_string(3).to_float(), "id": last.id}
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


## The mode in the TV's list to use for mode, best first: from --verbose the
## CEA timing (clock, totals and sync); then the nearest rate within
## RATE_MATCH, CEA sync first; then, for a TV that doesn't list that rate,
## its nearest lower one down to MIN_RATE, CEA sync first (D101).
## {name, rate, cea, id (--verbose)}, or {} if the list has none.
static func choose(out: Dictionary, mode: String) -> Dictionary:
	var m := split(mode)
	var cea: Array = CEA_TOTALS.get(mode, [])
	var best := {}
	var best_rank := INF
	for entry in out.modes:
		if entry.w != m.w or entry.h != m.h:
			continue
		var sync_ok: bool = entry.get("sync", "") in ["", CEA_SYNC]   # "" when xrandr didn't say
		var is_cea: bool = entry.has("id") and cea.size() == 3 and absf(entry.mhz - cea[0]) < 0.01 \
			and entry.htotal == cea[1] and entry.vtotal == cea[2] and entry.sync == CEA_SYNC
		for r in entry.rates:
			var hz: float = r.to_float()
			var d := absf(hz - m.hz)
			var tier := 0
			if is_cea:
				tier = 0
			elif d < RATE_MATCH:
				tier = 1 if sync_ok else 2
			elif hz >= MIN_RATE and hz < m.hz:
				tier = 3 if sync_ok else 4
			else:
				continue
			var rank := tier * 1000.0 + d
			if rank >= best_rank:
				continue                    # ties: the first in the TV's list
			best_rank = rank
			best = {"name": entry.name, "rate": r, "cea": is_cea}
			if entry.has("id"):
				best.id = entry.id
	return best


## The xrandr commands that put the output on mode, or [] if it already is.
## "auto" hands it back to the TV's preferred mode. strict: the current mode
## counts only if it is the chosen timing itself (login and Settings);
## otherwise any timing of that size and rate will do, so a picture that
## works after a replug is left alone (D83). A current mode with the chosen
## one's exact timing and sync is never set again (D101).
static func plan(out: Dictionary, mode: String, strict := true) -> Array:
	var o: String = out.name
	if mode == "auto":
		return [["xrandr", "--output", o, "--auto"]]
	if not strict and is_mode(out.current, mode):
		return []
	var best := choose(out, mode)
	if best.has("id"):
		if _same_timing(out, out.current.get("id", ""), best.id):
			return []
		return [["xrandr", "--output", o, "--mode", best.id]]
	if is_mode(out.current, mode):
		return []
	var m := split(mode)
	if best:
		return [["xrandr", "--output", o, "--mode", best.name, "--rate", best.rate]]
	# Not in the TV's list: add the CEA timing under its own name.
	var mode_name := "%dx%d_%d" % [m.w, m.h, roundi(m.hz)]
	return [["xrandr", "--newmode", mode_name] + CEA[mode],
		["xrandr", "--addmode", o, mode_name],
		["xrandr", "--output", o, "--mode", mode_name]]


## Puts the TV on mode, falling back to 1280 x 720 if 1920 x 1080 fails.
## run(argv) -> {code, out}. probe: read the TV again (xrandr --verbose);
## otherwise what X already knows (--verbose --current), which is quicker.
## Returns {ok, output, mode, changed, fallback, error}, plus was, modes and
## steps for the log.
static func ensure(mode: String, run: Callable, probe := true) -> Dictionary:
	var q: Dictionary = run.call(["xrandr", "--verbose"] if probe else ["xrandr", "--verbose", "--current"])
	if q.code != 0:
		return {"ok": false, "error": "xrandr did not run"}
	var out := pick_output(parse(q.out))
	if out.is_empty():
		return {"ok": false, "error": "no screen found"}
	var notes := {"output": out.name, "was": timing(out, out.current.get("id", "")), "modes": timings(out, mode)}
	var tries := [mode] if mode == FALLBACK or mode == "auto" else [mode, FALLBACK]
	for want in tries:
		var steps := plan(out, want, probe)
		if steps.is_empty() or _run_all(steps, run):
			var r := {"ok": true, "mode": want, "changed": not steps.is_empty(), "fallback": want != mode, "steps": steps}
			r.merge(notes)
			return r
	notes.merge({"ok": false, "error": "the screen did not take it"})
	return notes


# True if mode ids a and b are one timing: the same id, or the same clock,
# totals, rate and sync under two ids.
static func _same_timing(out: Dictionary, a: String, b: String) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	if a == b:
		return true
	var ma := _by_id(out, a)
	var mb := _by_id(out, b)
	return not ma.is_empty() and not mb.is_empty() and ma.w == mb.w and ma.h == mb.h \
		and absf(ma.mhz - mb.mhz) < 0.01 and ma.htotal == mb.htotal and ma.vtotal == mb.vtotal \
		and ma.sync == mb.sync and ma.rates == mb.rates


static func _by_id(out: Dictionary, id: String) -> Dictionary:
	for m in out.modes:
		if m.get("id", "") == id:
			return m
	return {}


## "1920x1080 0x4a 148.50 MHz 2200x1125 +HSync +VSync 60.00 Hz", for the log.
static func timing(out: Dictionary, id: String) -> String:
	for m in out.modes:
		if id and m.get("id", "") == id:
			return "%s %s %.2f MHz %dx%d %s %s Hz" % [m.name, m.id, m.mhz, m.htotal, m.vtotal, m.sync,
				m.rates[0] if m.rates else "?"]
	if out.current:
		return "%dx%d %.2f Hz" % [out.current.w, out.current.h, out.current.hz]
	return "off"


## Every timing in the TV's list at mode's size, for the log.
static func timings(out: Dictionary, mode: String) -> Array:
	var m := split(mode if mode != "auto" else "1920x1080@60")
	var list := []
	for entry in out.modes:
		if entry.w == m.w and entry.h == m.h and entry.has("id"):
			list.append(timing(out, entry.id))
	return list


static func _run_all(steps: Array, run: Callable) -> bool:
	for argv in steps:
		var r: Dictionary = run.call(argv)
		# --newmode fails if the mode was made earlier this session; carry on.
		if r.code != 0 and argv[1] != "--newmode":
			return false
	return true
