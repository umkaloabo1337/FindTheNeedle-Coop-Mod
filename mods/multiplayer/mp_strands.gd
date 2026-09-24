extends Node

# Loose straw.
#
# Every player's dig throws hundreds of straws around, and until now each
# player only saw their own: the floor was covered on one screen and clean on
# the other. The peer that made a straw sends where it is; everyone else keeps
# a copy of it.
#
# The copies are the game's own "visual only" straws: no collision, no physics
# body, drawn by the same multimesh as the real ones. They cannot be picked up
# or swept, so nobody can turn one straw into two loads of hay. Straws that
# have come to rest stop costing anything, since their pose never changes
# again, and nothing is sent about straws too far from anyone else to see.

const SCAN_TICK := 0.2
const MOVE_TICK := 0.15
const CENSUS_TICK := 5.0
const RANGE := 26.0        # what a remote player could see, Cfg.STRAND_DESPAWN_DIST
const MOVE_EPS := 0.004
const ADD_BUDGET := 80
const MOVE_BUDGET := 120
const MINE_CAP := 400      # never track more of our own than this
const MAX_RAW := 4 << 20

var mp: Node
var world: Node
var live: Node

var _mine := {}      # sid -> body we own
var _ghost := {}     # sid -> our copy of somebody else's straw
var _sent := {}      # sid -> last transform broadcast
var _owner := {}     # sid -> peer, for ghosts
var _next := 0
var _scan_t := 0.0
var _move_t := 0.0
var _census_t := 0.0


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	live = world.get("live")


func shutdown() -> void:
	for sid in _ghost:
		var b: Variant = _ghost[sid]
		if b != null and is_instance_valid(b) and live != null:
			_revive(b)
			live.consume(b)
	_ghost.clear()
	for pid in _hands:
		for b in _hands[pid]:
			if b != null and is_instance_valid(b) and live != null:
				_revive(b)
				live.consume(b)
	_hands.clear()
	_mine.clear()
	_sent.clear()
	_owner.clear()


func _me() -> int:
	return multiplayer.get_unique_id()


func _new_sid() -> int:
	_next += 1
	return _me() * 1000000 + _next


# ------------------------------------------------------------------ ticks

func _process(delta: float) -> void:
	if live == null or not is_instance_valid(live):
		return
	# keeps following the fist even if the link hiccups
	_park_hands()
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_scan_t += delta
	if _scan_t >= SCAN_TICK:
		_scan_t = 0.0
		_scan()
	_move_t += delta
	if _move_t >= MOVE_TICK:
		_move_t = 0.0
		_send_moves()
	_census_t += delta
	if _census_t >= CENSUS_TICK:
		_census_t = 0.0
		_census()


func _watchers() -> Array:
	var out: Array = []
	var ws: Node = mp.world_sync
	if ws == null or not is_instance_valid(ws):
		return out
	for id in ws.avatars:
		var a: Variant = ws.avatars[id]
		if a != null and is_instance_valid(a):
			out.append((a as Node3D).global_position)
	return out


func _near(at: Vector3, watchers: Array) -> bool:
	for w in watchers:
		if at.distance_squared_to(w) < RANGE * RANGE:
			return true
	return false


# Pick up straws that are ours and close enough to somebody else to matter,
# and let go of the ones that are gone or out of everyone's sight.
func _scan() -> void:
	var watchers := _watchers()
	var active: Variant = live.get("_active")
	if not (active is Array):
		return
	var adds: Array = []
	var seen := {}
	if not watchers.is_empty():
		for b in active:
			if _mine.size() + adds.size() >= MINE_CAP:
				break
			if b == null or not is_instance_valid(b):
				continue
			if b.has_meta("mp_ghost") or b.has_meta("needle_index"):
				continue
			# straw in a hand, a bucket or on a tool travels with whatever
			# holds it, so it is not ours to scatter on the floor
			if bool(b.get_meta("protected", false)):
				continue
			var body := b as Node3D
			if not _near(body.global_position, watchers):
				continue
			var sid := int(b.get_meta("mp_sid", 0))
			if sid != 0 and _mine.get(sid) == b:
				seen[sid] = true
				continue
			sid = _new_sid()
			b.set_meta("mp_sid", sid)
			_mine[sid] = b
			seen[sid] = true
			_sent[sid] = body.global_transform
			adds.append([sid, body.global_transform,
				b.get_meta("tint", Color(1, 1, 1))])
			if adds.size() >= ADD_BUDGET:
				break
	var drop := PackedInt64Array()
	for sid in _mine.keys():
		if seen.has(sid):
			continue
		var b: Variant = _mine[sid]
		_mine.erase(sid)
		_sent.erase(sid)
		if b != null and is_instance_valid(b):
			b.remove_meta("mp_sid")
		drop.append(sid)
	if not adds.is_empty():
		mp._rx_straw_add.rpc(adds)
	if drop.size() > 0:
		mp._rx_straw_del.rpc(drop)


func _send_moves() -> void:
	if _mine.is_empty():
		return
	var ids := PackedInt64Array()
	var rows := PackedFloat32Array()
	for sid in _mine:
		var b: Variant = _mine[sid]
		if b == null or not is_instance_valid(b):
			continue
		var xf: Transform3D = (b as Node3D).global_transform
		var was: Variant = _sent.get(sid)
		if was != null and (was as Transform3D).origin.distance_squared_to(xf.origin) < MOVE_EPS * MOVE_EPS:
			continue
		_sent[sid] = xf
		ids.append(sid)
		var q := xf.basis.get_rotation_quaternion()
		rows.append_array(PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z,
			q.x, q.y, q.z, q.w]))
		if ids.size() >= MOVE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_straw_move.rpc(ids, rows)


