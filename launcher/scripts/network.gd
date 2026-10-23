# Wi-Fi in Settings > Network, through nmcli (D81): the networks in range,
# which is connected and which are saved, and joining one with a password
# typed on the on-screen keyboard. Everything else stays in the desktop's
# own network settings.
extends RefCounted

const Tokens := preload("res://theme/tokens.gd")

const STRONG := 67               # nmcli signal, 0 to 100
const GOOD := 34


## Splits one line of nmcli -t output on ":" that isn't escaped as "\:".
static func split_terse(line: String) -> Array[String]:
	var out: Array[String] = []
	var cur := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if ch == "\\" and i + 1 < line.length():
			cur += line[i + 1]
			i += 2
			continue
		if ch == ":":
			out.append(cur)
			cur = ""
		else:
			cur += ch
		i += 1
	out.append(cur)
	return out


## nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list, one entry per
## name (the strongest), connected first, then strongest first.
## [{ssid, signal, secure, enterprise, in_use, known}]
static func parse_list(text: String, saved: Array = []) -> Array:
	var by_name := {}
	for line in text.split("\n"):
		var f := split_terse(line.strip_edges(false, true))
		if f.size() < 4 or f[3].is_empty() or not f[1].is_valid_int():
			continue      # a hidden network, or not a list line
		var n := {"ssid": f[3], "signal": f[1].to_int(), "secure": not f[2].strip_edges().is_empty(),
			"enterprise": f[2].contains("802.1X"), "in_use": f[0] == "*", "known": f[3] in saved}
		var had: Dictionary = by_name.get(n.ssid, {})
		if had.is_empty() or n.signal > had.signal:
			n.in_use = n.in_use or had.get("in_use", false)
			by_name[n.ssid] = n
		elif n.in_use:
			had.in_use = true
	var nets := by_name.values()
	nets.sort_custom(func(a, b):
		if a.in_use != b.in_use:
			return a.in_use
		return a.signal > b.signal)
	return nets


## Saved Wi-Fi profiles, from nmcli -t -f NAME,TYPE connection show.
static func parse_saved(text: String) -> Array:
	var out := []
	for line in text.split("\n"):
		var f := split_terse(line.strip_edges(false, true))
		if f.size() >= 2 and f[1] == "802-11-wireless":
			out.append(f[0])
	return out


## From nmcli -t -f TYPE,STATE,CONNECTION device: {has_wifi, wifi, wired}
## where wifi is the connected profile's name.
static func parse_devices(text: String) -> Dictionary:
	var out := {"has_wifi": false, "wifi": "", "wired": false}
	for line in text.split("\n"):
		var f := split_terse(line.strip_edges(false, true))
		if f.size() < 3:
			continue
		var up := f[1].begins_with("connected")
		if f[0] == "wifi":
			out.has_wifi = true
			if up:
				out.wifi = f[2]
		elif f[0] == "ethernet" and up:
			out.wired = true
	return out


## "Connected", "Saved, strong", "Open, weak".
static func words(n: Dictionary) -> String:
	if n.in_use:
		return "Connected"
	var parts := []
	if n.known:
		parts.append("Saved")
	elif not n.secure:
		parts.append("Open")
	var strength := "strong" if n.signal >= STRONG else ("good" if n.signal >= GOOD else "weak")
	parts.append(strength if parts else strength.capitalize())
	return ", ".join(parts)


## Networks in range. run(argv, limit_s, stderr) -> {code, out}.
## {ok, has_wifi, connected ("" or a network name or "Wired"), networks, error}
static func scan(run: Callable, rescan := false) -> Dictionary:
	var d: Dictionary = run.call(["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"])
	if d.code != 0:
		return {"ok": false, "has_wifi": false, "connected": "", "networks": [], "error": "no network manager"}
	var dev := parse_devices(d.out)
	var out := {"ok": true, "has_wifi": dev.has_wifi, "networks": [],
		"connected": dev.wifi if dev.wifi else ("Wired" if dev.wired else "")}
	if not dev.has_wifi:
		return out
	var l: Dictionary = run.call(["nmcli", "-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi", "list",
		"--rescan", "yes" if rescan else "auto"], Tokens.WIFI_SCAN_TIMEOUT)
	var saved: Dictionary = run.call(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
	out.networks = parse_list(l.out, parse_saved(saved.out))
	for n in out.networks:
		if n.in_use:
			out.connected = n.ssid
	return out


## Joins a network. A saved one is brought up as it is, or with a new
## password; a new one is made by nmcli. The password goes to nmcli as an
## argument (D81) and is never logged.
## {ok, ssid, error: "password" or "failed", tried_password}
static func join(ssid: String, password: String, known: bool, run: Callable) -> Dictionary:
	var wait := str(Tokens.WIFI_CONNECT_TIMEOUT - 5)
	var r: Dictionary
	if known:
		if password:
			var m: Dictionary = run.call(["nmcli", "connection", "modify", "id", ssid,
				"wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password], Tokens.SETUP_CMD_TIMEOUT, true)
			if m.code != 0:
				return {"ok": false, "ssid": ssid, "error": "password" if _bad_password(m.out) else "failed", "tried_password": true}
		r = run.call(["nmcli", "--wait", wait, "connection", "up", "id", ssid], Tokens.WIFI_CONNECT_TIMEOUT, true)
	else:
		var argv := ["nmcli", "--wait", wait, "device", "wifi", "connect", ssid]
		if password:
			argv.append_array(["password", password])
		r = run.call(argv, Tokens.WIFI_CONNECT_TIMEOUT, true)
	if r.code == 0:
		return {"ok": true, "ssid": ssid}
	return {"ok": false, "ssid": ssid, "error": "password" if _bad_password(r.out) else "failed",
		"tried_password": not password.is_empty()}


static func _bad_password(out: String) -> bool:
	return out.contains("Secrets were required") or out.contains("psk: property is invalid") \
		or out.contains("802-11-wireless-security.psk")
