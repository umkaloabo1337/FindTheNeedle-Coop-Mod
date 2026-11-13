extends FactoryClock
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

const Cells = preload("res://mods/multiplayer/mp_belt_watch_cells.gd")

class WatchView extends PropManager:
	func _ready() -> void:
		set_process(false)
		set_physics_process(false)

var _mp_props: PropManager
var _mp_watch: PropManager

func mp_watch_start(props: PropManager) -> void:
	_mp_props = props
	_mp_watch = WatchView.new()
	_mp_watch.name = "MPBeltWatchView"
	add_child(_mp_watch)

# Off in Early Access. This handed the game's belt watch one item per grid
# cell once a yard held 256 items, to save wake-up checks. EA's BeltWatch
# keeps its own grid (cells, halos, sleeping areas) and, given the thinned
# list, missed bales rolling into a machine's mouth: a wrapper with no player
# near slept and let them through unwrapped. The game's own check runs now.
const GROUP_IN_EA := false

# A guest's factory runs only to keep belts moving between the host's lists.
# When a frame runs long the engine catches up with up to four physics steps
# in the next one, each with a whole factory tick in it (about 55 ms in a big
# yard), which made the next frame longer still. On a guest the clock now ticks
# at most once per drawn frame and is handed the time it skipped.
var mp_guest := false
var _mp_frame := -1
var _mp_owed := 0.0
const MAX_STEP := 0.1

func _mp_timed_physics_process(delta: float) -> void:
	if mp_guest:
		_mp_owed += delta
		var frame := Engine.get_process_frames()
		if frame == _mp_frame:
			return
		_mp_frame = frame
		delta = minf(_mp_owed, MAX_STEP)
		_mp_owed = 0.0
	if not GROUP_IN_EA or not is_instance_valid(_mp_props) or not is_instance_valid(_mp_watch) or not Cells.should_group(_mp_props.items):
		super._physics_process(delta)
		return
	_mp_watch.items = Cells.representatives(_mp_props.items)
	_mp_watch.live = _mp_props.live
	var original := BeltWatch._props(get_tree())
	BeltWatch._props_ref = _mp_watch
	super._physics_process(delta)
	BeltWatch._props_ref = original
	_mp_watch.items.clear()

func mp_watch_stop() -> void:
	if is_instance_valid(_mp_watch):
		if BeltWatch._props_ref == _mp_watch:
			BeltWatch._props_ref = _mp_props
		_mp_watch.items.clear()
		_mp_watch.live = null
		_mp_watch.queue_free()
	_mp_watch = null
	_mp_props = null


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	__MPCost.in_clock = true
	_mp_timed_physics_process(delta)
	__MPCost.in_clock = false
	__MPCost.add("factory_clock(physics)", Time.get_ticks_usec() - __t)
