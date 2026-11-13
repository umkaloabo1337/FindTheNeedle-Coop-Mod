extends Node
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

const ArmState = preload("res://mods/multiplayer/mp_arm_state.gd")
const ArmVisual = preload("res://mods/multiplayer/mp_arm_visual.gd")

var _shader_fields := preload("res://mods/multiplayer/mp_shader_fields.gd").new()
var _arm_visual := ArmVisual.new()
var _alert := preload("res://mods/multiplayer/mp_alert_sync.gd").new()
var _crane_rig := preload("res://mods/multiplayer/mp_crane_rig.gd").new()

const DroneState = preload("res://mods/multiplayer/mp_drone_state.gd")
const MachinePacket = preload("res://mods/multiplayer/mp_machine_packet.gd")
const DiagnosticState = preload("res://mods/multiplayer/mp_diagnostic_state.gd")
const FrameSlots = preload("res://mods/multiplayer/mp_frame_slots.gd")

# Machines.
#
# A machine runs on the host only, so the same hay cannot become two bales.
# That used to leave it standing still on everyone else's screen. The host now
# sends three things for each one:
#
#   * where its moving parts are, whatever drives them (the piston rake scrubs
#     an AnimationPlayer, the robotic arm drives its joints from code)
#   * which of its parts are visible and which particles are running, so smoke,
#     flames and lamps show up
#   * the handful of numbers that other systems read: fuel and output for the
#     generator, and every setting a panel can change
#
# Only what changed is sent, and only for machines somebody is standing near.

const TICK := 0.2  # was 0.125: a big yard sent ~570 pose packets a second; guests walk between poses over the measured gap
const FIELD_TICK := 0.5
const EDIT_TICK := 0.2    # how often a guest looks for a setting it changed
const FULL_TICK := 2.0    # how often every part goes out again, packets get lost
const RANGE := 24.0        # metres from a player before a machine is worth sending (32 sent twice as many in a big yard)
const MOVE_EPS := 0.0015
const ANG_EPS := 0.004
# a machine model carries a lot of nodes and the smoke and firebox sit well
# down the list, so do not cut the walk short
const MAX_PARTS := 120
const SMOOTH := 22.0
# Machines whose panel reads state that lives in their saved data (contents,
# progress, output). A guest's copy is frozen, so it takes the host's.
static func _saved_kind(n: Variant) -> bool:
	return n is Assembler or n is BriquettePress or n is HayCompressor or n is HayPelletizer 		or n is HayPulper or n is PaperMachine or (n is HayWrapper and not n is Depot)

const SAVED_SKIP := ["type", "position", "yaw", "paid", "gift", "off", "recipe"]
const MIN_WALK := 0.06
const MAX_WALK := 0.5
# Past this far from the camera a machine's parts jump to their pose instead
# of being walked there frame by frame: nobody sees the difference, and the
# walking was most of a guest's frame in a big yard.
const EASE_RANGE := 25.0
const MAX_RAW := 4 << 20

# What each kind of machine keeps that is worth copying: the numbers other
# parts of the game read (power, stock) and everything a settings panel can
# change. Read from the machine, written back through its setter when it has
# one.
const FIELDS := {
	"generators": ["fuel", "switched_off", "made_kw", "water", "mp_alert"],
	"silos": ["switched_off", "discharge_rate", "resume_rate", "stored", "queued", "mp_alert"],
	"splitters": ["forced_side", "priority_side", "next_side", "filters", "entry", "manual", "closed_lane", "fed", "stem_wait", "mp_t_revision", "mp_alert"],
	"joiners": ["out_lane", "manual", "next_side", "mp_t_revision"],
	"tube_launchers": ["switched_off", "aim", "power", "stored", "mp_alert"],
	"piston_rakes": ["switched_off", "throw_distance", "mp_alert"],
	"hay_drones": ["switched_off", "mode", "takes", "mp_zone", "mp_drop", "mp_drone_status", "mp_alert"],
	"pelletizers": ["switched_off", "throw_distance", "head_yaw", "stored", "mp_scrap_jam", "iron_points", "copper_points", "mp_saved", "mp_alert"],
	"robotic_arms": ["switched_off", "accept_mask", "tier_index", "paid_cost", "legacy_refit", "pick_order", "mp_links", "mp_arm_status"],
	"scanners": ["switched_off", "tier_index", "stored", "mp_alert"],
	"compressors": ["switched_off", "stored", "mp_scrap_jam", "water", "mp_saved", "mp_alert"],
	"pulpers": ["switched_off", "stored", "mp_taps", "mp_scrap_jam", "mp_saved", "mp_alert"],
	"papers": ["switched_off", "queued", "recipe", "paint", "water", "mp_saved", "mp_alert"],
	"briquette_presses": ["switched_off", "stored_strands", "stored_bricks", "mp_scrap_jam", "recipe", "mp_saved", "mp_alert"],
	"wrappers": ["switched_off", "queued", "emptying", "emptying_kinds", "mp_saved", "mp_alert"],
	"boreholes": ["switched_off", "mp_alert"],
	"dump_hatches": ["stored"],
	"needle_radars": ["cooldown"],
	"work_lamps": ["brightness", "_off"],
	"hay_excavators": ["switched_off", "throw_distance", "mp_tube", "mp_alert"],
	# the yard fan (EA) lives in the BuildManager's "extras" list
	"extras": ["switched_off", "turn", "tilt", "height", "strength"],
	"skyline_cranes": ["switched_off", "mp_crane_zone", "mp_crane_rig", "mp_alert"],
	"pipe_pumps": ["switched_off", "mp_alert"],
}

# Machines that keep running on clients but whose settings still have to match.
const SETTINGS_ONLY := ["work_lamps", "extras"]

# The areas a machine watches for something to eat. Named rather than walked,
# because a machine's other areas are the scanner's beam and the stairs' climb
# zone, which have nothing to do with taking hay in.
const MOUTHS := ["_intake", "_hopper", "_mouth", "_mouth_area", "_wad_mouth",
	"_brick_mouth", "_catch", "_payout_area", "_skirt_area"]
const MOUTH_TICK := 0.25

# What a panel lets a player change, as opposed to what a machine works out for
# itself. Only these travel back from a guest: fuel, stock, output and the rest
# are the host's to count, and taking a guest's word for them would let the
# same hay pay twice.
const SETTINGS := {
	"generators": ["switched_off"],
	"silos": ["switched_off", "discharge_rate", "resume_rate"],
	"joiners": ["out_lane", "manual"],
	"splitters": ["forced_side", "priority_side", "filters", "entry", "manual", "closed_lane"],
	"tube_launchers": ["switched_off", "aim", "power"],
	"piston_rakes": ["switched_off", "throw_distance"],
	"hay_drones": ["switched_off", "mode", "takes", "mp_zone", "mp_drop"],
	"pelletizers": ["switched_off", "throw_distance", "head_yaw", "mp_scrap_jam"],
	"robotic_arms": ["switched_off", "accept_mask", "pick_order", "mp_links"],
	"scanners": ["switched_off", "tier_index"],
	"compressors": ["switched_off", "mp_scrap_jam"],
	"pulpers": ["switched_off", "mp_scrap_jam"],
	"papers": ["switched_off", "recipe", "paint"],
	"briquette_presses": ["switched_off", "mp_scrap_jam", "recipe"],
	"wrappers": ["switched_off", "emptying", "emptying_kinds"],
	"boreholes": ["switched_off"],
	"work_lamps": ["brightness", "_off"],
	"hay_excavators": ["switched_off", "throw_distance", "mp_tube"],
	# the yard fan (EA) lives in the BuildManager's "extras" list
	"extras": ["switched_off", "turn", "tilt", "height", "strength"],
	"skyline_cranes": ["switched_off", "mp_crane_zone"],
	"pipe_pumps": ["switched_off"],
}

const FIELD_GROUPS := [["entry", "out_lane", "closed_lane", "forced_side", "priority_side", "next_side", "manual", "stem_wait", "mp_t_revision"],
	["discharge_rate", "resume_rate"]]

var mp: Node
var world: Node
var builds: Node

var _part_shapes := {}
var _parts := {}    # key -> Array[Node3D] in walk order
var _ids := {}      # key -> PackedInt32Array, each part named by its path
var _slot := {}     # key -> {part id: index into _parts}
var _sent := {}     # key -> {part id: last transform broadcast}
var _pose_interest := {}
var _full := false  # this tick, send every part again
var _full_due_at := {}
var _refresh_t := 0.0
var _log := OS.get_environment("MP_DEBUG_PROPS") != ""
var _fx := {}       # key -> per part: its light and its shader values
var _fx_sent := {}  # key -> {"part:slot": last value sent}
var _flags := {}    # key -> PackedByteArray last broadcast
var _vals := {}     # key -> Dictionary of fields last broadcast
var _goal := {}     # key -> {part index: Transform3D}
var _pose_at := {}  # guest: key -> msec its last poses came
var _pose_gap := {} # guest: key -> how far apart its poses come, seconds
var _driving := {}  # guest: rake instance id -> weakref, driving along with the host
var _transport_memo := {}  # part instance id -> is a transport part (cleared on rescan)
# Host: a bale wrapper that sits still while bales wait is written to the
# trace with its state, so a "wrapper lets bales through" report says why.
const STUCK_TICK := 10.0
const STUCK_AFTER := 3  # ticks with nothing changing
var _stuck_t := 0.0
var _stuck := {}  # key -> [state seen, ticks unchanged]
var _nodes := {}    # key -> machine node
var _group := {}    # key -> which build array it came from
var _scan_t := 0.0
var _scan_slot := FrameSlots.new()
var _t := 0.0
var _pose_slot := FrameSlots.new()
var _second_half_due := false
var _field_t := 0.0
var _edit_t := 0.0
var _mouth_t := 0.0
var _pending_settings := {}
var _queued_settings := {}
var _applying_fields := false
var _processor_hooks := {}
var _junction_hooks := {}
var _processors_enabled := false
var _theirs := {}   # guest: key -> the settings as the host last stated them
var _rescan_at := -100000  # msec, last rescan forced by a key we did not know
# a key naming a machine we do not have (yet): skip it until then instead of
# walking every machine again for every packet that mentions it
const UNKNOWN_KEY_WAIT := 1000
var _unknown_noted := {}
const KEY_SLACK := 0.25   # metres: the same machine, placed on both sides
const BIG_PACKET := 1000  # compressed bytes; past this a packet goes reliable


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	builds = world.get("builds")
	_processors_enabled = true
	set_process(true)
	get_tree().node_added.connect(_processor_added)
	builds.changed.connect(_protect_processors)
	_rescan()


