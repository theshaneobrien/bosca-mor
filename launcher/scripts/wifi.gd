# Wi-Fi state for the top bar, read from /proc/net/wireless (no binaries,
# no per-frame work; Home polls it every WIFI_POLL seconds).
extends RefCounted

const PATH := "/proc/net/wireless"

## "on": a wireless interface has a link. "off": one exists but has no link.
## "none": no wireless interface (a wired box). "unknown": no /proc (not Linux).
static func state(path := PATH) -> String:
	if not FileAccess.file_exists(path):
		return "unknown"
	return parse(FileAccess.get_file_as_string(path))


static func parse(text: String) -> String:
	var found := false
	for line in text.split("\n"):
		if not line.contains(":") or line.strip_edges().begins_with("Inter-"):
			continue
		var head := line.split(":", true, 1)
		if head[0].strip_edges().contains("|"):
			continue
		var fields := head[1].split(" ", false)
		if fields.size() < 2:
			continue
		found = true
		if fields[1].trim_suffix(".").to_float() > 0.0:
			return "on"
	return "off" if found else "none"
