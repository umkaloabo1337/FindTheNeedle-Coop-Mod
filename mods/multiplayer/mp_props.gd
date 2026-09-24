extends Node

# Loose item replication.
#
# Every prop in the yard gets an id. The peer that made it owns it and is the
# only one that sends its movement; everyone else keeps a frozen copy that
# follows along. Picking up an item somebody else owns takes it over, so the
# item keeps moving for everybody while you carry it.
#
# The host is the reference: a joining client throws its own props away and
# rebuilds the list the host sends.

const MOVE_TICK := 0.1
const STATE_TICK := 1.0
const CENSUS_TICK := 6.0
const MOVE_EPS := 0.005
const BASIS_EPS := 0.01
const MOVE_BUDGET := 60
const STATE_BUDGET := 20
const RESET_BATCH := 30
const SMOOTH := 16.0
# tool items and the avatar tool that draws them, see _hide_held_tools
const TOOL_ITEMS := {"spade": 1, "pitchfork": 2, "broom": 3, "sand_shovel": 4,
	"metal_detector": 5, "yard_vac": 6}
const HELD_TICK := 0.2

var mp: Node
var world: Node
var props: Node

var _by_id := {}     # mp id -> Carryable
var _owner := {}     # mp id -> peer id
var _sent := {}      # mp id -> last transform we broadcast
var _hash := {}      # mp id -> hash of the last state we broadcast
var _goal := {}      # mp id -> transform a remote copy is easing towards
var _want := {}      # mp id -> peer we expect it from
var _next := 0
var _ready_map := false
var _busy := false   # we are the ones touching the prop list, do not echo it
var _move_t := 0.0
var _state_t := 0.0
var _census_t := 0.0
var _held_t := 0.0
var _hidden := {}   # mp id -> true while we hide a copy someone is carrying
var _log := OS.get_environment("MP_DEBUG_PROPS") != ""  # dev tracing


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	props = world.get("props")
	if props == null or not is_instance_valid(props):
		return
	props.item_added.connect(_on_added)
	props.item_removed.connect(_on_removed)
	var carry: Variant = _carry_tool()
	if carry != null:
		carry.carry_changed.connect(_on_carry_changed)
	session_started()


# The host can also open a session from inside a world, after this node is up.
func session_started() -> void:
	if mp.is_host and not _ready_map:
		_adopt_all()
		_ready_map = true


func shutdown() -> void:
	if props == null or not is_instance_valid(props):
		return
	if props.item_added.is_connected(_on_added):
		props.item_added.disconnect(_on_added)
	if props.item_removed.is_connected(_on_removed):
		props.item_removed.disconnect(_on_removed)
	var carry: Variant = _carry_tool()
	if carry != null and carry.carry_changed.is_connected(_on_carry_changed):
		carry.carry_changed.disconnect(_on_carry_changed)
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it != null and is_instance_valid(it):
			_release(it)
			if _hidden.has(id):
				it.visible = true
	_hidden.clear()
	_by_id.clear()
	_owner.clear()
	_goal.clear()


func _carry_tool() -> Variant:
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return null
	var c: Variant = pl.get("carry")
	if c == null or not is_instance_valid(c) or not c.has_signal("carry_changed"):
		return null
	return c


func _me() -> int:
	return multiplayer.get_unique_id()


func _new_id() -> int:
	_next += 1
	return _me() * 1000000 + _next


# ------------------------------------------------------------------ bookkeeping

func _adopt_all() -> void:
	for item in props.items:
		if is_instance_valid(item) and not item.has_meta("mp_id"):
			_adopt(item, _new_id(), _me())


func _adopt(item: Node, id: int, owner: int) -> void:
	item.set_meta("mp_id", id)
	_by_id[id] = item
	_owner[id] = owner
	_want.erase(id)
	if owner == _me():
		_release(item)
	else:
		_puppet(item)


func _forget(id: int) -> void:
	_hidden.erase(id)
	_by_id.erase(id)
	_owner.erase(id)
	_sent.erase(id)
	_hash.erase(id)
	_goal.erase(id)


# A copy owned by somebody else: no physics of its own, and off limits to the
# yard cleaner and to the machines that go looking for loose hay.
func _puppet(item: Node) -> void:
	item.set_meta("mp_copy", true)
	item.set_meta(PropManager.META_CLAIM, get_instance_id())
	item.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	item.freeze = true
	item.set_physics_process(false)


func _release(item: Node) -> void:
	if not item.has_meta("mp_copy"):
		return
	item.remove_meta("mp_copy")
	if item.has_meta(PropManager.META_CLAIM) \
	and int(item.get_meta(PropManager.META_CLAIM)) == get_instance_id():
		item.remove_meta(PropManager.META_CLAIM)
	item.set_physics_process(true)
	item.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	if not item.is_held():
		item.freeze = false


func _mine(id: int) -> bool:
	return int(_owner.get(id, 0)) == _me()


# ------------------------------------------------------------------ local events