func shutdown() -> void:
	_arm_visual.clear()
	_crane_rig.clear()
	_alert.clear(_replace_processor_script)
	_processors_enabled = false
	set_process(false)
	if is_instance_valid(builds) and builds.changed.is_connected(_protect_processors):
		builds.changed.disconnect(_protect_processors)
	if is_inside_tree() and get_tree().node_added.is_connected(_processor_added):
		get_tree().node_added.disconnect(_processor_added)
	for saved in _processor_hooks.values():
		var node: Variant = saved["node"].get_ref()
		if is_instance_valid(node) and node.get_script() == saved["replacement"]:
			_replace_processor_script(node, load(mp.base_dir + "/mp_arm_exit.gd") if node is RoboticArm else saved["original"])
			if node is HayLift or node is HayStairs:
				node._follow_tech()
			_refresh_processor_belt(node)
	_processor_hooks.clear()
	for saved in _junction_hooks.values():
		var helper: Variant = saved.helper.get_ref()
		if is_instance_valid(helper) and helper.get_script() == saved.replacement:
			_replace_junction_script(helper, saved.original)
	_junction_hooks.clear()
	_pending_settings.clear()
	_queued_settings.clear()
	_parts.clear()
	_part_shapes.clear()
	_fx.clear()
	_shader_fields.clear()
	_ids.clear()
	_slot.clear()
	_sent.clear()
	_pose_interest.clear()
	_second_half_due = false
	_flags.clear()
	_vals.clear()
	_goal.clear()
	_nodes.clear()
	# walk the models again: the game adds and drops nodes as it runs
	_parts.clear()
	_fx.clear()
	_shader_fields.clear()
	_ids.clear()
	_slot.clear()
	_group.clear()


# ------------------------------------------------------------------ the parts

# Every machine worth sending, under a key both sides work out the same way:
# the array it lives in and where it stands.
func _rescan() -> void:
	var __t0 := Time.get_ticks_usec()
	_rescan_inner()
	__MPCost.add("machines.rescan", Time.get_ticks_usec() - __t0)


func _rescan_inner() -> void:
	if not _processors_enabled or not is_instance_valid(mp) or not is_instance_valid(builds):
		return
	var ws: Node = mp.world_sync
	if not is_instance_valid(ws) or ws.get("world") != world:
		return
	for id in _processor_hooks.keys():
		if not is_instance_valid(_processor_hooks[id]["node"].get_ref()):
			_processor_hooks.erase(id)
	for id in _junction_hooks.keys():
		if not is_instance_valid(_junction_hooks[id].helper.get_ref()):
			_junction_hooks.erase(id)
	for key in _pending_settings.keys():
		if Time.get_ticks_msec() - int(_pending_settings[key].time) > 10000:
			_pending_settings.erase(key)
	var groups: Array = ws.get_script().get_script_constant_map().get("CLIENT_FROZEN", [])
	_transport_memo.clear()
	var previous_nodes := _nodes.duplicate()
	_nodes.clear()
	# walk the models again: the game adds and drops nodes as it runs
	_fx.clear()
	_shader_fields.clear()
	_group.clear()
	for group in groups + SETTINGS_ONLY:
		var arr: Variant = builds.get(group)
		if not (arr is Array):
			continue
		for n in arr:
			if is_instance_valid(n) and n is Node3D and n.is_inside_tree() and not n.is_queued_for_deletion():
				_protect_processor(n)
				if not mp.is_host and FIELDS.get(String(group), []).has("mp_alert") and n.is_node_ready() \
						and n.get("placement_preview") != true:
					_alert.wrap(n, _replace_processor_script)
				var key := _key(String(group), n)
				if previous_nodes.get(key) != n:
					for cache in [_parts, _ids, _slot, _part_shapes, _sent, _flags, _vals, _goal, _fx_sent, _theirs, _pose_at, _pose_gap]:
						cache.erase(key)
					_queued_settings.erase(key)
					for pending_key in _pending_settings.keys():
						if str(pending_key).begins_with(key + "|"):
							_pending_settings.erase(pending_key)
				_nodes[key] = n
				_group[key] = String(group)
	# a machine gone since: its walk is out of date at once
	for key in _parts.keys():
		if not is_instance_valid(_nodes.get(key)):
			_forget_parts(key)
	# forget machines that are gone (this used to run over _parts after it was
	# cleared, so it never did anything and every demolished machine's state
	# stayed behind for good)
	for d in [_sent, _flags, _vals, _goal, _fx_sent, _theirs, _pose_at, _pose_gap]:
		for key in (d as Dictionary).keys():
			if not _nodes.has(key):
				(d as Dictionary).erase(key)
	_arm_visual.prune(_nodes)
	_alert.prune()


func _forget_parts(key: String) -> void:
	_parts.erase(key)
	_ids.erase(key)
	_slot.erase(key)
	_part_shapes.erase(key)


# Whether each machine still has the parts we walked: the game adds and drops
# nodes of its own as it runs. This used to walk every machine again on every
# rescan, 35-40 ms at once every two seconds in a big yard (a stutter you
# could feel); now a few machines a frame, within a small budget.
var _part_checks: Array = []
var _part_check_at := 0  # msec, when the last round started
const PART_CHECK_USEC := 1000
const PART_CHECK_EVERY := 2000  # msec between rounds, as the rescan had it

func _check_parts_step() -> void:
	if _part_checks.is_empty():
		if _parts.is_empty() or Time.get_ticks_msec() - _part_check_at < PART_CHECK_EVERY:
			return
		_part_check_at = Time.get_ticks_msec()
		_part_checks = _parts.keys()
	var until := Time.get_ticks_usec() + PART_CHECK_USEC
	while not _part_checks.is_empty() and Time.get_ticks_usec() < until:
		var key: String = _part_checks.pop_back()
		if not _parts.has(key):
			continue
		var node: Variant = _nodes.get(key)
		if not is_instance_valid(node):
			_forget_parts(key)
			continue
		var current: Array = []
		_walk(node, current)
		if _parts[key] != current or _part_shapes.get(key, []) != DiagnosticState.machine_shape(node, current):
			_forget_parts(key)
			_fx.erase(key)


# Our key for a machine the host named: both sides place it from the same save
# data and build the key from where it stands, so an exact match is expected
# (not one miss in test runs with the host's big yard). A key that matches nothing
# waits a second before the next rescan, and is written down once.
# A field that reads back different from what the host sent: written down once
# per machine kind and field, so a sync warning says what it was about.
var _field_miss_noted := {}
func _note_field_miss(key: String, field: String, want: Variant, have: Variant) -> void:
	var at := key.get_slice("|", 0) + "|" + field
	if _field_miss_noted.has(at) or mp == null or mp.trace == null:
		return
	_field_miss_noted[at] = true
	mp.trace.note("machine field differs after applying %s %s: host %s, here %s" % [key, field, str(want).left(300), str(have).left(300)])


func _local_key(key: String) -> String:
	if _nodes.has(key):
		return key
	var now := Time.get_ticks_msec()
	if now - _rescan_at >= UNKNOWN_KEY_WAIT:
		_rescan_at = now
		if mp != null and mp.trace != null and not _unknown_noted.has(key):
			_unknown_noted[key] = true
			mp.trace.note("unknown machine key %s, rescanning" % key)
		_rescan()
		if _nodes.has(key):
			return key
	return ""


func _key(group: String, n: Node3D) -> String:
	var p := n.global_position
	return "%s|%.4f,%.4f,%.4f|%.5f" % [group, p.x, p.y, p.z, wrapf(n.rotation.y, -PI, PI)]


# The model's own nodes, in tree order. Both sides build the machine from the
# same code, so the same walk gives the same list and an index is enough.
func _parts_of(key: String) -> Array:
	if _parts.has(key):
		return _parts[key]
	var out: Array = []
	var ids := PackedInt32Array()
	var slot := {}
	var n: Variant = _nodes.get(key)
	if n != null and is_instance_valid(n):
		# from the machine itself, not from its model: the fire, the lamps and
		# the smoke column are made in code and hang off the machine, so a walk
		# that started at the model never saw them
		var base: Node = n as Node
		_walk(base, out)
		# A part is named by where it hangs, not by its place in the list: the
		# game adds and removes nodes of its own (alert markers, dust, range
		# rings), and a machine with one more of those would otherwise hand
		# every pose to the wrong part and come out crooked.
		for i in out.size():
			# 31 bits: these ids travel in a signed 32-bit array, and a hash that
			# spills over the sign bit would arrive as a different number and
			# match nothing. It cost half the parts of every machine.
			var id := int(_part_path(base, out[i]).hash()) & 0x7fffffff
			ids.append(id)
			slot[id] = i
	_parts[key] = out
	_part_shapes[key] = DiagnosticState.machine_shape(n, out) if is_instance_valid(n) else []
	_ids[key] = ids
	_slot[key] = slot
	return out


func _ids_of(key: String) -> PackedInt32Array:
	_parts_of(key)
	return _ids.get(key, PackedInt32Array())


func _slot_of(key: String) -> Dictionary:
	_parts_of(key)
	return _slot.get(key, {})


func _walk(n: Node, out: Array, checked: Variant = null) -> void:
	if checked == null:
		checked = {}
	for child in n.get_children():
		if out.size() >= MAX_PARTS:
			return
		if child is Node3D and not child.is_queued_for_deletion() and not _is_transport_part(child, checked):
			out.append(child)
			_walk(child, out, checked)


# ------------------------------------------------------------------ ticks

func _mp_timed_process(delta: float) -> void:
	if not _processors_enabled:
		return
	_ease(delta)
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_check_parts_step()
	if not mp.is_host:
		_step_driving(delta)
		# a guest works the panels on its own copy, which the machine itself
		# ignores, so watch for what the player changed and hand it to the host
		_scan_t += delta
		if _scan_t >= 2.0 and _scan_slot.take():
			_scan_t = 0.0
			_rescan()
		_edit_t += delta
		if _edit_t >= EDIT_TICK:
			_edit_t = 0.0
			_send_edits()
		return
	if mp.players.size() < 2:
		return
	_scan_t += delta
	var rescanned := false
	if _scan_t >= 2.0 and _scan_slot.take():
		_scan_t = 0.0
		_rescan()
		rescanned = true
	_t += delta
	if _second_half_due:
		if not rescanned and _pose_slot.take():
			_second_half_due = false
			_send_poses(1)
	elif _t >= TICK and not rescanned and _pose_slot.take():
		_t = 0.0
		_refresh_t += TICK
		_full = _refresh_t >= FULL_TICK
		if _full:
			_refresh_t = 0.0
			_vals.clear()
			_schedule_full_refresh()
		_send_poses(0)
		_second_half_due = true
	_field_t += delta
	if _field_t >= FIELD_TICK:
		_field_t = 0.0
		_send_fields()
	_stuck_t += delta
	if _stuck_t >= STUCK_TICK:
		_stuck_t = 0.0
		_watch_wrappers()
	_mouth_t += delta
	if _mouth_t >= MOUTH_TICK:
		_mouth_t = 0.0
		_feed_mouths()


func _watchers() -> Array:
	var ws: Node = mp.world_sync
	return ws.network_watchers() if is_instance_valid(ws) else []


func _near(at: Vector3, watchers: Array) -> bool:
	return preload("res://mods/multiplayer/mp_view_interest.gd").near(at, watchers, RANGE)


func _connected_peers() -> PackedInt32Array:
	return multiplayer.get_peers()


