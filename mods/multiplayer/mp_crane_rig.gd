extends RefCounted

# The skyline crane's rig on a guest. A guest's crane is frozen, so it never
# posed its rig: swing, trolley, hoist and claw stood where the save left them
# while the host's crane swung out, bit and dumped (measured: host hoist block
# moving 1.5 -> 12.5 m in three seconds, guest's not moving at all). The host
# sends the rig's four numbers, whether it carries hay, and its hopper; the
# guest's rig walks to them through its own setters, so ropes, claw and load
# are drawn by the game's own code.

const EASE := 6.0     # per second; field ticks are 0.5 s apart
const SNAP_DEG := 90.0

var _goals := {}      # key -> {"crane": WeakRef, "want": Array}
var _bool_claw := {}  # script -> whether set_claw takes a bool


static func read(crane: Node) -> Variant:
	var rig: Variant = crane.get("_rig")
	if not is_instance_valid(rig):
		return null
	var load_on := false
	var ld: Variant = rig.get("_load")
	if ld is Node3D:
		load_on = (ld as Node3D).visible
	# the hopper as the crane shows it: what it has let go of so far over
	# what it holds (SkylineCrane._show_pose)
	var fill := 0.0
	var shown: Variant = crane.get("_fill_shown")
	if (shown is float or shown is int) and crane.has_method("hopper_capacity"):
		fill = maxf(float(shown), 0.0) / float(maxi(1, int(crane.hopper_capacity())))
	return [snappedf(float(rig.get("_swing")), 0.01), snappedf(float(rig.get("_trolley_t")), 0.001),
		snappedf(float(rig.get("_hoist")), 0.01), snappedf(float(rig.get("_claw")), 0.01), load_on,
		snappedf(fill, 0.01)]


static func valid(v: Variant) -> bool:
	if not (v is Array) or v.size() != 6 or not (v[4] is bool):
		return false
	for i in [0, 1, 2, 3, 5]:
		if not (v[i] is float or v[i] is int) or not is_finite(float(v[i])) or absf(float(v[i])) > 100000.0:
			return false
	return true


# Guest: what the host last said, which is what this side reads back.
func goal_of(key: String) -> Variant:
	var g: Dictionary = _goals.get(key, {})
	return g.get("want")


func apply(key: String, crane: Node, v: Variant) -> void:
	if not valid(v):
		return
	var rig: Variant = crane.get("_rig")
	if not is_instance_valid(rig):
		return
	var first := not _goals.has(key)
	var was: Variant = _goals.get(key, {}).get("want")
	_goals[key] = {"crane": weakref(crane), "want": (v as Array).duplicate()}
	# the guest's freeze paused every AnimationPlayer; the claw's is the rig's
	# own and only plays when set_claw asks it to
	var player: Variant = rig.get("_claw_player")
	if player is AnimationPlayer and (player as Node).process_mode == Node.PROCESS_MODE_DISABLED:
		(player as Node).process_mode = Node.PROCESS_MODE_INHERIT
	# the claw let go: the bite falls into the hopper, as on the host
	if was is Array and bool(was[4]) and not bool(v[4]) and rig.has_method("drop_load") and rig.has_method("heap_top_y"):
		rig.drop_load(rig.heap_top_y(clampf(float(v[5]), 0.0, 1.0)), func() -> void: pass)
	if rig.has_method("set_load"):
		var ld: Variant = rig.get("_load")
		if not (ld is Node3D) or (ld as Node3D).visible != bool(v[4]):
			rig.set_load(bool(v[4]))
	if rig.has_method("set_hopper"):
		rig.set_hopper(clampf(float(v[5]), 0.0, 1.0))
	if first:
		_pose(rig, float(v[0]), float(v[1]), float(v[2]), float(v[3]))


func step(delta: float) -> void:
	if _goals.is_empty():
		return
	var k := 1.0 - exp(-EASE * delta)
	for key in _goals.keys():
		var g: Dictionary = _goals[key]
		var crane: Variant = g.crane.get_ref()
		if not is_instance_valid(crane) or not crane.is_inside_tree():
			_goals.erase(key)
			continue
		var rig: Variant = crane.get("_rig")
		if not is_instance_valid(rig):
			continue
		var want: Array = g.want
		var swing := float(rig.get("_swing"))
		var turn := wrapf(float(want[0]) - swing, -180.0, 180.0)
		var trolley := float(rig.get("_trolley_t"))
		var hoist := float(rig.get("_hoist"))
		var claw := float(rig.get("_claw"))
		if absf(turn) < 0.005 and absf(float(want[1]) - trolley) < 0.0005 and absf(float(want[2]) - hoist) < 0.005 and absf(float(want[3]) - claw) < 0.005:
			continue
		if absf(turn) > SNAP_DEG:
			_pose(rig, float(want[0]), float(want[1]), float(want[2]), float(want[3]))
			continue
		_pose(rig, swing + turn * k, lerpf(trolley, float(want[1]), k), lerpf(hoist, float(want[2]), k), lerpf(claw, float(want[3]), k))


func _pose(rig: Node, swing: float, trolley: float, hoist: float, claw: float) -> void:
	var span := float(rig.get("span")) if rig.get("span") != null else 0.0
	if rig.has_method("pose") and span > 0.0:
		# pose() takes the trolley as metres along the span
		rig.pose(swing, trolley * span, hoist)
	else:
		if rig.has_method("set_swing"):
			rig.set_swing(swing)
		if rig.has_method("set_trolley"):
			rig.set_trolley(trolley)
		if rig.has_method("set_hoist"):
			rig.set_hoist(hoist)
	if rig.has_method("set_claw"):
		var scr: Script = rig.get_script()
		if not _bool_claw.has(scr):
			var as_bool := false
			for m in scr.get_script_method_list():
				if m.name == "set_claw" and m.args.size() == 1:
					as_bool = int(m.args[0].type) == TYPE_BOOL
			_bool_claw[scr] = as_bool
		if _bool_claw[scr]:
			rig.set_claw(claw > 0.5)
		else:
			rig.set_claw(claw)


func clear() -> void:
	_goals.clear()