func _on_added(item: Node) -> void:
	if _busy or not _ready_map or item.has_meta("mp_id"):
		return
	var id := _new_id()
	_adopt(item, id, _me())
	_sent[id] = item.global_transform
	var st := _state_of(item)
	_hash[id] = st.hash()
	if _log:
		print("[MPPROPS] made %s id=%d at %v" % [item.item_id, id, item.global_position])
	mp._rx_prop_add.rpc(id, String(item.item_id), item.global_transform, st)


func _on_removed(item: Node) -> void:
	if not item.has_meta("mp_id"):
		return
	var id := int(item.get_meta("mp_id"))
	var mine := _mine(id)
	_forget(id)
	if _busy:
		return
	if _log:
		print("[MPPROPS] lost %s id=%d mine=%s" % [item.item_id, id, mine])
	if mine:
		mp._rx_prop_del.rpc(PackedInt64Array([id]))
	else:
		# a local machine ate a copy: ask for it back
		_want[id] = 0


# Taking an item somebody else owns makes it ours, so we are the one moving it.
func _on_carry_changed(item: Variant) -> void:
	if item == null or not is_instance_valid(item) or not item.has_meta("mp_id"):
		return
	var id := int(item.get_meta("mp_id"))
	if _mine(id):
		return
	_owner[id] = _me()
	_goal.erase(id)
	_release(item)
	mp._rx_prop_claim.rpc(id)


func _state_of(item: Node) -> Dictionary:
	var st: Dictionary = item.to_state()
	if item.holds_needle():
		st["needle"] = item.needle_index
	return st


# ------------------------------------------------------------------ ticks

func _process(delta: float) -> void:
	_smooth(delta)
	_held_t += delta
	if _held_t >= HELD_TICK:
		_held_t = 0.0
		_hide_held_tools()
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if not _ready_map:
		return
	_move_t += delta
	if _move_t >= MOVE_TICK:
		_move_t = 0.0
		_move_tick()
	_state_t += delta
	if _state_t >= STATE_TICK:
		_state_t = 0.0
		_state_tick()
	_census_t += delta
	if _census_t >= CENSUS_TICK:
		_census_t = 0.0
		_census_tick()


# A tool somebody else is carrying floats in front of their first-person view,
# but their farmer already draws it in its hand, so hide that copy while it's
# up there. Tools lying around, and every other item, stay visible.
func _hide_held_tools() -> void:
	var ws: Variant = mp.world_sync if mp != null else null
	var avatars: Dictionary = ws.avatars if ws != null and is_instance_valid(ws) else {}
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it):
			continue
		var tool: int = TOOL_ITEMS.get(String(it.item_id), 0)
		if tool == 0:
			continue
		var hide := false
		if not _mine(id):
			var av: Variant = avatars.get(int(_owner.get(id, 0)))
			if av != null and is_instance_valid(av) and int(av.get("_tool")) == tool:
				var off: Vector3 = it.global_position - av.global_position
				hide = off.y > 0.5 and Vector2(off.x, off.z).length() < 2.0
		if hide and not _hidden.has(id):
			_hidden[id] = true
			it.visible = false
		elif not hide and _hidden.has(id):
			_hidden.erase(id)
			it.visible = true


# Remote copies ease towards the last position we heard about instead of
# jumping ten times a second.
func _smooth(delta: float) -> void:
	if _goal.is_empty():
		return
	var f := minf(1.0, delta * SMOOTH)
	var done: Array = []
	for id in _goal:
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			done.append(id)
			continue
		var want: Transform3D = _goal[id]
		var step: Transform3D = it.global_transform.interpolate_with(want, f)
		it.global_transform = step
		if step.origin.distance_to(want.origin) < 0.002:
			it.global_transform = want
			done.append(id)
	for id in done:
		_goal.erase(id)


func _move_tick() -> void:
	var ids := PackedInt64Array()
	var xfs: Array = []
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _mine(id):
			continue
		var xf: Transform3D = it.global_transform
		var last: Variant = _sent.get(id)
		if last != null and _same(last, xf):
			continue
		_sent[id] = xf
		ids.append(id)
		xfs.append(xf)
		if ids.size() >= MOVE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_prop_move.rpc(ids, xfs)
	if not _want.is_empty():
		var asking := PackedInt64Array()
		for id in _want:
			asking.append(id)
		_want.clear()
		mp._rx_prop_want.rpc(asking)


func _same(a: Transform3D, b: Transform3D) -> bool:
	if a.origin.distance_squared_to(b.origin) > MOVE_EPS * MOVE_EPS:
		return false
	return a.basis.x.distance_squared_to(b.basis.x) < BASIS_EPS * BASIS_EPS \
		and a.basis.y.distance_squared_to(b.basis.y) < BASIS_EPS * BASIS_EPS


func _state_tick() -> void:
	var ids := PackedInt64Array()
	var states: Array = []
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _mine(id):
			continue
		var st := _state_of(it)
		var h := st.hash()
		if int(_hash.get(id, 0)) == h:
			continue
		_hash[id] = h
		ids.append(id)
		states.append(st)
		if ids.size() >= STATE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_prop_state.rpc(ids, states)