func _pose_audience() -> Dictionary:
	var audience := {}
	var ws: Node = mp.world_sync
	if not is_instance_valid(ws):
		return audience
	for peer_id in _connected_peers():
		if peer_id == 1 or not mp.players.has(peer_id) or mp.players[peer_id].get("state") != "world":
			continue
		var watchers: Array = []
		var avatar: Variant = ws.avatars.get(peer_id)
		if is_instance_valid(avatar) and avatar.is_inside_tree():
			watchers.append(avatar.global_position)
		if ws._build_views.has(peer_id):
			watchers.append(ws._build_views[peer_id])
		var keys := {}
		for key in _nodes:
			var node: Variant = _nodes[key]
			if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion() \
					and not SETTINGS_ONLY.has(_group.get(key, "")) and _near(node.global_position, watchers):
				keys[key] = node.get_instance_id()
		audience[peer_id] = keys
	return audience


func _schedule_full_refresh() -> void:
	var now_msec := Time.get_ticks_msec()
	var span := maxi(1, int(FULL_TICK * 1000.0) - int(TICK * 1000.0))
	for key in _nodes:
		_full_due_at[key] = now_msec + posmod(abs(String(key).hash()), span)
	for key in _full_due_at.keys():
		if not _nodes.has(key):
			_full_due_at.erase(key)


func _in_half(key: String, half: int) -> bool:
	return half < 0 or (key.hash() & 1) == half


func _merge_interest(audience: Dictionary, half: int) -> Dictionary:
	if half < 0:
		return audience
	var merged := {}
	for peer_id in audience:
		var keys := {}
		var before: Dictionary = _pose_interest.get(peer_id, {})
		for key in before:
			if not _in_half(key, half):
				keys[key] = before[key]
		for key in audience[peer_id]:
			if _in_half(key, half):
				keys[key] = audience[peer_id][key]
		merged[peer_id] = keys
	return merged


func _send_poses(half: int = -1) -> void:
	var transport_checks := {}
	var audience := _pose_audience()
	var now_msec := Time.get_ticks_msec()
	var wanted := {}
	var refresh := {}
	for peer_id in audience:
		var before: Dictionary = _pose_interest.get(peer_id, {})
		for key in audience[peer_id]:
			if not _in_half(key, half):
				continue
			wanted[key] = true
			if before.get(key) != audience[peer_id][key]:
				refresh[key] = true
	_pose_interest = _merge_interest(audience, half)
	if wanted.is_empty():
		return
	var batch := {}
	for key in _nodes:
		if SETTINGS_ONLY.has(_group.get(key, "")):
			continue
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree() or n.is_queued_for_deletion():
			continue
		if not wanted.has(key):
			continue
		var full := refresh.has(key)
		if not full and _full_due_at.has(key) and now_msec >= int(_full_due_at[key]):
			# the periodic resend of everything: it repeats every FULL_TICK,
			# so it may be lost like any move. Only a machine a player just
			# came near (refresh) has to arrive. Marking these reliable made
			# nearly every pose packet reliable (480 a second in a big yard),
			# and Steam queued them up until even picking something up took
			# seconds.
			full = true
			_full_due_at[key] = now_msec + int(FULL_TICK * 1000.0)
		var parts := _parts_of(key)
		if parts.is_empty():
			continue
		# Every part now and then, not only the ones that just moved: poses go
		# out on an unreliable channel, and a part that moves once and stops
		# would stay wrong on the other screen for good if that packet was
		# lost. It also puts right anything that started out differently.
		var last: Dictionary = _sent.get(key, {})
		if full:
			last = {}
		var part_ids := _ids_of(key)
		var flags := PackedByteArray()
		flags.resize(parts.size())
		var moved := PackedInt32Array()
		var rows := PackedFloat32Array()
		for i in parts.size():
			var part: Variant = parts[i]
			if not is_instance_valid(part) or not (part is Node3D) or not part.is_inside_tree() \
					or part.is_queued_for_deletion() or not n.is_ancestor_of(part) or _transport_cached(part, transport_checks):
				continue
			var node := part as Node3D
			flags[i] = _flags_of(node)
			var xf: Transform3D = node.transform
			var was: Variant = last.get(part_ids[i])
			if was != null and _same(was, xf):
				continue
			last[part_ids[i]] = xf
			moved.append(part_ids[i])
			# the whole basis, not a rotation and a scale: some parts are
			# skewed and rebuilding them from a quaternion left them crooked
			rows.append_array(PackedFloat32Array([
				xf.origin.x, xf.origin.y, xf.origin.z,
				xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
				xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
				xf.basis.z.x, xf.basis.z.y, xf.basis.z.z]))
		_sent[key] = last
		var entry := {}
		if n is RoboticArm:
			var visual := _arm_visual.capture(key, n, full)
			if not visual.is_empty():
				entry["a"] = visual
		if moved.size() > 0:
			entry["i"] = moved
			entry["t"] = rows
		if full or _flags.get(key, PackedByteArray()) != flags:
			_flags[key] = flags
			var fl := PackedInt32Array()
			for i in parts.size():
				fl.append(part_ids[i])
				fl.append(flags[i])
			entry["f"] = fl
		var fx_ids := PackedInt32Array()
		var fx_vals := PackedFloat32Array()
		_read_fx(key, fx_ids, fx_vals, full)
		if fx_vals.size() > 0:
			entry["xi"] = fx_ids
			entry["xv"] = fx_vals
		if not entry.is_empty():
			batch[key] = entry
	if batch.is_empty():
		return
	if _log and _full:
		for key in batch:
			var e: Dictionary = batch[key]
			print("[MPMACH] send %s moved=%d flags=%d fx=%d" % [key,
				(e.get("i", PackedInt32Array()) as PackedInt32Array).size(),
				(e.get("f", PackedInt32Array()) as PackedInt32Array).size() / 2,
				(e.get("xv", PackedFloat32Array()) as PackedFloat32Array).size()])
	var groups := {}
	for peer_id in audience:
		var keys := PackedStringArray()
		for key in audience[peer_id]:
			if batch.has(key):
				keys.append(key)
		if keys.is_empty():
			continue
		keys.sort()
		var signature := "\n".join(keys)
		if not groups.has(signature):
			# what has to arrive goes on its own, so it does not make the
			# moves of every other machine in the packet reliable too
			var moves := {}
			var musts := {}
			for key in keys:
				if refresh.has(key):
					musts[key] = batch[key]
				else:
					moves[key] = batch[key]
			groups[signature] = {"moves": moves, "musts": musts, "peers": []}
		groups[signature].peers.append(peer_id)
	for group in groups.values():
		for part in [[group.moves, false], [group.musts, true]]:
			if part[0].is_empty():
				continue
			if mp.over_steam:
				_send_small(part[0], group.peers, part[1])
			else:
				_send_one(part[0], group.peers, part[1])


# Over Steam, in small pieces. Every guest crash over Steam came right after a
# big machine update arrived (up to 9 KB in one message), and over a direct
# connection it has never happened, so over Steam no message gets that big:
# each machine's parts, flags and effects are split into pieces a guest can
# apply one by one, and packed into messages of about a kilobyte.
const PIECE_PARTS := 40  # parts per piece: 10 made a big arm or machine several messages a tick
const PIECE_PAIRS := 40
const SMALL_PACKET := 1800  # compressed bytes a pose message aims at; 900 made hundreds of tiny messages a second

func _send_small(batch: Dictionary, peers: Array, force_reliable: bool = false) -> void:
	var pieces: Array = []  # [key, sub entry]
	for key in batch:
		var e: Dictionary = batch[key]
		if e.has("a"):
			for visual in ArmVisual.pieces(e.a):
				pieces.append([key, {"a": visual}])
		if e.has("f"):
			var f: PackedInt32Array = e["f"]
			for a in range(0, f.size(), PIECE_PAIRS * 2):
				pieces.append([key, {"f": f.slice(a, a + PIECE_PAIRS * 2)}])
		if e.has("xi") and e.has("xv"):
			var xi: PackedInt32Array = e["xi"]
			var xv: PackedFloat32Array = e["xv"]
			for a in range(0, xv.size(), PIECE_PAIRS):
				pieces.append([key, {"xi": xi.slice(a * 2, (a + PIECE_PAIRS) * 2),
					"xv": xv.slice(a, a + PIECE_PAIRS)}])
		if e.has("i") and e.has("t"):
			var ids: PackedInt32Array = e["i"]
			var rows: PackedFloat32Array = e["t"]
			for a in range(0, ids.size(), PIECE_PARTS):
				pieces.append([key, {"i": ids.slice(a, a + PIECE_PARTS),
					"t": rows.slice(a * 12, (a + PIECE_PARTS) * 12)}])
	var out := {}
	var size := 0
	for p in pieces:
		var key: String = p[0]
		if out.has(key):
			_send_one(out, peers, force_reliable)
			out = {}
			size = 0
		out[key] = p[1]
		# the size so far, added up piece by piece: serialising the whole
		# message again after every piece cost the host more the bigger the
		# yard got
		size += var_to_bytes(p[1]).size() + key.length() + 16
		if size > SMALL_PACKET * 3:
			# ~3:1 compression on these; keep what is sent near a kilobyte
			_send_one(out, peers, force_reliable)
			out = {}
			size = 0
	if not out.is_empty():
		_send_one(out, peers, force_reliable)


func _send_one(batch: Dictionary, peers: Array, force_reliable: bool = false) -> void:
	var raw := var_to_bytes(batch)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	# the periodic full refresh has to arrive; the moves in between may drop
	var reliable: bool = force_reliable or _has_arm_geometry(batch) or (not mp.over_steam and packed.size() > BIG_PACKET)
	var connected := _connected_peers()
	for peer_id in peers:
		if not connected.has(peer_id):
			continue
		if reliable:
			mp._rx_machines_big.rpc_id(peer_id, packed, raw.size(), mp._outgoing_world_seed())
		else:
			mp._rx_machines.rpc_id(peer_id, packed, raw.size(), mp._outgoing_world_seed())


func _has_arm_geometry(batch: Dictionary) -> bool:
	for entry in batch.values():
		if entry.has("a") and entry.a.has("d"):
			return true
	return false


# bit 0: the part is drawn. bit 1: its particles are running.
func _flags_of(n: Node3D) -> int:
	var f := 1 if n.visible else 0
	if n is GPUParticles3D:
		f |= 2 if (n as GPUParticles3D).emitting else 0
	elif n is CPUParticles3D:
		f |= 2 if (n as CPUParticles3D).emitting else 0
	return f


func _same(a: Transform3D, b: Transform3D) -> bool:
	if a == b:
		return true
	if a.origin.distance_squared_to(b.origin) > MOVE_EPS * MOVE_EPS:
		return false
	return a.basis.x.distance_squared_to(b.basis.x) < ANG_EPS * ANG_EPS \
		and a.basis.y.distance_squared_to(b.basis.y) < ANG_EPS * ANG_EPS \
		and a.basis.z.distance_squared_to(b.basis.z) < ANG_EPS * ANG_EPS


func _send_fields() -> void:
	var batch := {}
	for key in _nodes:
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n):
			continue
		var names: Array = FIELDS.get(_group.get(key, ""), [])
		if names.is_empty():
			continue
		var was: Dictionary = _vals.get(key, {})
		var now := {}
		var diff := {}
		for f in names:
			var v: Variant = _read_field(n, f)
			if v == null:
				continue
			now[f] = _copy_value(v)
			if not was.has(f) or was[f] != v:
				diff[f] = _copy_value(v)
		_vals[key] = now
		if not diff.is_empty():
			_complete_fields(n, diff, names)
			batch[key] = diff
	if batch.is_empty():
		return
	mp._rx_machine_fields.rpc(batch, mp._outgoing_world_seed())


