extends RefCounted

# Where a frame's time goes, per part of the mod. The busy functions add the
# microseconds they took; mp_trace writes the totals on its once-a-second tick
# line ("cost=machines:12.3 ..." in ms per second) and starts over.

static var spent := {}
# Parts switched off from the chat ("/perf belts" and so on) to find out
# in a running game which one costs the frames.
static var off := {}
# true while the factory clock runs its tick (belts and machines)
static var in_clock := false


static func is_off(what: String) -> bool:
	return off.has(what)


static func add(what: String, usec: int) -> void:
	spent[what] = int(spent.get(what, 0)) + usec


static func take() -> String:
	if spent.is_empty():
		return ""
	var names := spent.keys()
	names.sort_custom(func(a, b): return int(spent[a]) > int(spent[b]))
	var parts := PackedStringArray()
	for name in names.slice(0, 16):
		if int(spent[name]) >= 500:
			parts.append("%s:%.1f" % [name, int(spent[name]) / 1000.0])
	spent.clear()
	return " cost=" + ",".join(parts) if not parts.is_empty() else ""
