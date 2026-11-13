extends Node

# What the mod was doing, written as it happens.
#
# Some guests crash over Steam and the game dies without a word: the crash log
# stops and says nothing about what came in last. This keeps a small file next
# to the game's crash logs with every message the mod receives and when the
# heavier jobs (adding buildings, belts, loading the world) start and end, so
# after a crash its last lines say what was being handled.
#
# It stays on the player's PC and holds no chat or names, only which message
# arrived, from which peer and how big it was. The ones that come in many times
# a second (moves, poses, belt and machine updates) are only counted, and the
# counts go on the once a second tick line: one line each filled 4 MB in about
# 18 minutes and the start of a session was gone by the time anyone looked. Each line is flushed as it is
# written, so it survives the game dying. On start the previous run's file is
# kept as mp_trace.prev.log, since after a crash the game gets opened again.

const PATH := "user://mp_trace.log"
const PREV := "user://mp_trace.prev.log"
# When the file is full it moves aside as mp_trace.part.log and a new one
# starts, so the minutes before the end are still there to read.
const PART := "user://mp_trace.part.log"
const MAX_BYTES := 16 << 20
const TICK := 1.0
# EA factories send a dozen machine packets every two seconds and the rest
# below several times a second; written one line each they filled the old
# 4 MB in a few minutes. They are counted on the tick line instead.
const COUNTED := ["straw_move", "straw_add", "straw_del", "straw_census",
	"prop_move", "prop_state", "prop_census", "machines", "machine_fields",
	"belts", "hay", "hay_sums", "state_delta", "machines_big", "state_snap",
	"prop_add", "prop_del", "prop_rest", "prop_want", "contract", "stand_visuals",
	"depot_setting"]

var _f: FileAccess = null
var _t := 0.0
var _frames := 0
var _dirty := false  # something was written this frame
var _counts := {}    # message -> how many since the last tick


func start(version: String) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PATH.get_file()):
		dir.rename(PATH.get_file(), PREV.get_file())
	# the last session's earlier part goes along with it
	if dir != null:
		if dir.file_exists(PART.get_file()):
			if dir.file_exists("mp_trace.prev.part.log"):
				dir.remove("mp_trace.prev.part.log")
			dir.rename(PART.get_file(), "mp_trace.prev.part.log")
		elif dir.file_exists("mp_trace.prev.part.log"):
			dir.remove("mp_trace.prev.part.log")
	_open()
	note("start mod %s, engine %s, %s" % [version, Engine.get_version_info().get("string", "?"),
		Time.get_datetime_string_from_system(true)])


# Guest: what the host shared, in a file of its own next to ours.
func host_lines(lines: PackedStringArray) -> void:
	if _host_f == null:
		_host_f = FileAccess.open(HOST_PATH, FileAccess.WRITE)
	if _host_f == null:
		return
	for line in lines:
		_host_f.store_line(line.left(2000))
	_host_f.flush()
	if _host_f.get_length() > MAX_BYTES:
		_host_f.close()
		_host_f = FileAccess.open(HOST_PATH, FileAccess.WRITE)


var last_cost := ""

func _cost_line() -> String:
	last_cost = preload("res://mods/multiplayer/mp_cost.gd").take()
	var session := get_node_or_null("/root/MPMod")
	if is_instance_valid(session):
		session.set("_perf_last", last_cost.replace(" cost=", "").left(160))
	return last_cost


func _open() -> void:
	_f = FileAccess.open(PATH, FileAccess.WRITE)


# Host: the lines a guest should see too (machine trouble and the
# once-a-second costs), so a report from either PC carries both sides.
const SHARED := ["wrapper ", "tick fps", "truck load", "peer ", "leave session", "world sync"]
const SHARE_MAX := 200
const HOST_PATH := "user://mp_host_trace.log"
var share := false
var shared: PackedStringArray = []
var _host_f: FileAccess = null


func note(text: String) -> void:
	_recent.append("%s %s" % [Time.get_time_string_from_system(), text])
	if _recent.size() > RECENT:
		_recent.remove_at(0)
	if share and shared.size() < SHARE_MAX:
		for prefix in SHARED:
			if text.begins_with(prefix):
				shared.append("%d %s" % [Time.get_ticks_msec(), text])
				break
	if _f == null:
		return
	_f.store_line("%d %s" % [Time.get_ticks_msec(), text])
	_f.flush()
	_dirty = true
	if _f.get_length() > MAX_BYTES:
		# start over rather than grow for ever, but keep the part before
		_f.close()
		var dir := DirAccess.open("user://")
		if dir != null:
			if dir.file_exists(PART.get_file()):
				dir.remove(PART.get_file())
			dir.rename(PATH.get_file(), PART.get_file())
		_open()
		note("trace restarted (size limit), the part before is mp_trace.part.log")


func rx(what: String, from: int, size: int) -> void:
	if COUNTED.has(what):
		_counts[what] = int(_counts.get(what, 0)) + 1
		return
	note("rx %s from %d%s" % [what, from, (" n=%d" % size) if size >= 0 else ""])


func _process(delta: float) -> void:
	# a frame went by after something was written: whatever that was, it
	# finished. After a crash, a message with no "frame" after it is the suspect.
	if _dirty and _f != null:
		_f.store_line("%d frame" % Time.get_ticks_msec())
		_f.flush()
		_dirty = false
	_frames += 1
	_t += delta
	if _t < TICK:
		return
	var got := ""
	for what in _counts:
		got += " %s=%d" % [what, _counts[what]]
	_counts.clear()
	note("tick fps=%d frame_ms=%.1f nodes=%d objects=%d res=%d orphans=%d phys_active=%d pairs=%d islands=%d phys_ms=%.1f proc_ms=%.1f%s%s" % [_frames, 1000.0 * _t / maxf(1.0, _frames),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		1000.0 * Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
		1000.0 * Performance.get_monitor(Performance.TIME_PROCESS), got,
		_cost_line()])
	_t = 0.0
	_frames = 0


func _exit_tree() -> void:
	if _f != null:
		note("quit")
		_f.close()
		_f = null


# A lost connection, written down where it is not rotated away: the trace
# moves to mp_trace.prev.log on the next start and is gone on the one after,
# and a player who dropped usually restarts the game at once. mp_drops.log
# keeps the last few drops with the time, the ping and the last lines before.
const DROPS := "user://mp_drops.log"
const DROPS_MAX := 2 << 20
const RECENT := 120
var _recent: PackedStringArray = []

func drop_report(title: String, version: String, ping_ms: float) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(DROPS.get_file()):
		var size := FileAccess.open(DROPS, FileAccess.READ)
		if size != null and size.get_length() > DROPS_MAX:
			size.close()
			if dir.file_exists(DROPS.get_file() + ".old"):
				dir.remove(DROPS.get_file() + ".old")
			dir.rename(DROPS.get_file(), DROPS.get_file() + ".old")
	var f := FileAccess.open(DROPS, FileAccess.READ_WRITE) if FileAccess.file_exists(DROPS) else FileAccess.open(DROPS, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("==== %s  %s  mod %s  ping %.0f ms" % [Time.get_datetime_string_from_system(false, true), title, version, ping_ms])
	for line in _recent:
		f.store_line("  " + line)
	f.store_line("")
	f.close()