# ------------------------------------------------------------------ from the net

func _mp_timed_on_poses(packed: PackedByteArray, raw_size: int) -> void:
	if __MPCost.is_off("poses"):
		return
	if raw_size <= 0 or raw_size > MAX_RAW:
		_observe_packet(true)
		return
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		_observe_packet(true)
		return
	var batch: Variant = bytes_to_var(raw)
	if not MachinePacket.valid(batch):
		_observe_packet(true)
		return
	_observe_packet(false)
	for host_key in batch:
		var key := _local_key(String(host_key))
		if key == "":
			if _log:
				print("[MPMACH] got %s but no machine of mine matches" % host_key)
			continue
		var parts := _parts_of(key)
		if parts.is_empty():
			if _log:
				print("[MPMACH] got %s but walked no parts" % key)
			continue
		var slot := _slot_of(key)
		var entry: Dictionary = batch[host_key]
		if entry.has("a") and _nodes.get(key) is RoboticArm:
			_arm_visual.apply(key, _nodes[key], entry.a, float(_pose_gap.get(key, TICK)))
		if entry.has("f"):
			var flags: PackedInt32Array = entry["f"]
			var k := 0
			var hit := 0
			var lost := 0
			while k + 1 < flags.size():
				var at: int = int(slot.get(flags[k], -1))
				if at >= 0 and at < parts.size():
					var part: Variant = parts[at]
					if is_instance_valid(part) and part is Node3D and (_flags_of(part) == flags[k + 1] or _live_part(key, part)):
						_set_flags(part as Node3D, flags[k + 1])
						hit += 1
				else:
					lost += 1
				k += 2
			if _log and lost > 0:
				print("[MPMACH] %s flags: %d placed, %d with no part here (I walked %d)" % [
					key, hit, lost, parts.size()])
		if entry.has("xi") and entry.has("xv"):
			on_fx(key, entry["xi"], entry["xv"])
		if not entry.has("t") or not entry.has("i"):
			continue
		var moved: PackedInt32Array = entry["i"]
		var rows: PackedFloat32Array = entry["t"]
		# how long to walk to this pose: the time the poses actually take to
		# come, not the tick they are meant to come at. With a fixed tick a
		# late packet left an arm standing and the next one made it jump.
		var now_ms := Time.get_ticks_msec()
		if _pose_at.has(key):
			# a machine standing still sends nothing; that pause is no gap
			var raw_gap := float(now_ms - int(_pose_at[key])) / 1000.0
			if raw_gap <= MAX_WALK:
				_pose_gap[key] = lerpf(float(_pose_gap.get(key, TICK)), clampf(raw_gap, MIN_WALK, MAX_WALK), 0.3)
		_pose_at[key] = now_ms
		var want: Dictionary = _goal.get(key, {})
		var cam := get_viewport().get_camera_3d()
		var machine: Variant = _nodes.get(key)
		var walk_it := cam == null or not (machine is Node3D) 			or (machine as Node3D).global_position.distance_squared_to(cam.global_position) <= EASE_RANGE * EASE_RANGE
		for j in moved.size():
			var r := j * 12
			if r + 11 >= rows.size():
				break
			if not slot.has(moved[j]):
				continue
			var to := Transform3D(Basis(
					Vector3(rows[r + 3], rows[r + 4], rows[r + 5]),
					Vector3(rows[r + 6], rows[r + 7], rows[r + 8]),
					Vector3(rows[r + 9], rows[r + 10], rows[r + 11])),
				Vector3(rows[r], rows[r + 1], rows[r + 2]))
			var part_id: int = moved[j]
			var at: int = int(slot[part_id])
			if at < 0 or at >= parts.size() or not is_instance_valid(parts[at]) or not (parts[at] is Node3D):
				want.erase(part_id)
				continue
			var part := parts[at] as Node3D
			var from: Transform3D = part.transform
			if from.is_equal_approx(to):
				want.erase(part_id)
				continue
			if not _live_part(key, part):
				want.erase(part_id)
				continue
			if not walk_it:
				part.transform = to
				want.erase(part_id)
				continue
			var current: Variant = want.get(part_id)
			if current is Array and current.size() == 4 and (current[1] as Transform3D).is_equal_approx(to) and is_same(current[3].get_ref(), part):
				continue
			# Walk from where the part is now to where it has got to, over the
			# gap between packets. Chasing the newest pose with a fixed pull
			# made every arm and grabber move in steps.
			want[part_id] = [from, to, 0.0, weakref(part)]
		if want.is_empty():
			_goal.erase(key)
		else:
			_goal[key] = want


func _set_flags(n: Node3D, f: int) -> void:
	var on := (f & 1) != 0
	if n.visible != on:
		n.visible = on
	var running := (f & 2) != 0
	if n is GPUParticles3D and (n as GPUParticles3D).emitting != running:
		(n as GPUParticles3D).emitting = running
	elif n is CPUParticles3D and (n as CPUParticles3D).emitting != running:
		(n as CPUParticles3D).emitting = running


func _mp_timed_on_fields(batch: Dictionary) -> void:
	if not mp.is_host:
		_send_edits()
	var diagnostic_errors := 0
	var junctions: Array = []
	for host_key in batch:
		var key := _local_key(String(host_key))
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n):
			diagnostic_errors += 1
			continue
		if not (batch[host_key] is Dictionary):
			continue
		var junction_before := _junction_state(n)
		var diff: Dictionary = batch[host_key]
		# remember what the host says, so a guest can tell a setting the player
		# just changed from one the host handed down
		var known: Dictionary = _theirs.get(key, {})
		var checked := {}
		var held := _held_fields(key, diff)
		for f in _ordered_fields(diff):
			if f in held:
				continue
			if not FIELDS.get(_group.get(key, ""), []).has(f):
				continue
			if f == "mp_arm_status" and not ArmState.valid(diff[f]):
				diagnostic_errors += 1
				continue
			if n is HayDrone and not DroneState.valid(str(f), diff[f]):
				diagnostic_errors += 1
				continue
			var pending_key := key + "|" + str(f)
			var pending: Dictionary = _pending_settings.get(pending_key, {})
			if not pending.is_empty():
				if pending.value != diff[f] and Time.get_ticks_msec() - int(pending.time) < 2000:
					continue
				_pending_settings.erase(pending_key)
			_apply_field(n as Node, String(f), diff[f])
			known[String(f)] = _copy_value(diff[f])
			# a saved state read back need not match key for key
			if f != "mp_saved":
				checked[String(f)] = diff[f]
		_theirs[key] = known
		if _junction_state(n) != junction_before:
			junctions.append(n)
		for f in checked:
			var matches: bool = _tap_state_matches(n, checked[f]) if f == "mp_taps" else _read_field(n, f) == checked[f]
			if not matches:
				diagnostic_errors += 1
				_note_field_miss(key, String(f), checked[f], _read_field(n, f))
	_rewire_junctions(junctions)
	if is_instance_valid(mp.world_sync) and "diagnostics" in mp.world_sync and is_instance_valid(mp.world_sync.diagnostics):
		mp.world_sync.diagnostics.observe("machines", diagnostic_errors > 0, diagnostic_errors)


# Guest: anything in SETTINGS that no longer matches what the host last told us
# is something the player just did on a panel. Send it and remember it as the
# new agreed value, so a switch does not go out again every tick while we wait
# for the host to echo it back.
func apply_power_switches(states: Dictionary) -> void:
	for node in states:
		if is_instance_valid(node) and node.has_method("set_switched_off") and bool(node.is_switched_off()) != states[node]:
			_applying_fields = true
			node.set_switched_off(states[node])
			_applying_fields = false
	for key in _nodes:
		var node: Variant = _nodes[key]
		if not states.has(node):
			continue
		var field := "_off" if _group.get(key) == "work_lamps" else "switched_off"
		if not FIELDS.get(_group.get(key, ""), []).has(field):
			continue
		var known: Dictionary = _theirs.get(key, {})
		known[field] = states[node]
		_theirs[key] = known
		_pending_settings.erase(key + "|" + field)
		if _queued_settings.has(key):
			_queued_settings[key].fields.erase(field)
			if _queued_settings[key].fields.is_empty():
				_queued_settings.erase(key)

func _send_edits() -> void:
	var batch := {}
	for key in _queued_settings:
		var queued: Dictionary = _queued_settings[key]
		var n: Variant = queued.node.get_ref()
		if not is_instance_valid(n) or _nodes.get(key) != n:
			continue
		var known: Dictionary = _theirs.get(key, {})
		for field in queued.fields:
			known[field] = _copy_value(queued.fields[field])
		_theirs[key] = known
		batch[key] = queued.fields.duplicate(true)
	_queued_settings.clear()
	for key in _nodes:
		var names: Array = SETTINGS.get(_group.get(key, ""), [])
		if names.is_empty():
			continue
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n):
			continue
		# nothing from the host yet: we have no idea what it thinks, so a
		# difference here would be our own ignorance, not the player's doing
		var known: Dictionary = _theirs.get(key, {})
		if known.is_empty():
			continue
		var diff := {}
		for f in names:
			if not known.has(f):
				continue
			var v: Variant = _read_field(n, f)
			if v == null or v == known[f]:
				continue
			if f == "mp_scrap_jam" and not _guest_cleared_jam(v, known[f]):
				continue
			diff[f] = _copy_value(v)
		if not diff.is_empty():
			_complete_fields(n, diff, names)
			for f in diff:
				_pending_settings[key + "|" + str(f)] = {"value": _copy_value(diff[f]), "time": Time.get_ticks_msec()}
				known[f] = _copy_value(diff[f])
			if batch.has(key):
				batch[key].merge(diff, true)
			else:
				batch[key] = diff
	if batch.is_empty():
		return
	mp._rx_machine_edit.rpc_id(1, batch, mp._outgoing_world_seed())
	if _log:
		print("[MPMACH] guest sent %d machine edits" % batch.size())


func queue_setting(node: Node, field: String, value: Variant) -> void:
	if _applying_fields or not is_instance_valid(mp) or not mp.active() or mp.is_host:
		return
	if not is_instance_valid(node) or not node.is_inside_tree() or node.is_queued_for_deletion():
		return
	var group := "pelletizers"
	if node is RoboticArm:
		if field != "mp_links" or not value is Array or value.size() > 128:
			return
		for link in value:
			if not link is Dictionary or link.get("role") not in ["take", "put"] or not link.get("at") is Vector3 or not link.at.is_finite():
				return
		group = "robotic_arms"
	elif field not in ["throw_distance", "head_yaw", "switched_off"] or not node is HayPelletizer:
		return
	elif field == "switched_off":
		if not value is bool:
			return
	elif not (value is int or value is float) or not is_finite(float(value)):
		return
	var key := _key(group, node)
	if _nodes.get(key) != node:
		_rescan()
	if _nodes.get(key) != node:
		return
	if not _queued_settings.has(key):
		_queued_settings[key] = {"node": weakref(node), "fields": {}}
	_queued_settings[key].fields[field] = _copy_value(value)
	_pending_settings[key + "|" + field] = {"value": _copy_value(value), "time": Time.get_ticks_msec()}


