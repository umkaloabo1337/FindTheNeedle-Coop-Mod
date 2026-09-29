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
# arrived, from which peer and how big it was. Each line is flushed as it is
# written, so it survives the game dying. On start the previous run's file is
# kept as mp_trace.prev.log, since after a crash the game gets opened again.

const PATH := "user://mp_trace.log"
const PREV := "user://mp_trace.prev.log"
const MAX_BYTES := 4 << 20
const TICK := 1.0

var _f: FileAccess = null
var _t := 0.0
var _frames := 0
var _dirty := false  # something was written this frame


func start(version: String) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PATH.get_file()):
		dir.rename(PATH.get_file(), PREV.get_file())
	_open()
	note("start mod %s, engine %s, %s" % [version, Engine.get_version_info().get("string", "?"),
		Time.get_datetime_string_from_system(true)])


func _open() -> void:
	_f = FileAccess.open(PATH, FileAccess.WRITE)


func note(text: String) -> void:
	if _f == null:
		return
	_f.store_line("%d %s" % [Time.get_ticks_msec(), text])
	_f.flush()
	_dirty = true
	if _f.get_length() > MAX_BYTES:
		# start over rather than grow for ever; the end is what matters
		_f.close()
		_open()
		note("trace restarted (size limit)")


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
	note("tick fps=%d frame_ms=%.1f nodes=%d" % [_frames, 1000.0 * _t / maxf(1.0, _frames),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	_t = 0.0
	_frames = 0


func _exit_tree() -> void:
	if _f != null:
		note("quit")
		_f.close()
		_f = null
