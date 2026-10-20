# What Settings > About shows: version, hostname, IP, memory, session type.
extends RefCounted


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


static func hostname() -> String:
	var h := FileAccess.get_file_as_string("/etc/hostname").strip_edges()
	if h.is_empty():
		h = OS.get_environment("HOSTNAME")
	if h.is_empty():
		h = OS.get_environment("COMPUTERNAME")
	return h if h else "Unknown"


static func ip_addresses() -> String:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		out.append(a)
	out.sort()
	return ", ".join(out) if out else "Not connected"


## "1.2 GB free of 3.7 GB", or "" off Linux.
static func memory(meminfo := "/proc/meminfo") -> String:
	var total := 0
	var avail := 0
	for line in FileAccess.get_file_as_string(meminfo).split("\n"):
		var f := line.split(" ", false)
		if f.size() >= 2 and f[0] == "MemTotal:":
			total = f[1].to_int()
		elif f.size() >= 2 and f[0] == "MemAvailable:":
			avail = f[1].to_int()
	if total == 0:
		return ""
	return "%.1f GB free of %.1f GB" % [avail / 1048576.0, total / 1048576.0]


static func launcher_memory_mb() -> int:
	return int(OS.get_static_memory_usage() / 1048576)


static func session_type() -> String:
	var t := OS.get_environment("XDG_SESSION_TYPE")
	return t if t else "unknown"