# Host: hand the machines whatever a guest has put in their mouths. A copy
# somebody else owns is frozen, and a machine skips a frozen body that is not
# riding a belt, so a guest could load a generator all day and nothing burned.
# Taking the item over here lets the machine's own code do the rest.
func _feed_mouths() -> void:
	var props: Node = mp.world_sync.props_sync if mp.world_sync != null else null
	if props == null or not is_instance_valid(props):
		return
	# loose straw thrown in by a guest, not only their items
	var straws: Node = mp.world_sync.strands_sync
	var watchers := _watchers()
	if watchers.is_empty():
		return
	var feeders: Array = _nodes.values()
	var stand: Node = builds.get("stand") as Node if is_instance_valid(builds) else null
	if is_instance_valid(stand):
		feeders.append(stand)
	var hoppers: Variant = mp.world_sync.get("hoppers_sync")
	if is_instance_valid(hoppers) and is_instance_valid(hoppers.sale_stations):
		for row in hoppers.sale_stations.serialize().get("rows", []):
			var station: Node = hoppers.sale_stations.model(row.id)
			if is_instance_valid(station) and station != stand:
				feeders.append(station)
	for n in feeders:
		if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		if not _near((n as Node3D).global_position, watchers):
			continue
		for mouth in MOUTHS:
			var a: Variant = (n as Node).get(mouth)
			if not (a is Area3D) or not (a as Area3D).is_inside_tree():
				continue
			for body in (a as Area3D).get_overlapping_bodies():
				if not props.host_take(body) and straws != null and is_instance_valid(straws):
					straws.host_take(body)

	for id in props._by_id.keys():
		var container: Variant = props._by_id.get(id)
		if not props._mine(id) or not is_instance_valid(container) or not container.is_inside_tree():
			continue
		if not container.has_method("takes_loose") or not container.takes_loose():
			continue
		var interior: Variant = container.get("_interior")
		if not (interior is Area3D) or not interior.is_inside_tree():
			continue
		for body in interior.get_overlapping_bodies():
			if not props.host_take(body) and is_instance_valid(straws):
				straws.host_take(body)


# Host: a guest worked a panel. The machine is ours to run, so apply it here and
# the next field tick hands it to everyone, the guest who asked included.
func on_edit(from: int, batch: Dictionary) -> void:
	if not mp.is_host or not mp.players.has(from):
		return
	for guest_key in batch:
		var key := _local_key(String(guest_key))
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n):
			continue
		var names: Array = SETTINGS.get(_group.get(key, ""), [])
		if not (batch[guest_key] is Dictionary):
			continue
		var diff: Dictionary = batch[guest_key]
		if not _t_edit_matches(n, diff):
			_vals.erase(key)
			continue
		var was: Dictionary = _vals.get(key, {})
		for f in _ordered_fields(diff):
			if (n is ConveyorTSplitter or n is ConveyorTJoiner) and f in ["entry", "out_lane", "manual", "closed_lane"]:
				continue
			# only ever the settings: a guest does not get to set our stock
			if names.has(String(f)):
				_apply_field(n as Node, String(f), diff[f])
			# forget what we last sent for it either way, so the next field
			# tick states our value again: that is what puts a guest back in
			# line when we would not take the change
			was.erase(String(f))
		_vals[key] = was


func _t_edit_matches(node: Node, fields: Dictionary) -> bool:
	var required: Array = []
	if node is ConveyorTSplitter:
		required = ["entry", "manual", "closed_lane"]
	elif node is ConveyorTJoiner:
		required = ["out_lane", "manual"]
	for field in required:
		if not fields.has(field) or fields[field] != node.get(field):
			return false
	return true


func _junction_state(node: Node) -> PackedInt32Array:
	if node is ConveyorTSplitter:
		return PackedInt32Array([node.entry, int(node.manual), node.closed_lane])
	if node is ConveyorTJoiner:
		return PackedInt32Array([node.out_lane, int(node.manual)])
	return PackedInt32Array()


func _rewire_junctions(nodes: Array) -> void:
	if nodes.is_empty() or not is_instance_valid(builds):
		return
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion():
			builds.refit_runs_at(node.ports())
			YardPorts.touch()
			BuildManager.jx_note(node)
	builds.rebuild_junctions()
	builds.changed.emit()
	_rescan()


func _complete_fields(n: Node, diff: Dictionary, allowed: Array) -> void:
	for group in FIELD_GROUPS:
		var changed := false
		for field in group:
			if diff.has(field) and field not in ["next_side", "stem_wait"]:
				changed = true
		if not changed:
			continue
		for field in group:
			if field in allowed:
				var value: Variant = _read_field(n, field)
				if value != null:
					diff[field] = _copy_value(value)


func _held_fields(key: String, diff: Dictionary) -> Array:
	var held: Array = []
	for field in diff:
		var pending: Dictionary = _pending_settings.get(key + "|" + str(field), {})
		if not pending.is_empty() and pending.value != diff[field] and Time.get_ticks_msec() - int(pending.time) < 2000:
			held.append(field)
	for group in FIELD_GROUPS:
		var blocked := false
		for field in group:
			if field in held:
				blocked = true
		if blocked:
			for field in group:
				if field not in held:
					held.append(field)
	return held


func _ordered_fields(diff: Dictionary) -> Array:
	var fields: Array = diff.keys()
	for field in ["out_lane", "entry"]:
		if fields.has(field):
			fields.erase(field)
			fields.push_front(field)
	for field in ["forced_side", "priority_side", "next_side", "stem_wait", "resume_rate"]:
		if fields.has(field):
			fields.erase(field)
			fields.append(field)
	return fields


func _tap_state(n: Node) -> Array:
	var out: Array = []
	for tap in n.taps:
		if is_instance_valid(tap) and not tap.is_queued_for_deletion() and not n.is_pending_tap(tap):
			out.append([tap.position, -tap.basis.z])
	return out


func _tap_state_matches(n: Node, value: Variant) -> bool:
	if not (value is Array):
		return false
	var current := _tap_state(n)
	if current.size() != value.size():
		return false
	for i in current.size():
		if not (value[i] is Array) or value[i].size() != 2:
			return false
		for side in 2:
			if not (value[i][side] is Vector3) or not value[i][side].is_finite():
				return false
			if current[i][side].distance_to(value[i][side]) >= 0.00001:
				return false
	return true


func _same_tap(tap: Node3D, data: Array) -> bool:
	return tap.position.distance_to(data[0]) < 0.00001 and (-tap.basis.z).distance_to(data[1]) < 0.00001


func _apply_taps(n: Node, value: Variant) -> void:
	if not (value is Array) or value.size() > 4096:
		return
	for data in value:
		if not (data is Array) or data.size() != 2:
			return
		if not (data[0] is Vector3) or not (data[1] is Vector3) or not data[0].is_finite() or not data[1].is_finite():
			return
		if absf(data[1].length_squared() - 1.0) > 0.001 or absf(data[1].dot(Vector3.BACK)) > 0.999:
			return
	if _tap_state(n) == value:
		return
	var used: Array = []
	var changed := false
	for data in value:
		var found: Node3D = null
		for tap in n.taps:
			if is_instance_valid(tap) and not tap.is_queued_for_deletion() and tap not in used and _same_tap(tap, data):
				found = tap
				break
		if found == null:
			found = n.add_tap(data[0], data[1], false)
			changed = true
		elif n.is_pending_tap(found):
			n.commit_tap(found)
			changed = true
		used.append(found)
	for tap in n.taps.duplicate():
		if not is_instance_valid(tap):
			n.taps.erase(tap)
			changed = true
		elif tap not in used:
			if n.is_pending_tap(tap):
				used.append(tap)
			else:
				n.remove_tap(tap)
				changed = true
	if n.taps != used:
		n.taps.assign(used)
		changed = true
	if changed:
		builds.rebuild_water_joints()
		builds.changed.emit()


func _copy_value(value: Variant) -> Variant:
	if value is Array or value is Dictionary:
		return value.duplicate(true)
	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY and typeof(value) < TYPE_MAX:
		return value.duplicate()
	return value


func _read_field(n: Node, field: String) -> Variant:
	match field:
		"mp_arm_status": return n.mp_status_snapshot() if n.has_method("mp_status_snapshot") else ArmState.capture(n)
		"mp_drone_status": return DroneState.status(n)
		"mp_t_revision":
			return int(n.get_meta("mp_t_revision", 0)) if n is ConveyorTSplitter or n is ConveyorTJoiner else null
		"mp_links": return n.links_to_save()
		"mp_taps": return _tap_state(n)
		"mp_zone": return [n.zone_at, n.zone_r]
		"mp_crane_zone": return [n.zone_at, n.zone_radius] if "zone_radius" in n else null
		"mp_alert": return _alert.read(n) if mp.is_host else _alert.shown(n)
		"mp_crane_rig":
			if not (n is SkylineCrane):
				return null
			return _crane_rig.read(n) if mp.is_host else _crane_rig.goal_of(_key("skyline_cranes", n))
		"mp_saved":
			# EA assemblers (and the kiln and reactor built on them) keep their
			# slots, progress and output in state the panel reads; a guest's
			# copy is frozen, so it shows the host's saved state instead
			if not _saved_kind(n) or not n.has_method("to_dict"):
				return null
			var state: Dictionary = n.to_dict()
			for k in SAVED_SKIP:
				state.erase(k)
			return state
		"mp_tube":
			if not (n is HayExcavator):
				return null
			var saved: Dictionary = n.to_dict()
			return [saved.get("tube"), saved.get("aimed")]
		"mp_drop": return [n.drop_at, n.drop_kind]
		"_off": return n.get("_off")
		"mp_scrap_jam":
			var jam: Variant = n.get("scrap_jam")
			if not (jam is Object) or not jam.has_method("to_dict"):
				return null
			var state: Dictionary = jam.to_dict()
			# the decay ticks every frame; whole seconds are plenty and keep
			# the field quiet while nothing really changes
			if state.get("decay") is float:
				state["decay"] = snappedf(state["decay"], 1.0)
			return state
	return n.get(field)


# The kinds a depot empties, kept either as a list or as {kind: on}.
static func _kind_set(v: Variant) -> Dictionary:
	var out := {}
	if v is Dictionary:
		for id in v:
			if v[id]:
				out[id] = true
	elif v is Array or v is PackedInt32Array or v is PackedStringArray:
		for id in v:
			out[id] = true
	return out


# Metal stuck in a machine (EA v14): {meter, jammed, piece, decay}.
static func _valid_jam(v: Variant) -> bool:
	return v is Dictionary and v.get("jammed") is bool and v.get("meter") is int 		and v.get("piece") is String and String(v.get("piece")).length() <= 64 		and (v.get("decay") is float or v.get("decay") is int) and is_finite(float(v.get("decay")))


# A guest pulled the metal out: their copy is clear while the host still said
# jammed. Anything else about the jam is the host's to count.
static func _guest_cleared_jam(local: Variant, known: Variant) -> bool:
	return _valid_jam(local) and _valid_jam(known) and not bool(local.jammed) and bool(known.jammed)


