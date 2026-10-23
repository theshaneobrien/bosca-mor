# Sound out of the TV, read and set with pactl, which talks to PulseAudio and
# PipeWire alike (D80). Chief's setting: Built-in Audio's HDMI / DisplayPort
# output, profile "Digital Stereo (HDMI) Output", volume 100%.
extends RefCounted

## The Sound output choices in Settings: the TV's HDMI, or leave it alone.
const OUTPUTS := ["hdmi", "auto"]
const OUTPUT_NAMES := {"hdmi": "HDMI / DisplayPort", "auto": "Automatic"}
## Volume at startup, in percent.
const VOLUMES := [100, 75, 50]
## "Digital Stereo (HDMI) Output". The -extra1, -extra2 profiles are the
## box's other HDMI and DP sockets.
const HDMI := "output:hdmi-stereo"


## pactl list cards as [{name, description, active, profiles: [{name, description, available}]}].
static func parse_cards(text: String) -> Array:
	var cards: Array = []
	var card := {}
	var section := ""
	for line in text.split("\n"):
		var depth := line.length() - line.lstrip("\t").length()
		var t := line.strip_edges()
		if t.is_empty():
			continue
		if depth == 0:
			card = {}
			if t.begins_with("Card #"):
				card = {"name": "", "description": "", "active": "", "profiles": []}
				cards.append(card)
			continue
		if card.is_empty():
			continue
		if depth == 1:
			section = ""
			if t.begins_with("Name: "):
				card.name = t.trim_prefix("Name: ")
			elif t.begins_with("Active Profile: "):
				card.active = t.trim_prefix("Active Profile: ")
			elif t.ends_with(":"):
				section = t.trim_suffix(":")
			continue
		if depth == 2 and section == "Properties" and t.begins_with("device.description = "):
			card.description = t.trim_prefix("device.description = ").trim_prefix("\"").trim_suffix("\"")
		elif depth == 2 and section == "Profiles" and t.contains(": "):
			var pname := t.get_slice(": ", 0)
			var rest := t.substr(pname.length() + 2)
			var paren := rest.rfind(" (sinks:")
			card.profiles.append({
				"name": pname,
				"description": rest.substr(0, paren) if paren >= 0 else rest,
				"available": not rest.contains("available: no"),
			})
	return cards


## Output-only HDMI profiles. Each socket's "+input:analog-stereo" twin plays
## through the same socket, and counting it would make one socket look like two.
static func is_hdmi(profile_name: String) -> bool:
	return not profile_name.contains("+") \
		and (profile_name == HDMI or profile_name.begins_with(HDMI + "-extra"))


## The first card with an HDMI output.
static func hdmi_card(cards: Array) -> Dictionary:
	for c in cards:
		for p in c.profiles:
			if is_hdmi(p.name):
				return c
	return {}


## The HDMI profile to use: the one socket with a TV on it, if exactly one
## says so, else "Digital Stereo (HDMI) Output" as Chief set it.
static func choose_profile(card: Dictionary) -> String:
	var hdmi: Array = card.profiles.filter(func(p): return is_hdmi(p.name))
	if hdmi.is_empty():
		return ""
	var live := hdmi.filter(func(p): return p.available)
	if live.size() == 1:
		return live[0].name
	for p in hdmi:
		if p.name == HDMI:
			return HDMI
	return hdmi[0].name


## The output half of a profile: "output:hdmi-stereo+input:analog-stereo"
## plays through output:hdmi-stereo.
static func output_of(profile_name: String) -> String:
	return profile_name.get_slice("+", 0)


static func profile_description(card: Dictionary, profile_name: String) -> String:
	for p in card.profiles:
		if p.name == profile_name:
			return p.description
	return profile_name


## The sink a card's profile makes: alsa_card.X with output:Y is alsa_output.X.Y.
static func sink_for(card: Dictionary, profile_name: String, short_sinks: String) -> String:
	var names: Array[String] = []
	for line in short_sinks.split("\n"):
		var f := line.split("\t")
		if f.size() >= 2:
			names.append(f[1])
	var tail := output_of(profile_name).trim_prefix("output:")
	var want := "alsa_output.%s.%s" % [String(card.name).trim_prefix("alsa_card."), tail]
	if want in names:
		return want
	for n in names:
		if n.ends_with("." + tail):
			return n
	return ""


static func default_sink(info: String) -> String:
	for line in info.split("\n"):
		if line.begins_with("Default Sink: "):
			return line.trim_prefix("Default Sink: ").strip_edges()
	return ""


## Sets the output (if want is "hdmi") and the volume (if volume >= 0).
## run(argv) -> {code, out}. Returns {ok, playing, changed, error}, where
## playing is what Settings shows: "Digital Stereo (HDMI) Output, Built-in Audio".
static func ensure(want: String, volume: int, run: Callable) -> Dictionary:
	var r: Dictionary = run.call(["pactl", "list", "cards"])
	if r.code != 0:
		return {"ok": false, "error": "no sound server"}
	var cards := parse_cards(r.out)
	var changed := false
	var sink := "@DEFAULT_SINK@"
	var card: Dictionary = hdmi_card(cards) if want == "hdmi" else (cards[0] if cards else {})
	var playing := ""
	if want == "hdmi":
		if card.is_empty():
			return {"ok": false, "error": "no HDMI sound"}
		var profile := choose_profile(card)
		if output_of(card.active) != profile:
			if run.call(["pactl", "set-card-profile", card.name, profile]).code != 0:
				return {"ok": false, "error": "the profile did not change"}
			card.active = profile
			changed = true
		sink = sink_for(card, profile, run.call(["pactl", "list", "short", "sinks"]).out)
		if sink.is_empty():
			return {"ok": false, "error": "no HDMI sink yet"}
		if default_sink(run.call(["pactl", "info"]).out) != sink:
			if run.call(["pactl", "set-default-sink", sink]).code != 0:
				return {"ok": false, "error": "the output did not change"}
			changed = true
	if not card.is_empty():
		playing = "%s, %s" % [profile_description(card, card.active), card.description] \
			if card.description else profile_description(card, card.active)
	if volume >= 0:
		run.call(["pactl", "set-sink-mute", sink, "0"])
		if run.call(["pactl", "set-sink-volume", sink, "%d%%" % volume]).code != 0:
			return {"ok": false, "playing": playing, "error": "the volume did not change"}
	return {"ok": true, "playing": playing, "changed": changed}