func _census() -> void:
	var ids := PackedInt64Array()
	for sid in _mine:
		if is_instance_valid(_mine[sid]):
			ids.append(sid)
	mp._rx_straw_census.rpc(ids)


# ------------------------------------------------------------------ from the net

func on_add(sender: int, adds: Array) -> void:
	if live == null or not is_instance_valid(live):
		return
	for row in adds:
		if not (row is Array) or (row as Array).size() < 3:
			continue
		var sid: int = row[0]
		if _ghost.has(sid) or _mine.has(sid):
			continue
		var xf: Transform3D = row[1]
		var b: Variant = live.spawn(xf.origin, xf.basis, Vector3.ZERO, row[2], true)
		if b == null:
			continue
		b.set_meta("mp_ghost", true)
		(b as Node3D).global_transform = xf
		_ghost[sid] = b
		_owner[sid] = sender


func on_move(ids: PackedInt64Array, rows: PackedFloat32Array) -> void:
	for i in ids.size():
		var b: Variant = _ghost.get(ids[i])
		if b == null or not is_instance_valid(b):
			continue
		var k := i * 7
		if k + 6 >= rows.size():
			return
		(b as Node3D).global_transform = Transform3D(
			Basis(Quaternion(rows[k + 3], rows[k + 4], rows[k + 5], rows[k + 6])),
			Vector3(rows[k], rows[k + 1], rows[k + 2]))


func on_del(ids: PackedInt64Array) -> void:
	for sid in ids:
		_drop_ghost(sid)


func on_census(sender: int, ids: PackedInt64Array) -> void:
	var theirs := {}
	for sid in ids:
		theirs[sid] = true
	var gone: Array = []
	for sid in _ghost:
		if int(_owner.get(sid, 0)) == sender and not theirs.has(sid):
			gone.append(sid)
	for sid in gone:
		_drop_ghost(sid)


func _drop_ghost(sid: int) -> void:
	var b: Variant = _ghost.get(sid)
	_ghost.erase(sid)
	_owner.erase(sid)
	if b != null and is_instance_valid(b) and live != null:
		_revive(b)
		live.consume(b)


# A "visual only" straw is taken out of the physics world entirely. These
# bodies come from a pool the game reuses for real straws, so put it back
# before handing it over or the next straw drawn from the pool falls through
# the floor. Same steps the robotic arm uses for its sample bodies.
func _revive(b: Node) -> void:
	var body := b as Node3D
	if body == null or not body.is_inside_tree():
		return
	var space: RID = body.get_world_3d().space
	PhysicsServer3D.body_set_space(b.get_rid(), space)
	PhysicsServer3D.body_set_state(b.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)
	body.force_update_transform()


func peer_gone(pid: int) -> void:
	var gone: Array = []
	for sid in _owner:
		if int(_owner[sid]) == pid:
			gone.append(sid)
	for sid in gone:
		_drop_ghost(sid)


# ------------------------------------------------------------------ in the hand

# Straw a remote player is holding. Their own game parks the real bodies in
# front of their camera; here we put copies in their farmer's hand so the
# others can see them carry it.

const HAND_FAN := 0.05
# the hand node hangs down the arm: a short step along -Z is the fist itself
const HAND_REACH := 0.13
const HAND_DROP := -0.03

var _hands := {}     # peer -> Array of straw bodies we keep for them


func set_hand(pid: int, count: int) -> void:
	if live == null or not is_instance_valid(live):
		return
	var held: Array = _hands.get(pid, [])
	count = clampi(count, 0, 12)
	while held.size() > count:
		var b: Variant = held.pop_back()
		if b != null and is_instance_valid(b):
			_revive(b)
			live.consume(b)
	while held.size() < count:
		var b: Variant = live.spawn(Vector3.ZERO, Basis(), Vector3.ZERO,
			Color(0.86, 0.74, 0.4), true)
		if b == null:
			break
		b.set_meta("mp_ghost", true)
		held.append(b)
	if held.is_empty():
		_hands.erase(pid)
	else:
		_hands[pid] = held


# fanned out in front of the fist, the way the game holds them
func _park_hands() -> void:
	if _hands.is_empty():
		return
	var ws: Node = mp.world_sync
	if ws == null or not is_instance_valid(ws):
		return
	for pid in _hands.keys():
		var av: Variant = ws.avatars.get(pid)
		if av == null or not is_instance_valid(av) or not av.has_method("hand_xform"):
			set_hand(int(pid), 0)
			continue
		var base: Transform3D = av.hand_xform()
		var held: Array = _hands[pid]
		for i in held.size():
			var b: Variant = held[i]
			if b == null or not is_instance_valid(b):
				continue
			var side := (float(i) - float(held.size() - 1) * 0.5) * HAND_FAN
			var xf := base * Transform3D(Basis(Vector3.UP, side * 1.6),
				Vector3(side, HAND_DROP, -HAND_REACH))
			(b as Node3D).global_transform = xf


func drop_hand(pid: int) -> void:
	set_hand(pid, 0)