func _apply_field(n: Node, f: String, v: Variant) -> void:
	var was_applying := _applying_fields
	_applying_fields = true
	_apply_field_value(n, f, v)
	_applying_fields = was_applying


func _apply_field_value(n: Node, f: String, v: Variant) -> void:
	if f == "mp_scrap_jam":
		var jam: Variant = n.get("scrap_jam")
		if not _valid_jam(v) or not (jam is Object) or not jam.has_method("from_dict"):
			return
		if mp.is_host:
			# only ever a clear, and only while it is still jammed here
			if bool(v.jammed) or not bool(jam.get("jammed")):
				return
		jam.from_dict(v)
		if not mp.is_host:
			# from_dict() settles the meter at once: a host's fresh 2 with its
			# decay just reset came out as 1 here, and the panel and the sync
			# check both saw a machine that differed (45 sync warnings in an
			# evening, every one of them this). Take the host's numbers as sent.
			if v.get("meter") is int or v.get("meter") is float:
				jam.set("meter", int(v.meter))
			if (v.get("decay") is float or v.get("decay") is int) and "_decay" in jam:
				jam.set("_decay", float(v.decay))
		return
	# EA machines that share a group with an older one: the assembler, kiln and
	# reactor (briquette presses), the fabricator and fibre machines (papers)
	# pick a recipe; a depot (wrappers) picks which kinds it empties.
	if f == "recipe":
		if not n.has_method("set_recipe") or not ((v is String and v.length() <= 64) or (v is StringName and String(v).length() <= 64) or (v is int and v >= -1 and v < 4096)):
			return
		if n.get("recipe") != v:
			n.set_recipe(v)
		return
	if f == "paint":
		if not n.has_method("set_paint") or not ((v is int and v >= -1 and v < 4096) or (v is String and v.length() <= 64) or v is Color):
			return
		if n.get("paint") != v:
			n.set_paint(v)
		return
	if f == "emptying":
		if not (v is bool) or not n.has_method("set_emptying"):
			return
		if n.get("emptying") != v:
			n.set_emptying(v)
		return
	if f in ["water", "iron_points", "copper_points"]:
		# the host's numbers, shown on a guest's panel
		if mp.is_host or not (v is int or v is float) or not is_finite(float(v)):
			return
		n.set(f, v)
		return
	if f == "emptying_kinds":
		if not n.has_method("set_emptying_kind") or not (v is Dictionary or v is Array or v is PackedInt32Array or v is PackedStringArray):
			return
		if v.size() > 256:
			return
		var want := _kind_set(v)
		var have := _kind_set(n.get("emptying_kinds"))
		for id in have:
			if not want.has(id):
				n.set_emptying_kind(id, false)
		for id in want:
			if not have.has(id):
				n.set_emptying_kind(id, true)
		return
	if f == "mp_arm_status":
		if not mp.is_host and n.has_method("mp_apply_status"):
			n.mp_apply_status(v)
		return
	if f == "banked" and n is HaystackScanner:
		return
	if f == "mp_t_revision":
		if not mp.is_host and v is int and v >= 0 and (n is ConveyorTSplitter or n is ConveyorTJoiner):
			n.set_meta("mp_t_revision", maxi(v, int(n.get_meta("mp_t_revision", 0))))
		return
	if f == "mp_taps":
		if not mp.is_host:
			_apply_taps(n, v)
		return
	if f in ["discharge_rate", "resume_rate", "throw_distance", "head_yaw", "out_lane", "entry"]:
		if not (v is int or v is float) or not is_finite(float(v)):
			return
	if f in ["out_lane", "entry"]:
		var setter := "set_out" if f == "out_lane" else "set_entry"
		if v != int(v) or int(v) < 0 or int(v) > 2 or not n.has_method(setter):
			return
		n.call(setter, int(v))
		return
	if f == "discharge_rate" and n.has_method("set_rate"):
		var resume: Variant = n.get("resume_rate")
		n.set_rate(float(v))
		if not mp.is_host:
			n.set(f, float(v))
			n.set("resume_rate", resume)
		return
	if f == "resume_rate" and n.has_method("rate_min") and n.has_method("rate_max"):
		n.set(f, clampf(float(v), n.rate_min(), n.rate_max()) if mp.is_host else float(v))
		return
	if n is HayDrone:
		if not DroneState.valid(f, v):
			return
		if not mp.is_host:
			DroneState.apply_snapshot(n, f, v)
			return
	if f == "mp_links" and n.has_method("load_links"):
		n.load_links(v)
		return
	if f == "mp_saved":
		if mp.is_host or not _saved_kind(n) or not (v is Dictionary) or v.size() > 64 or var_to_bytes(v).size() > 16384:
			return
		var mine: Dictionary = n.to_dict()
		var changed := false
		for k in v:
			if k in SAVED_SKIP:
				continue
			if mine.get(k) != v[k]:
				mine[k] = v[k]
				changed = true
		if changed:
			n.from_dict(mine)
		return
	if f == "mp_tube":
		# where the excavator's tube points, as its own save data has it
		if not (n is HayExcavator) or not (v is Array) or v.size() != 2 or not (v[1] is bool) or not (v[0] is Array) or v[0].size() != 4:
			return
		for x in v[0]:
			if not (x is float or x is int) or not is_finite(float(x)):
				return
		var saved: Dictionary = n.to_dict()
		if saved.get("tube") == v[0] and saved.get("aimed") == v[1]:
			return
		saved["tube"] = v[0]
		saved["aimed"] = v[1]
		n.from_dict(saved)
		return
	if n is YardFan and f in ["turn", "tilt", "height", "strength"]:
		if not (v is float or v is int) or not is_finite(float(v)) or absf(float(v)) > 1000.0:
			return
		if n.get(f) != v:
			n.call("set_" + f, float(v))
		return
	if f == "mp_alert":
		if not mp.is_host:
			_alert.apply(n, v)
		return
	if f == "mp_crane_rig":
		if not mp.is_host and n is SkylineCrane:
			_crane_rig.apply(_key("skyline_cranes", n), n, v)
		return
	if f == "mp_crane_zone":
		if v is Array and v.size() == 2 and v[0] is Vector3 and v[0].is_finite() and (v[1] is float or v[1] is int) 				and is_finite(float(v[1])) and float(v[1]) >= 0.0 and n.has_method("set_zone"):
			n.set_zone(v[0], float(v[1]))
		return
	if f == "mp_zone" and v is Array and v.size() == 2:
		if not (v[0] is Vector3) or not v[0].is_finite() or float(v[1]) <= 0:
			n.clear_zone()
		else:
			n.set_zone(v[0], float(v[1]))
		return
	if f == "mp_drop" and v is Array and v.size() == 2:
		if not (v[0] is Vector3) or not v[0].is_finite():
			n.clear_drop()
		else:
			n.set_drop(v[0], int(v[1]))
		return
	if f == "tier_index" and n.has_method("set_tier"):
		n.set_tier(int(v))
		return
	if f == "filters" and n.has_method("set_filter") and (v is Array or v is PackedInt32Array):
		for side in mini(v.size(), 3):
			n.set_filter(side, int(v[side]))
		return
	if f == "closed_lane" and n.has_method("set_closed"):
		n.set_closed(int(v))
		return
	var setter := "set_switched_off" if f == "_off" else "set_" + f
	if n.has_method(setter):
		n.call(setter, v)
	else:
		n.set(f, v)


# Parts ease towards the last pose we heard about, so ten packets a second
# still read as movement rather than stepping.
func _ease(delta: float) -> void:
	_arm_visual.step(delta)
	_crane_rig.step(delta)
	if _goal.is_empty():
		return
	var empty_keys: Array = []
	for key in _goal:
		var step_t := delta / float(_pose_gap.get(key, TICK))
		var parts := _parts_of(key)
		var slot := _slot_of(key)
		var want: Dictionary = _goal[key]
		var done: Array = []
		for part_id in want:
			var idx: int = int(slot.get(part_id, -1))
			if idx < 0 or idx >= parts.size():
				done.append(part_id)
				continue
			var part: Variant = parts[idx]
			if not _live_part(key, part):
				done.append(part_id)
				continue
			var walk: Array = want[part_id]
			if walk.size() != 4 or not is_same(walk[3].get_ref(), part):
				done.append(part_id)
				continue
			var from: Transform3D = walk[0]
			var to: Transform3D = walk[1]
			var t: float = minf(1.0, float(walk[2]) + step_t)
			walk[2] = t
			# axis by axis: interpolate_with would pull a skewed part through a
			# rotation it never had
			(part as Node3D).transform = Transform3D(Basis(
					from.basis.x.lerp(to.basis.x, t),
					from.basis.y.lerp(to.basis.y, t),
					from.basis.z.lerp(to.basis.z, t)),
				from.origin.lerp(to.origin, t))
			if t >= 1.0:
				done.append(part_id)
		for gone in done:
			want.erase(gone)
		if want.is_empty():
			empty_keys.append(key)
	for key in empty_keys:
		_goal.erase(key)


# Host: a bale leaving a wrapper's outfeed unwrapped is written down with the
# wrapper's state at that moment.
var _passes := {}  # wrapper instance id -> unwrapped bales seen leaving it

func _hook_wrapper_outfeed(w: Node) -> void:
	for c in w.get_children():
		if c is BeltPath and c.name == "OutfeedStub" and c.run.has_signal("handed_out"):
			# bound to the wrapper's id: a weakref is a new object every
			# time, so the check never matched and every look added one more
			# connection, all of them called for every bale
			var cb := _on_wrapper_handed_out.bind(w.get_instance_id())
			if not c.run.is_connected("handed_out", cb):
				c.run.connect("handed_out", cb)


func _on_wrapper_handed_out(_seq: int, kind: int, _strands: int, wrapper_id: int) -> void:
	var w: Variant = instance_from_id(wrapper_id)
	if not is_instance_valid(w) or mp.trace == null or kind < 0 or kind >= BeltRun.ITEM_IDS.size():
		return
	if BeltRun.ITEM_IDS[kind] != "hay_bale":
		return
	var id: int = w.get_instance_id()
	_passes[id] = int(_passes.get(id, 0)) + 1
	var n: int = _passes[id]
	if n == 1 or n % 20 == 0:
		mp.trace.note("wrapper let a bale through unwrapped (%d so far) %s: wrapping=%s progress=%.2f queued=%d waiting=%s released=%s off=%s power=%.2f blocked=%s full=%s" % [n,
			str((w as Node3D).global_position.snapped(Vector3.ONE * 0.1)), str(w.is_wrapping()), float(w.wrap_progress()), w.queued.size(),
			str(w.waiting_bales()), str(w.get("_released")), str(w.is_switched_off()), float(w.get("power")), str(w.get("power_blocked")),
			str(w.is_full() if w.has_method("is_full") else null)])