func _census_tick() -> void:
	var ids := PackedInt64Array()
	for id in _by_id:
		if _mine(id) and is_instance_valid(_by_id[id]):
			ids.append(id)
	mp._rx_prop_census.rpc(ids)


# ------------------------------------------------------------------ from the net

func on_add(sender: int, id: int, item_id: String, xf: Transform3D, state: Dictionary) -> void:
	var have: Variant = _by_id.get(id)
	if have != null and is_instance_valid(have):
		_goal[id] = xf
		return
	if not ItemDb.has_item(item_id):
		return
	_busy = true
	var it: Variant = props.spawn(item_id, xf, state)
	_busy = false
	if it != null:
		_adopt(it, id, sender)


func on_del(ids: PackedInt64Array) -> void:
	for id in ids:
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		_forget(id)
		if it != null and is_instance_valid(it):
			_busy = true
			props.remove(it)
			_busy = false


func on_move(sender: int, ids: PackedInt64Array, xfs: Array) -> void:
	for i in ids.size():
		var id: int = ids[i]
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			_want[id] = sender
			continue
		if int(_owner.get(id, 0)) != sender:
			_owner[id] = sender
			_puppet(it)
		if it.is_held():
			continue
		_goal[id] = xfs[i]


func on_state(sender: int, ids: PackedInt64Array, states: Array) -> void:
	for i in ids.size():
		var id: int = ids[i]
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			_want[id] = sender
			continue
		var st: Dictionary = states[i]
		it.from_state(st)
		it.needle_index = int(st.get("needle", -1))


func on_claim(sender: int, id: int) -> void:
	var it: Variant = _by_id.get(id)
	_owner[id] = sender
	_sent.erase(id)
	_goal.erase(id)
	if it == null or not is_instance_valid(it):
		return
	if sender == _me():
		_release(it)
	else:
		_puppet(it)


func on_want(sender: int, ids: PackedInt64Array) -> void:
	for id in ids:
		if not _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			continue
		mp._rx_prop_add.rpc_id(sender, id, String(it.item_id),
			it.global_transform, _state_of(it))


# The owner lists what it still has. Anything of theirs we are holding on to
# that is not on the list is gone; anything on the list we lack, we ask for.
func on_census(sender: int, ids: PackedInt64Array) -> void:
	var theirs := {}
	for id in ids:
		theirs[id] = true
	var drop: Array = []
	for id in _by_id:
		if int(_owner.get(id, 0)) == sender and not theirs.has(id):
			drop.append(id)
	for id in drop:
		var it: Variant = _by_id.get(id)
		_forget(id)
		if it != null and is_instance_valid(it):
			_busy = true
			props.remove(it)
			_busy = false
	var missing := PackedInt64Array()
	for id in ids:
		var it2: Variant = _by_id.get(id)
		if it2 == null or not is_instance_valid(it2):
			missing.append(id)
	if missing.size() > 0:
		mp._rx_prop_want.rpc_id(sender, missing)


# ------------------------------------------------------------------ joining

# Host side: hand a client the whole yard, in batches so no single packet gets
# out of hand. Sent right after the client reports it is in the world.
func send_all(pid: int) -> void:
	var ids := PackedInt64Array()
	var owners := PackedInt32Array()
	var entries: Array = []
	var first := true
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not it.is_inside_tree():
			continue
		ids.append(id)
		owners.append(int(_owner.get(id, 1)))
		entries.append({
			"id": String(it.item_id),
			"xform": it.global_transform,
			"state": _state_of(it),
		})
		if entries.size() >= RESET_BATCH:
			mp._rx_prop_reset.rpc_id(pid, first, ids, owners, entries)
			first = false
			ids = PackedInt64Array()
			owners = PackedInt32Array()
			entries = []
	mp._rx_prop_reset.rpc_id(pid, first, ids, owners, entries)
	mp._rx_prop_reset_end.rpc_id(pid)


func on_reset(first: bool, ids: PackedInt64Array, owners: PackedInt32Array, entries: Array) -> void:
	if first:
		_busy = true
		props.clear()
		_busy = false
		_by_id.clear()
		_owner.clear()
		_sent.clear()
		_hash.clear()
		_goal.clear()
		_want.clear()
	for i in ids.size():
		var e: Dictionary = entries[i]
		var item_id: String = e.get("id", "")
		if not ItemDb.has_item(item_id):
			continue
		_busy = true
		var it: Variant = props.spawn(item_id, e.get("xform", Transform3D.IDENTITY), e.get("state", {}))
		_busy = false
		if it != null:
			_adopt(it, ids[i], owners[i])


func on_reset_end() -> void:
	_ready_map = true


# A peer left: the host keeps their things and takes over sending them.
func peer_gone(pid: int) -> void:
	for id in _owner:
		if int(_owner[id]) != pid:
			continue
		_owner[id] = 1
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			continue
		if _me() == 1:
			_release(it)
			_sent.erase(id)