func _watch_wrappers() -> void:
	if mp.trace == null:
		return
	for key in _nodes:
		var n: Variant = _nodes[key]
		if not (n is HayWrapper) or n is Depot or not is_instance_valid(n):
			continue
		_hook_wrapper_outfeed(n)
		var waiting: int = int(n.waiting_bales()) if n.has_method("waiting_bales") else 0
		var state := [n.is_wrapping(), snappedf(float(n.wrap_progress()), 0.01), n.queued.size(), waiting,
			n.get("_released"), n.is_switched_off(), snappedf(float(n.get("power")), 0.01), n.get("power_blocked"),
			n.is_full() if n.has_method("is_full") else null, n.outfeed_hold() if n.has_method("outfeed_hold") else null]
		var seen: Array = _stuck.get(key, [null, 0])
		if seen[0] == state and (waiting > 0 or bool(state[0])):
			seen[1] = int(seen[1]) + 1
		else:
			seen = [state, 0]
		_stuck[key] = seen
		if int(seen[1]) == STUCK_AFTER:
			mp.trace.note("wrapper stuck %s: wrapping=%s progress=%s queued=%s waiting=%s released=%s off=%s power=%s blocked=%s full=%s outfeed_hold=%s" % ([str((n as Node3D).global_position.snapped(Vector3.ONE * 0.1))] + state))
	for key in _stuck.keys():
		if not _nodes.has(key):
			_stuck.erase(key)


# ------------------------------------------------------------------ piston rake driving

func _key_of(node: Node) -> String:
	for key in _nodes:
		if _nodes[key] == node:
			return key
	_rescan()
	for key in _nodes:
		if _nodes[key] == node:
			return key
	return ""


# The check the rake panel passes along: can the rake go there, and why not.
func _rake_check() -> Callable:
	var player: Variant = mp.world_sync.get("player") if is_instance_valid(mp.world_sync) else null
	var tool: Variant = player.get("build") if is_instance_valid(player) else null
	if is_instance_valid(tool) and tool.has_method("rake_drive_reason"):
		return Callable(tool, "rake_drive_reason")
	return func(_rake: Node, _to: Vector3) -> String: return ""


# Guest: the panel's drive button. True when it went to the host instead.
func rake_drive_remote(rake: Node, direction: float) -> bool:
	if not mp.active() or mp.is_host:
		return false
	var key := _key_of(rake)
	if key != "" and is_finite(direction):
		mp._rx_rake_drive.rpc_id(1, key, direction, mp._outgoing_world_seed())
	return true


# Host: a guest pressed drive.
func on_rake_drive(key: String, direction: float) -> void:
	if not mp.is_host or not is_finite(direction):
		return
	var rake: Variant = _nodes.get(_local_key(key))
	if rake is PistonRake and not rake.is_driving():
		rake.drive(clampf(direction, -1.0, 1.0), _rake_check())


# Host: a rake set off, whoever pressed it.
func rake_drive_started(rake: Node, direction: float) -> void:
	if not mp.active() or not mp.is_host:
		return
	var key := _key_of(rake)
	if key == "":
		return
	rake.set_meta("mp_drive_key", key)
	mp._rx_rake_drive_go.rpc(key, direction, mp._outgoing_world_seed())


# Host: the rake stopped; everyone puts theirs where ours is.
func rake_drive_finished(rake: Node) -> void:
	if not mp.active() or not mp.is_host or not rake.has_meta("mp_drive_key"):
		return
	var key := str(rake.get_meta("mp_drive_key"))
	rake.remove_meta("mp_drive_key")
	mp._rx_rake_drive_end.rpc(key, (rake as Node3D).global_transform, mp._outgoing_world_seed())
	_rescan()


# Guest: the host's rake set off, so ours drives along.
func on_rake_drive_go(key: String, direction: float) -> void:
	if mp.is_host or not is_finite(direction):
		return
	var rake: Variant = _nodes.get(_local_key(key))
	if not (rake is PistonRake) or rake.is_driving():
		return
	rake.set_meta("mp_drive_key", key)
	rake.set("mp_following", true)
	rake.drive(clampf(direction, -1.0, 1.0), _rake_check())
	rake.set("mp_following", false)
	if rake.is_driving():
		_driving[rake.get_instance_id()] = weakref(rake)


# Guest: where the host's rake stopped.
func on_rake_drive_end(key: String, xform: Transform3D) -> void:
	if mp.is_host or not xform.origin.is_finite():
		return
	var rake: Variant = null
	for id in _driving:
		var r: Variant = _driving[id].get_ref()
		if is_instance_valid(r) and str(r.get_meta("mp_drive_key", "")) == key:
			rake = r
			break
	if rake == null:
		rake = _nodes.get(_local_key(key))
	if not (rake is PistonRake):
		return
	_driving.erase(rake.get_instance_id())
	if rake.has_meta("mp_drive_key"):
		rake.remove_meta("mp_drive_key")
	if rake.is_driving():
		rake._drive_done()
	(rake as Node3D).global_transform = xform
	_rescan()


# A guest's rake is frozen (no _process), so its drive is stepped here.
func _step_driving(delta: float) -> void:
	for id in _driving.keys():
		var rake: Variant = _driving[id].get_ref()
		if not is_instance_valid(rake) or not rake.is_inside_tree() or not rake.is_driving():
			_driving.erase(id)
			continue
		rake._drive_step(delta)


# A client just arrived: forget what we think it knows, so the next ticks
# send every pose, flag and setting again.
func send_all(pid: int) -> void:
	_rescan()
	if pid > 0:
		_pose_interest.erase(pid)
	else:
		_pose_interest.clear()
	_vals.clear()


# ------------------------------------------------------------------ glow

# Smoke columns, fire glow and dials are driven by a shader value or a light's
# strength, not by a node moving, so a frozen machine looks cold without them.
# Work out once per part what it has, then send only what changed.
func _fx_of(key: String) -> Array:
	if _fx.has(key):
		return _fx[key]
	var out: Array = []
	for part in _parts_of(key):
		# the game frees some parts of its own (markers, rings) while it runs
		if part == null or not is_instance_valid(part):
			out.append(null)
			continue
		var node := part as Node3D
		var entry: Dictionary = {}
		if node is Light3D:
			entry["light"] = node
		var mat: Variant = _shader_of(node)
		if mat != null:
			var names: PackedStringArray = _shader_fields.names((mat as ShaderMaterial).shader)
			if names.size() > 0:
				entry["mat"] = mat
				entry["names"] = names
		out.append(entry if not entry.is_empty() else null)
	_fx[key] = out
	return out


func _shader_of(n: Node3D) -> Variant:
	if not (n is GeometryInstance3D):
		return null
	var g := n as GeometryInstance3D
	if g.material_override is ShaderMaterial:
		# the build hologram, while a machine is being put up: it belongs to
		# BuildFx, which hands the real material back when it is done
		if _is_build_glow(g.material_override):
			return null
		return g.material_override
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.get_surface_override_material_count() > 0 \
		and mi.get_surface_override_material(0) is ShaderMaterial:
			return mi.get_surface_override_material(0)
		if mi.mesh != null and mi.mesh.get_surface_count() > 0 \
		and mi.mesh.surface_get_material(0) is ShaderMaterial:
			return mi.mesh.surface_get_material(0)
	return null


# While a machine is being put up, BuildFx swaps every mesh's material for its
# green hologram and puts the real one back when it is done, but only on a
# mesh still wearing that hologram. We used to copy it as the part's "own"
# material, so the game never gave the real one back and the machine stayed a
# half-built hologram for good.
func _is_build_glow(mat: Variant) -> bool:
	return mat is ShaderMaterial and BuildFx._shader != null \
		and (mat as ShaderMaterial).shader == BuildFx._shader


# -1 as the slot means the light's strength, 0 and up are shader values
func _read_fx(key: String, ids: PackedInt32Array, vals: PackedFloat32Array, force_full: bool = false) -> void:
	var fx := _fx_of(key)
	var part_ids := _ids_of(key)
	var was: Dictionary = _fx_sent.get(key, {})
	if force_full:
		was = {}
	for i in fx.size():
		var entry: Variant = fx[i]
		if entry == null:
			continue
		var d: Dictionary = entry
		if d.has("light"):
			var light: Variant = d["light"]
			if is_instance_valid(light):
				_note_fx(part_ids[i], -1, (light as Light3D).light_energy, was, ids, vals)
		if not d.has("mat"):
			continue
		var mat: Variant = d["mat"]
		if not is_instance_valid(mat):
			continue
		var names: PackedStringArray = d["names"]
		for j in names.size():
			var v: Variant = (mat as ShaderMaterial).get_shader_parameter(names[j])
			if v == null:
				continue
			_note_fx(part_ids[i], j, float(v), was, ids, vals)
	_fx_sent[key] = was


func _note_fx(part_id: int, slot: int, v: float, was: Dictionary,
		ids: PackedInt32Array, vals: PackedFloat32Array) -> void:
	# a number, not "id:slot": formatting that string for every shader value
	# of every part ten times a second was half of what a host spent
	# sending machine poses
	var at: int = (part_id << 8) | (slot + 1)
	if was.has(at) and absf(float(was[at]) - v) < 0.004:
		return
	was[at] = v
	ids.append(part_id)
	ids.append(slot)
	vals.append(v)


func on_fx(key: String, ids: PackedInt32Array, vals: PackedFloat32Array) -> void:
	if ids.size() != vals.size() * 2:
		return
	var parts := _parts_of(key)
	var fx := _fx_of(key)
	var slot := _slot_of(key)
	var k := 0
	while k + 1 < ids.size() and k / 2 < vals.size():
		var at: int = int(slot.get(ids[k], -1))
		var which: int = ids[k + 1]
		var v: float = vals[k / 2]
		k += 2
		if not is_finite(v) or at < 0 or at >= fx.size() or fx[at] == null or at >= parts.size():
			continue
		var d: Dictionary = fx[at]
		if which < 0:
			if d.has("light") and is_instance_valid(d["light"]) and (d["light"] as Light3D).light_energy != v \
					and _live_part(key, parts[at]):
				(d["light"] as Light3D).light_energy = v
			continue
		if not d.has("mat") or not is_instance_valid(d["mat"]):
			continue
		var names: PackedStringArray = d["names"]
		if which < names.size():
			var existing: ShaderMaterial = d["mat"]
			if existing.get_shader_parameter(names[which]) == v:
				continue
			if not _live_part(key, parts[at]):
				continue
			var material := _own_material(key, at, d)
			if material != null:
				material.set_shader_parameter(names[which], v)


# A machine's shader material is often the mesh's own, shared by every copy of
# that machine, so one machine's smoke or glow set here showed on all of them.
# Give the part its own copy the first time we write to it.
func _own_material(key: String, at: int, d: Dictionary) -> ShaderMaterial:
	var mat: ShaderMaterial = d["mat"]
	var parts := _parts_of(key)
	if at < 0 or at >= parts.size() or parts[at] == null or not is_instance_valid(parts[at]) 	or not (parts[at] is GeometryInstance3D):
		return null
	if _shader_of(parts[at]) != mat or _is_build_glow(mat):
		return null
	if mat.has_meta("mp_own"):
		return mat
	# Work out where the copy goes before making it. A part whose mesh the
	# game is rebuilding has no surfaces for a moment; the copy made for it
	# used to be thrown away again, and that happened for every value the
	# host sent: some 2000 material copies a second in a big yard, most of
	# what a guest's frame cost.
	var g := parts[at] as GeometryInstance3D
	var whole := g.material_override == mat
	if not whole:
		if not (g is MeshInstance3D):
			return mat
		var mesh: Mesh = (g as MeshInstance3D).mesh
		if mesh == null or mesh.get_surface_count() == 0:
			return mat
		# EA machines build many parts in code and rebuild their meshes; such
		# a part can have no surfaces on the rendering side for a moment, and
		# a surface override then fails ("p_surface = 0 is out of bounds").
		# With one surface the whole-part override looks the same and always
		# takes.
		whole = mesh.get_surface_count() == 1 or mesh is ImmediateMesh
	var own := mat.duplicate() as ShaderMaterial
	own.set_meta("mp_own", true)
	if whole:
		g.material_override = own
	else:
		(g as MeshInstance3D).set_surface_override_material(0, own)
	d["mat"] = own
	return own


# Where a part hangs, as a name both sides work out the same way. Nodes the
# game builds in code get a generated name (@GPUParticles3D@27) that counts up
# differently on each machine, so those are placed by what they are and where
# they sit among their siblings instead.
func _part_path(base: Node, n: Node) -> String:
	var bits := PackedStringArray()
	var cur: Node = n
	while cur != null and cur != base:
		bits.append(_part_name(cur))
		cur = cur.get_parent()
	bits.reverse()
	return "/".join(bits)


func _part_name(n: Node) -> String:
	var nm := String(n.name)
	if not nm.begins_with("@"):
		return nm
	var parent := n.get_parent()
	if parent == null:
		return n.get_class()
	var seen := 0
	for child in parent.get_children():
		if child == n:
			break
		if child.get_class() == n.get_class():
			seen += 1
	return "%s#%d" % [n.get_class(), seen]


func _protect_processors() -> void:
	for group in ["compressors", "wrappers", "hay_drones", "robotic_arms", "hay_lifts", "hay_stairs", "scanners", "pelletizers", "joiners", "splitters", "piston_rakes"]:
		var nodes: Variant = builds.get(group)
		if nodes is Array:
			for node in nodes:
				_protect_processor(node)


func _processor_added(node: Node) -> void:
	if node is HayCompressor or node is HayWrapper or node is HayDrone or node is RoboticArm or node is HayLift or node is HayStairs or node is HaystackScanner or node is HayPelletizer or node is ConveyorJoiner or node is ConveyorSplitter or node is PistonRake:
		_protect_processor_deferred.call_deferred(weakref(node))


func _protect_processor_deferred(reference: WeakRef) -> void:
	var node: Variant = reference.get_ref()
	if is_instance_valid(node):
		_protect_processor(node)


func _protect_processor(node: Node) -> void:
	if not _processors_enabled or not is_instance_valid(node) or not node.is_inside_tree() or not node.is_node_ready() or node.is_queued_for_deletion():
		return
	_protect_junction(node)
	if not (node is HayCompressor or node is HayWrapper or node is HayDrone or node is RoboticArm or node is HayLift or node is HayStairs or node is HaystackScanner or node is HayPelletizer or node is ConveyorTSplitter or node is PistonRake):
		return
	if node.placement_preview:
		return
	var saved: Dictionary = _processor_hooks.get(node.get_instance_id(), {})
	# a guest's alert-sign script sits on top of the replacement; one put on
	# before the replacement comes off again first (the rescan puts it back)
	if _alert.wrapped(node) and (saved.is_empty() or _alert.base_of(node) != saved["replacement"]):
		_alert.unwrap(node, _replace_processor_script)
	var original: Script = _alert.base_of(node)
	if not saved.is_empty() and original == saved["replacement"]:
		_refresh_processor_belt(node)
		return
	if original == null:
		return
	var replacement: Script
	if original.resource_path == "res://scripts/build/conveyor_t_splitter.gd":
		replacement = load(mp.base_dir + "/mp_distributor_t_splitter.gd")
	elif original.resource_path == "res://scripts/build/hay_compressor.gd":
		replacement = load(mp.base_dir + "/mp_hay_compressor.gd")
	elif original.resource_path == "res://scripts/build/hay_wrapper.gd":
		replacement = load(mp.base_dir + "/mp_hay_wrapper.gd")
	elif original.resource_path == "res://scripts/build/hay_drone.gd":
		replacement = load(mp.base_dir + "/mp_hay_drone.gd")
	elif original.resource_path == "res://scripts/build/hay_pelletizer.gd":
		replacement = load(mp.base_dir + "/mp_hay_pelletizer.gd")
	elif original.resource_path == "res://scripts/build/hay_stairs.gd":
		replacement = load(mp.base_dir + "/mp_hay_stairs.gd")
	elif original.resource_path == "res://scripts/build/hay_lift.gd":
		replacement = load(mp.base_dir + "/mp_hay_lift.gd")
	elif original.resource_path in ["res://scripts/build/robotic_arm.gd", "res://mods/multiplayer/mp_arm_exit.gd"]:
		replacement = load(mp.base_dir + "/mp_robotic_arm.gd")
	elif original.resource_path == "res://scripts/build/haystack_scanner.gd":
		replacement = load(mp.base_dir + "/mp_haystack_scanner.gd")
	elif original.resource_path == "res://scripts/build/piston_rake.gd":
		replacement = load(mp.base_dir + "/mp_piston_rake.gd")
	else:
		return
	_replace_processor_script(node, replacement)
	if "mp_transport" in node:
		node.set("mp_transport", self)
	if node is HayLift or node is HayStairs:
		node._follow_tech()
	_processor_hooks[node.get_instance_id()] = {"node": weakref(node), "original": original, "replacement": replacement}
	_refresh_processor_belt(node)


func _protect_junction(node: Node) -> void:
	if not (node is ConveyorJoiner or node is ConveyorSplitter) or node.placement_preview or not "_jam" in node:
		return
	var helper: Variant = node.get("_jam")
	if not is_instance_valid(helper):
		return
	var original: Script = helper.get_script()
	if original == null or original.resource_path != "res://scripts/build/junction_jam.gd":
		return
	var replacement: Script = load(mp.base_dir + "/mp_junction_jam.gd")
	if replacement == null:
		return
	_replace_junction_script(helper, replacement)
	# A guest's junctions are frozen and its belts follow the host's: the
	# game's own unjam there pushed riders on that the host still had waiting,
	# 725 times in an evening against the host's 285, and every push came back
	# as a reset (belts and smart splitters jumping). Only the host unjams.
	helper.set("mp_guest", not mp.is_host)
	_junction_hooks[helper.get_instance_id()] = {"helper": weakref(helper), "original": original, "replacement": replacement}


func _replace_junction_script(helper: Object, script: Script) -> void:
	var values := {}
	for property in helper.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			values[property.name] = helper.get(property.name)
	helper.set_script(script)
	for key in values:
		if key in helper:
			helper.set(key, values[key])


func _replace_processor_script(node: Node, script: Script) -> void:
	var values := {}
	for property in node.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			values[property.name] = node.get(property.name)
	node.set_script(script)
	for key in values:
		if key in node:
			node.set(key, values[key])


func _refresh_processor_belt(node: Node) -> void:
	if node is HayDrone or node is RoboticArm or node is HayLift or node is HayStairs or node is HaystackScanner or node is HayPelletizer or node is ConveyorTSplitter:
		return
	var belt: Variant = node.get("_belt")
	if not is_instance_valid(belt) or not belt.is_inside_tree():
		return
	var parks := Callable(node, "_parks")
	# The demo's processors did not hold anything on their own belt, so the
	# mod made them hold what they park. Early Access machines set their own
	# hold when they build the belt; replacing it with the demo's rule let
	# bales run through a wrapper unwrapped wherever no player was near (out
	# there bales are records, and the hold is all that stops them). A belt
	# the game already holds is left alone.
	var native: Variant = belt.get("_eats")
	if native is Callable and (native as Callable).is_valid() and native != parks and bool(belt.get("_records_held")):
		return
	if belt.get("_eats") != parks or not bool(belt.get("_records_held")) \
			or belt.run.hold_for != Callable(belt, "_eats_kind"):
		belt.hold_records(parks)
	if node is HayCompressor:
		belt._sync_run_links()
		var holds := Callable(node, "_held_on_deck")
		if belt.get("_hold_for") != holds:
			belt.set_hold_filter(holds)


func _live_part(key: String, part: Variant) -> bool:
	if not _part_attached(key, part):
		return false
	# whether a part is a belt, a lift's load or an arm's hay hardly ever
	# changes; it was worked out again, walking up to the scene root, for every
	# part of every pose and every frame of every walk
	var id: int = (part as Node).get_instance_id()
	var known: Variant = _transport_memo.get(id)
	if known == null:
		known = _is_transport_part(part)
		_transport_memo[id] = known
	return not bool(known)

func _part_attached(key: String, part: Variant) -> bool:
	var machine: Variant = _nodes.get(key)
	return is_instance_valid(machine) and machine is Node3D \
		and machine.is_inside_tree() and not machine.is_queued_for_deletion() \
		and is_instance_valid(part) and part is Node3D \
		and part.is_inside_tree() and not part.is_queued_for_deletion() \
		and machine.is_ancestor_of(part)


# The same as _is_transport_part, remembered until the next rescan: whether a
# part is a belt, a lift's load or an arm's hay hardly ever changes, and the
# host asked it again for every part of every machine ten times a second.
func _transport_cached(part: Node, checked: Variant = null) -> bool:
	var id: int = part.get_instance_id()
	var known: Variant = _transport_memo.get(id)
	if known == null:
		known = _is_transport_part(part, checked)
		_transport_memo[id] = known
	return bool(known)


func _is_transport_part(part: Node, checked: Variant = null) -> bool:
	var current := part
	var visited: Array[Node] = []
	var found := false
	while is_instance_valid(current):
		if checked != null and checked.has(current):
			found = bool(checked[current])
			break
		if checked != null:
			visited.append(current)
		if current is BeltPath or current.name == "Marker_BeltIn" or current.name == "Marker_BeltOut" or current.has_meta("mp_lift_cargo") or current.has_meta("mp_arm_visual"):
			found = true
			break
		var parent := current.get_parent()
		# nothing above the machine can make a part of it a transport part
		if parent == null or parent == builds or parent == world:
			break
		if parent is RoboticArm and current == parent.get("_payload_visual"):
			found = true
			break
		if parent is HayPulper and current in parent.taps:
			found = true
			break
		if parent is HayLift or parent is HayStairs:
			for carried in parent._carried:
				if carried.get("draw") == current:
					found = true
					break
		if found:
			break
		current = parent
	if checked != null:
		for node in visited:
			checked[node] = found
	return found


func _observe_packet(rejected: bool) -> void:
	if is_instance_valid(mp.world_sync) and is_instance_valid(mp.world_sync.diagnostics):
		mp.world_sync.diagnostics.observe("machines", rejected, 1 if rejected else 0, 1)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_process(delta)
	__MPCost.add("machines", Time.get_ticks_usec() - __t)


func on_poses(packed: PackedByteArray, raw_size: int) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_on_poses(packed, raw_size)
	__MPCost.add("machines.on_poses", Time.get_ticks_usec() - __t)


func on_fields(batch: Dictionary) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_on_fields(batch)
	__MPCost.add("machines.on_fields", Time.get_ticks_usec() - __t)
