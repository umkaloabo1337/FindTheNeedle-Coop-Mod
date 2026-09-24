# Per-world sync for the multiplayer mod. Created by MPMod once the yard is
# built, freed when the scene changes. All network traffic goes through MPMod's
# RPCs; this node only reads and applies game state.
extends Node

var mp: Node
var world: Node
var field: Node
var builds: Node
var player: Node

const POSE_HZ := 20.0
const HAY_TICK := 0.12
const HAY_FULL_SCAN := 3.0
const HAY_EPS := 0.002
const HAY_BATCH := 6000
const BUILD_TICK := 0.4
const STATE_TICK := 0.25

# Buildings that feed themselves from the pile or the world. On clients these
# stay frozen so nothing is dug, scanned or sold twice (the host runs them).
# Machines that take hay out of the pile or off a belt and turn it into
# something. They run on the host only: the belts and the items they make are
# sent out, so running them twice would just duplicate the work. Conveyors,
# lifts, generators and the rest of the yard keep running everywhere.
const CLIENT_FROZEN := ["piston_rakes", "robotic_arms", "hay_drones", "scanners",
	"compressors", "pulpers", "papers", "briquette_presses", "wrappers", "silos",
	"pelletizers", "tube_launchers", "dump_hatches", "needle_radars",
	"generators", "boreholes", "splitters", "joiners", "hay_lifts", "hay_stairs",
	"cabinets"]

const BUILD_ARRAYS := ["conveyors", "corners", "water_mains", "water_splitters",
	"robotic_arms", "platforms", "stairs", "railings", "walls", "roofs", "scanners",
	"compressors", "pulpers", "papers", "briquette_presses", "wrappers", "silos",
	"pelletizers", "generators", "boreholes", "tube_launchers", "dump_hatches",
	"hay_stairs", "hay_lifts", "splitters", "joiners", "cabinets", "needle_radars",
	"paint_boards", "work_lamps", "hay_drones", "piston_rakes", "power_poles"]
const BUILD_SHAPE_KEYS := ["span", "rise", "kind", "sections", "rows", "side"]

const ADD_F := ["money", "debt", "hay_total", "hay_dug", "hay_returned", "hay_sold",
	"money_earned", "stacks_ordered", "needles_found", "pile_needles_found"]
const ADD_A := ["needles_by_type", "needle_stock"]
const OR_A := ["needle_taken", "discovered"]
const HOST_ABS := ["run_secs", "lot_tier", "hay_initial", "money_peak", "pile_cleared",
	"first_needle_secs", "first_clear_secs", "best_sale", "best_sale_strands"]
const HOST_MAX := ["mission_index", "contract_index"]

var avatars := {}
var _avatar_script: Script
var _me: Node  # our own body, seen when looking down
var props_sync: Node  # loose item replication
var belts_sync: Node  # what is riding on the belts
var machines_sync: Node  # how the machines move and what they are set to
var strands_sync: Node  # loose straw on the ground
var _pose_t := 0.0

var _hay_base := PackedFloat32Array()
var _hay_cand := {}
var _hay_t := 0.0
var _hay_scan_t := 0.0

var _bkeys := {}  # key -> building dict
var _builds_dirty := false
var _build_t := 0.0
var _applying_builds := false

var _st_base := {}
var _st_pending: Array = []  # [seq, delta]
var _seq := 0
var _peer_ack := {}
var _state_t := 0.0
var _tech_mute := false
var _needles := {}  # needle index -> "free" | "held" | "away"
var _needle_t := 0.0
var _frozen := false  # stop sending (pile swap in progress, waiting for a reload)
var _pile_seed := 0


func _ready() -> void:
	field = world.get("field")
	builds = world.get("builds")
	player = world.get("player")
	_avatar_script = load(mp.base_dir + "/mp_avatar.gd")
	_me = _avatar_script.new()
	_me.setup_local(player, mp)
	world.add_child(_me)
	props_sync = (load(mp.base_dir + "/mp_props.gd") as Script).new()
	props_sync.name = "MPProps"
	add_child(props_sync)
	props_sync.start(mp, world)
	belts_sync = (load(mp.base_dir + "/mp_belts.gd") as Script).new()
	belts_sync.name = "MPBelts"
	add_child(belts_sync)
	belts_sync.start(mp, world)
	machines_sync = (load(mp.base_dir + "/mp_machines.gd") as Script).new()
	machines_sync.name = "MPMachines"
	add_child(machines_sync)
	machines_sync.start(mp, world)
	strands_sync = (load(mp.base_dir + "/mp_strands.gd") as Script).new()
	strands_sync.name = "MPStrands"
	add_child(strands_sync)
	strands_sync.start(mp, world)
	if field != null:
		field.cells_redrawn.connect(_on_cells_redrawn)
	if builds != null:
		builds.changed.connect(_on_builds_changed)
	Tech.tech_changed.connect(_on_tech_changed)
	GameState.pile_replaced.connect(_on_pile_replaced)
	GameState.needle_found.connect(_on_needle_found)
	GameState.needle_discovered.connect(_on_needle_discovered)
	rebaseline()
	if mp.active():
		apply_session_rules()


func shutdown() -> void:
	if Tech.tech_changed.is_connected(_on_tech_changed):
		Tech.tech_changed.disconnect(_on_tech_changed)
	if GameState.pile_replaced.is_connected(_on_pile_replaced):
		GameState.pile_replaced.disconnect(_on_pile_replaced)
	if GameState.needle_found.is_connected(_on_needle_found):
		GameState.needle_found.disconnect(_on_needle_found)
	if GameState.needle_discovered.is_connected(_on_needle_discovered):
		GameState.needle_discovered.disconnect(_on_needle_discovered)
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.shutdown()
	if belts_sync != null and is_instance_valid(belts_sync):
		belts_sync.shutdown()
	if machines_sync != null and is_instance_valid(machines_sync):
		machines_sync.shutdown()
	if strands_sync != null and is_instance_valid(strands_sync):
		strands_sync.shutdown()
	clear_avatars()
	if is_instance_valid(_me):
		_me.queue_free()


# Take the current world as the agreed starting point (nothing to send yet).
func rebaseline() -> void:
	if field != null:
		_hay_base = field.heights.duplicate()
	_hay_cand.clear()
	_bkeys = _scan_builds()
	_builds_dirty = false
	_st_base = _capture_state()
	_st_pending.clear()
	_pile_seed = GameState.run_seed
	_needles.clear()
	for idx in _needle_bodies():
		_needles[idx] = "free"
	_frozen = false


# Put the local player where a new game starts (the save carries the host's
# spot). Each client gets a small sideways offset so nobody spawns inside
# someone else.
func place_at_spawn() -> void:
	if player == null or not is_instance_valid(player):
		return
	var consts: Dictionary = world.get_script().get_script_constant_map()
	var sp: Vector3 = consts.get("SPAWN_POS", Vector3(13.2, 0.4, 5.6))
	var slot: int = mp.players.keys().find(multiplayer.get_unique_id())
	sp += Vector3(0.0, 0.0, 0.9 * float(maxi(slot, 1)))
	var at: Vector3 = world._seat(sp) if world.has_method("_seat") else sp
	player.global_position = at
	player.look_at_from_position(at, Vector3(0, 3.0, 0), Vector3.UP)
	player.rotation = Vector3(0, player.rotation.y, 0)
	if player.has_method("set_look"):
		player.set_look(player.rotation.y, 0.0)
	player.velocity = Vector3.ZERO


func apply_session_rules() -> void:
	mp._mp_guard_online_services()
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.session_started()
	if not mp.is_host:
		SaveManager.block_save = true
		if "autosave_enabled" in world:
			world.autosave_enabled = false
		# needles that surface as the pile is dug are announced by the host;
		# letting both sides pop them out gives two bodies for one needle
		var live: Node = _live()
		if live != null and "expose_uncovered" in live:
			live.expose_uncovered = false
		_freeze_client_machines()


func _is_client() -> bool:
	return mp.active() and not mp.is_host


func _process(delta: float) -> void:
	if not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_pose_t += delta
	if _pose_t >= 1.0 / POSE_HZ:
		_pose_t = 0.0
		_send_pose()
	if _frozen:
		return
	_hay_t += delta
	_hay_scan_t += delta
	if _hay_t >= HAY_TICK:
		_hay_t = 0.0
		var full := _hay_scan_t >= HAY_FULL_SCAN
		if full:
			_hay_scan_t = 0.0
		_hay_tick(full)
	_build_t += delta
	if _build_t >= BUILD_TICK:
		_build_t = 0.0
		_build_tick()
	_needle_t += delta
	if _needle_t >= 0.2:
		_needle_t = 0.0
		_needle_tick()
	_state_t += delta
	if _state_t >= STATE_TICK:
		_state_t = 0.0
		_state_tick()


# ---------------------------------------------------------------- avatars

func _send_pose() -> void:
	if player == null or not is_instance_valid(player):
		return
	var pitch := 0.0
	var p: Variant = player.get("_pitch")
	if p != null:
		pitch = float(p)
	var crouch := 0.0
	if player.has_method("crouch_amount"):
		crouch = float(player.crouch_amount())
	var moving: float = (player.velocity * Vector3(1, 0, 1)).length() if "velocity" in player else 0.0
	mp._rx_pose.rpc(player.global_position, player.rotation.y, pitch,
		int(player.get("current_tool")), crouch, moving)


func on_pose(id: int, pos: Vector3, yaw: float, pitch: float, tool: int, crouch: float, moving: float) -> void:
	var a: Node = avatars.get(id)
	if a == null or not is_instance_valid(a):
		a = _avatar_script.new()
		a.setup(mp.player_name(id), mp.player_color(id))
		world.add_child(a)
		a.global_position = pos
		avatars[id] = a
	a.set_target(pos, yaw, pitch, tool, crouch, moving)


func remove_avatar(id: int) -> void:
	var a: Node = avatars.get(id)
	if a != null and is_instance_valid(a):
		a.queue_free()
	avatars.erase(id)


func clear_avatars() -> void:
	for id in avatars.keys():
		remove_avatar(id)


func forget_peer(id: int) -> void:
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.peer_gone(id)
	if strands_sync != null and is_instance_valid(strands_sync):
		strands_sync.peer_gone(id)
	_peer_ack.erase(id)


func avatar_positions() -> Dictionary:
	var out := {}
	for id in avatars:
		if is_instance_valid(avatars[id]):
			out[id] = avatars[id].global_position
	return out


# ---------------------------------------------------------------- hay

func _on_cells_redrawn(cells: PackedInt32Array) -> void:
	var nc: int = field.get("_nc")
	var nv: int = field.get("_nv")
	for gc in cells:
		var v := (gc / nc) * nv + (gc % nc)
		_hay_cand[v] = true
		_hay_cand[v + 1] = true
		_hay_cand[v + nv] = true
		_hay_cand[v + nv + 1] = true


func _hay_tick(full: bool) -> void:
	if field == null:
		return
	var h: PackedFloat32Array = field.heights
	if h.size() != _hay_base.size():
		_hay_base = h.duplicate()
		_hay_cand.clear()
		return
	var idx := PackedInt32Array()
	var vals := PackedFloat32Array()
	if full:
		for i in h.size():
			if absf(h[i] - _hay_base[i]) > HAY_EPS:
				idx.append(i)
				vals.append(h[i])
				_hay_base[i] = h[i]
	else:
		var n := h.size()
		for i in _hay_cand:
			if i < n and absf(h[i] - _hay_base[i]) > HAY_EPS:
				idx.append(i)
				vals.append(h[i])
				_hay_base[i] = h[i]
	_hay_cand.clear()
	var at := 0
	while at < idx.size():
		var end := mini(at + HAY_BATCH, idx.size())
		mp._rx_hay.rpc(idx.slice(at, end), vals.slice(at, end))
		at = end


func on_hay(idx: PackedInt32Array, vals: PackedFloat32Array) -> void:
	if field == null or _frozen:
		return
	field.settle_join()
	var h: PackedFloat32Array = field.heights
	var n := h.size()
	if _hay_base.size() != n:
		_hay_base = h.duplicate()
	var nv: int = field.get("_nv")
	var touched := PackedInt32Array()
	for k in idx.size():
		var i := idx[k]
		if i < 0 or i >= n:
			continue
		h[i] = vals[k]
		_hay_base[i] = vals[k]
		touched.append(i)
	field.heights = h
	for i in touched:
		field._dirty_vertex_cells(i % nv, i / nv)


# ---------------------------------------------------------------- buildings

func _on_builds_changed() -> void:
	if not _applying_builds:
		_builds_dirty = true


func _bkey(d: Dictionary) -> String:
	var parts := [str(d.get("type", ""))]
	for k in ["position", "a", "b"]:
		if d.has(k):
			parts.append(_qv(d[k]))
	if d.has("yaw"):
		parts.append(str(snappedf(float(d["yaw"]), 0.05)))
	for k in BUILD_SHAPE_KEYS:
		if d.has(k):
			parts.append("%s=%s" % [k, str(d[k])])
	return "|".join(parts)


func _qv(v: Variant) -> String:
	if v is Vector3:
		return "%.1f,%.1f,%.1f" % [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]
	return str(v)


func _scan_builds() -> Dictionary:
	var out := {}
	if builds == null:
		return out
	for d in builds.to_array():
		if d is Dictionary:
			out[_bkey(d)] = d
	return out


func _build_tick() -> void:
	if _applying_builds or not _builds_dirty:
		return
	_flush_builds()


func _flush_builds() -> void:
	_builds_dirty = false
	var cur := _scan_builds()
	var adds: Array = []
	var removes: Array = []
	for k in cur:
		if not _bkeys.has(k):
			adds.append(cur[k])
	for k in _bkeys:
		if not cur.has(k):
			removes.append(_bkeys[k])
	_bkeys = cur
	if not adds.is_empty() or not removes.is_empty():
		mp._rx_builds.rpc(adds, removes)
	if _is_client():
		_freeze_client_machines()


func on_builds(adds: Array, removes: Array) -> void:
	if builds == null or _frozen:
		return
	while _applying_builds:
		await get_tree().process_frame
	# anything we built locally goes out first so the rescan below can't swallow it
	if _builds_dirty:
		_flush_builds()
	_applying_builds = true
	for d in removes:
		if d is Dictionary:
			var n := _find_building(d)
			if n != null:
				_demolish(n)
	if not adds.is_empty():
		await _add_buildings(adds)
	_bkeys = _scan_builds()
	_builds_dirty = false
	_applying_builds = false
	if _is_client():
		_freeze_client_machines()


func _find_building(d: Dictionary) -> Node3D:
	var want := str(d.get("type", ""))
	var best: Node3D = null
	var best_err := 0.6
	for n in builds.every_placed():
		if not is_instance_valid(n) or n.is_queued_for_deletion() or not n.has_method("to_dict"):
			continue
		var nd: Dictionary = n.to_dict()
		if str(nd.get("type", "")) != want:
			continue
		var err := 0.0
		for k in ["position", "a", "b"]:
			if d.has(k) and nd.has(k) and d[k] is Vector3 and nd[k] is Vector3:
				err += (d[k] as Vector3).distance_to(nd[k])
		if err < best_err:
			best_err = err
			best = n
	return best


func _demolish(n: Node3D) -> void:
	if builds.has_method("demolish_blocked_reason") and str(builds.demolish_blocked_reason(n)) == "":
		builds.demolish(n)
	if is_instance_valid(n) and not n.is_queued_for_deletion():
		builds._demolish_one(n)


# Add buildings through the game's own loader without wiping the yard:
# from_array() starts with clear(), so the existing buildings are parked
# outside the manager's lists while it runs, then merged back.
func _add_buildings(dicts: Array) -> void:
	var parked := {}
	for a in BUILD_ARRAYS:
		var arr: Variant = builds.get(a)
		if arr is Array:
			parked[a] = arr.duplicate()
			arr.clear()
	var slice: int = builds.restore_slice_usec
	builds.restore_slice_usec = 0
	await builds.from_array(dicts)
	builds.restore_slice_usec = slice
	for a in parked:
		var arr: Array = builds.get(a)
		var fresh := arr.duplicate()
		arr.clear()
		arr.append_array(parked[a])
		arr.append_array(fresh)
	builds.rebuild_junctions()
	builds.rebuild_water_joints()
	builds.fit_posts_to_decks()
	builds.share_joints()
	builds.changed.emit()


# Stopping a machine takes more than process_mode: the factory runs its
# machines from one static list (FactoryClock._tick_machines) and skips only
# the ones whose physics processing is off, so a "disabled" machine kept
# eating hay and spawning items while standing perfectly still. Clear both
# flags and the machine is really out of the loop; the host sends us how it
# moves instead.
func _freeze_client_machines() -> void:
	if builds == null:
		return
	for a in CLIENT_FROZEN:
		var arr: Variant = builds.get(a)
		if not (arr is Array):
			continue
		for n in arr:
			if not is_instance_valid(n) or n.has_meta("mp_stopped"):
				continue
			n.set_meta("mp_stopped", true)
			n.set_process(false)
			n.set_physics_process(false)
			n.process_mode = Node.PROCESS_MODE_DISABLED
			_still_animations(n)


# Their clips would otherwise hold whatever frame they stopped on, or keep
# looping, and fight the poses coming from the host.
func _still_animations(n: Node) -> void:
	for child in n.get_children():
		if child is AnimationPlayer:
			(child as AnimationPlayer).pause()
			child.process_mode = Node.PROCESS_MODE_DISABLED
		_still_animations(child)


# ---------------------------------------------------------------- shared game state

func _capture_state() -> Dictionary:
	var s := {}
	for f in ADD_F:
		s[f] = GameState.get(f)
	for a in ADD_A + OR_A:
		var v: Variant = GameState.get(a)
		s[a] = v.duplicate() if v != null else null
	return s


func _state_tick() -> void:
	if mp.is_host:
		var snap := _capture_state()
		for f in HOST_ABS + HOST_MAX:
			snap[f] = GameState.get(f)
		for pid in mp.players.keys():
			if pid != 1 and str(mp.players[pid].get("state", "")) == "world":
				mp._rx_state_snap.rpc_id(pid, int(_peer_ack.get(pid, 0)), snap)
		return
	var cur := _capture_state()
	var delta := {}
	for f in ADD_F:
		var d: float = float(cur[f]) - float(_st_base[f])
		if absf(d) > 1e-6:
			delta[f] = d
	for a in ADD_A:
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != b.size():
			continue
		var diff := PackedInt32Array()
		diff.resize(c.size())
		var any := false
		for i in c.size():
			diff[i] = c[i] - b[i]
			any = any or diff[i] != 0
		if any:
			delta[a] = diff
	for a in OR_A:
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != b.size():
			continue
		var bits := PackedInt32Array()
		for i in c.size():
			if c[i] != 0 and b[i] == 0:
				bits.append(i)
		if not bits.is_empty():
			delta[a] = bits
	_st_base = cur
	if delta.is_empty():
		return
	_seq += 1
	_st_pending.append([_seq, delta])
	mp._rx_state_delta.rpc_id(1, _seq, delta)


func on_state_delta(pid: int, seq: int, delta: Dictionary) -> void:
	var before := _capture_state()
	for f in ADD_F:
		if delta.has(f):
			_set_typed(f, float(GameState.get(f)) + float(delta[f]))
	for a in ADD_A:
		if delta.has(a):
			var arr: Variant = GameState.get(a)
			var d: PackedInt32Array = delta[a]
			if arr != null and arr.size() == d.size():
				for i in d.size():
					arr[i] = maxi(0, arr[i] + d[i])
				GameState.set(a, arr)
	for a in OR_A:
		if delta.has(a):
			var arr: Variant = GameState.get(a)
			if arr != null:
				for i in delta[a]:
					if i >= 0 and i < arr.size():
						arr[i] = 1
				GameState.set(a, arr)
	_peer_ack[pid] = seq
	_emit_state_signals(before)


func on_state_snap(ack: int, snap: Dictionary) -> void:
	if mp.is_host:
		return
	while not _st_pending.is_empty() and int(_st_pending[0][0]) <= ack:
		_st_pending.pop_front()
	var pend := {}
	for entry in _st_pending:
		var d: Dictionary = entry[1]
		for f in d:
			if f in ADD_F:
				pend[f] = float(pend.get(f, 0.0)) + float(d[f])
			elif f in ADD_A:
				if not pend.has(f):
					pend[f] = d[f].duplicate()
				elif pend[f].size() == d[f].size():
					for i in d[f].size():
						pend[f][i] += d[f][i]
			elif f in OR_A:
				if not pend.has(f):
					pend[f] = PackedInt32Array()
				pend[f].append_array(d[f])
	var before := _capture_state()
	var cur := before
	for f in ADD_F:
		if not snap.has(f):
			continue
		var unsent: float = float(cur[f]) - float(_st_base[f])
		var nb: float = float(snap[f]) + float(pend.get(f, 0.0))
		_st_base[f] = nb
		_set_typed(f, nb + unsent)
	for a in ADD_A:
		if not snap.has(a) or snap[a] == null:
			continue
		var s: PackedInt32Array = snap[a]
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != s.size() or b.size() != s.size():
			GameState.set(a, s.duplicate())
			_st_base[a] = s.duplicate()
			continue
		var p: Variant = pend.get(a)
		var nb := s.duplicate()
		var nv := s.duplicate()
		for i in s.size():
			var pi: int = p[i] if p != null and p.size() == s.size() else 0
			nb[i] = s[i] + pi
			nv[i] = nb[i] + (c[i] - b[i])
		_st_base[a] = nb
		GameState.set(a, nv)
	for a in OR_A:
		if not snap.has(a) or snap[a] == null:
			continue
		var s: PackedByteArray = snap[a]
		var c: Variant = cur[a]
		if c == null or c.size() != s.size():
			GameState.set(a, s.duplicate())
			_st_base[a] = s.duplicate()
			continue
		var nb := s.duplicate()
		for i in pend.get(a, PackedInt32Array()):
			if i >= 0 and i < nb.size():
				nb[i] = 1
		var nv := nb.duplicate()
		for i in s.size():
			if c[i] != 0:
				nv[i] = 1
		_st_base[a] = nb
		GameState.set(a, nv)
	for f in HOST_ABS:
		if snap.has(f) and snap[f] != null:
			GameState.set(f, snap[f])
	for f in HOST_MAX:
		if snap.has(f):
			GameState.set(f, maxi(int(GameState.get(f)), int(snap[f])))
	_emit_state_signals(before)


func _set_typed(f: String, v: float) -> void:
	var cur: Variant = GameState.get(f)
	if typeof(cur) == TYPE_INT:
		GameState.set(f, int(round(v)))
	else:
		GameState.set(f, v)


func _emit_state_signals(before: Dictionary) -> void:
	if not is_equal_approx(float(before["money"]), float(GameState.money)):
		GameState.money_changed.emit(GameState.money)
	if not is_equal_approx(float(before["debt"]), float(GameState.debt)):
		GameState.debt_changed.emit(GameState.debt)
	if not is_equal_approx(float(before["hay_total"]), float(GameState.hay_total)) \
	or not is_equal_approx(float(before["hay_dug"]), float(GameState.hay_dug)):
		GameState.set("_hay_dirty", true)
		GameState.hay_changed.emit(GameState.hay_total, GameState.hay_dug)
	if not is_equal_approx(float(before["hay_sold"]), float(GameState.hay_sold)):
		GameState.hay_sold_changed.emit(GameState.hay_sold)
	var bs: Variant = before["needle_stock"]
	var ns: PackedInt32Array = GameState.needle_stock
	if bs != null and bs.size() == ns.size():
		for t in ns.size():
			if bs[t] != ns[t]:
				GameState.needle_stock_changed.emit(t, ns[t])
	var bd: Variant = before["discovered"]
	var nd: PackedByteArray = GameState.discovered
	if bd != null and bd.size() == nd.size():
		var at: Vector3 = player.global_position if player != null and is_instance_valid(player) else Vector3.ZERO
		for t in nd.size():
			if bd[t] == 0 and nd[t] != 0:
				GameState.needle_discovered.emit(t, at)


# ---------------------------------------------------------------- tech tree

func _on_tech_changed(id: String, rank: int) -> void:
	if _tech_mute or not mp.active() or _frozen:
		return
	mp._rx_tech.rpc(id, rank)


func on_tech(id: String, rank: int) -> void:
	_tech_mute = true
	if rank <= 0:
		Tech.ranks.erase(id)
	else:
		Tech.ranks[id] = rank
	Tech.tech_changed.emit(id, rank)
	_tech_mute = false


# ---------------------------------------------------------------- full sync / pile swaps

# The host's world in the same shape SaveManager writes to disk, so a client
# can drop it into a scratch slot and load it with the game's own loader.
func build_payload(_pid: int) -> Dictionary:
	var xf: Transform3D = player.global_transform
	xf.origin += xf.basis.x * 1.2 + Vector3.UP * 0.2
	var props_arr: Array = []
	var props: Variant = world.get("props")
	if props != null and props.has_method("to_array"):
		props_arr = props.to_array()
	var belts: Dictionary = {}
	if world.has_method("_belts_to_dict"):
		belts = world._belts_to_dict()
	return {
		"version": SaveManager.FORMAT_VERSION,
		"pile_shape_version": SaveManager.current_pile_shape_version,
		"state": GameState.to_dict(),
		"heights": field.heights,
		"player": xf,
		"buildings": builds.to_array(),
		"props": props_arr,
		"belts": belts,
		"tech": Tech.to_dict(),
		"cell": Cfg.CELL,
		"extent": Cfg.FIELD_EXTENT,
		"meta": {
			"name": "Multijugador",
			"locked": false,
			"map": SaveManager.current_map,
			"pile_size": SaveManager.current_pile_size,
			"saved_at": int(Time.get_unix_time_from_system()),
			"hay_dug": GameState.hay_dug,
			"hay_initial": GameState.hay_initial,
			"hay_total": GameState.hay_total,
			"needles_found": GameState.needles_found,
			"money": GameState.money,
			"money_earned": GameState.money_earned,
		},
	}


func send_full_sync(pid: int) -> void:
	# loose needles the late joiner missed: [index, position, held_by_someone]
	var needles: Array = []
	var bodies := _needle_bodies()
	for idx in bodies:
		needles.append([idx, bodies[idx].global_position, _needles.get(idx, "") == "held"])
	for idx in _needles:
		if _needles[idx] == "away" and not bodies.has(idx):
			needles.append([idx, Vector3.ZERO, true])
	mp._rx_full_sync.rpc_id(pid, field.heights, builds.to_array(), Tech.to_dict(), needles)
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.send_all(pid)
	if belts_sync != null and is_instance_valid(belts_sync):
		belts_sync.send_all(pid)
	if machines_sync != null and is_instance_valid(machines_sync):
		machines_sync.send_all(pid)


func on_full_sync(heights: PackedFloat32Array, host_builds: Array, tech: Dictionary, needles: Array = []) -> void:
	for n in needles:
		on_needle("claim" if bool(n[2]) else "spawn", int(n[0]), n[1])
	if field != null and heights.size() == field.heights.size():
		var idx := PackedInt32Array()
		var vals := PackedFloat32Array()
		var h: PackedFloat32Array = field.heights
		for i in heights.size():
			if absf(heights[i] - h[i]) > HAY_EPS:
				idx.append(i)
				vals.append(heights[i])
		if not idx.is_empty():
			on_hay(idx, vals)
		_hay_base = field.heights.duplicate()
	if builds != null:
		var want := {}
		for d in host_builds:
			if d is Dictionary:
				want[_bkey(d)] = d
		var have := _scan_builds()
		var adds: Array = []
		var removes: Array = []
		for k in want:
			if not have.has(k):
				adds.append(want[k])
		for k in have:
			if not want.has(k):
				removes.append(have[k])
		if not adds.is_empty() or not removes.is_empty():
			_builds_dirty = false
			await on_builds(adds, removes)
		_bkeys = _scan_builds()
	_tech_mute = true
	Tech.from_dict(tech)
	_tech_mute = false
	_st_base = _capture_state()


func _on_pile_replaced() -> void:
	if not mp.active():
		_pile_seed = GameState.run_seed
		return
	if mp.is_host:
		_frozen = true
		mp.ui.notify(mp.t("new_pile_host"))
		await get_tree().create_timer(1.5).timeout
		if not is_inside_tree():
			return
		rebaseline()
		mp.resync_all()
	else:
		# We just paid for the load. Get that out before freezing stops the
		# state tick, or the host undoes its own charge expecting ours and the
		# pile ends up free for everyone.
		_state_tick()
		_frozen = true
		# the host owns the pile; ask it to swap its pile, it will send us the result
		mp.ui.notify(mp.t("new_pile_client"))
		mp._rx_new_pile_request.rpc_id(1)


func host_new_pile_for_client(pid: int) -> void:
	# The client already paid on its side (that arrives as a state delta),
	# so undo the host-side charge of the delivery.
	var money: float = GameState.money
	var debt: float = GameState.debt
	var stacks: int = GameState.stacks_ordered
	var seed_before := GameState.run_seed
	if world.has_method("_deliver_new_pile"):
		world._deliver_new_pile(false)
	GameState.money = money
	GameState.debt = debt
	GameState.stacks_ordered = stacks
	GameState.money_changed.emit(money)
	GameState.debt_changed.emit(debt)
	if GameState.run_seed == seed_before:
		# the host could not take a new load right now: put the client back
		mp.send_world(pid)


# ---------------------------------------------------------------- loose needles
# Uncovered needles are physics bodies in LiveStrandManager.needles, tagged
# with meta "needle_index". Everyone sees a needle once someone uncovers it;
# picking it up claims it (it vanishes for the others) so it can only be
# handed in once. States per index: "free" (lying here), "held" (in our hand),
# "away" (someone else is holding it).

func _live() -> Node:
	return world.get("live")


func _needle_bodies() -> Dictionary:
	var out := {}
	var live := _live()
	if live == null:
		return out
	for b in live.get("needles"):
		if is_instance_valid(b) and not b.is_queued_for_deletion():
			var idx := int(b.get_meta("needle_index", -1))
			if idx >= 0:
				out[idx] = b
	return out


func _held_needle() -> int:
	var hand: Variant = player.get("hand") if player != null and is_instance_valid(player) else null
	if hand != null and is_instance_valid(hand) and hand.has_method("held_needle_index"):
		return int(hand.held_needle_index())
	return -1


func _needle_tick() -> void:
	var cur := _needle_bodies()
	var held := _held_needle()
	for idx in cur:
		var st: String = _needles.get(idx, "")
		if st == "away":
			continue
		if st == "":
			_needles[idx] = "free"
			mp._rx_needle.rpc("spawn", idx, cur[idx].global_position)
			st = "free"
		if idx == held and st != "held":
			_needles[idx] = "held"
			mp._rx_needle.rpc("claim", idx, Vector3.ZERO)
		elif idx != held and st == "held":
			_needles[idx] = "free"
			mp._rx_needle.rpc("spawn", idx, cur[idx].global_position)
	for idx in _needles.keys():
		if _needles[idx] != "away" and not cur.has(idx):
			_needles.erase(idx)
			mp._rx_needle.rpc("gone", idx, Vector3.ZERO)


func on_needle(kind: String, idx: int, pos: Vector3) -> void:
	var live := _live()
	if live == null or _frozen:
		return
	var body: RigidBody3D = _needle_bodies().get(idx)
	match kind:
		"spawn":
			if body != null:
				if idx != _held_needle():
					body.global_position = pos
					body.linear_velocity = Vector3.ZERO
			else:
				live.reveal_needle(idx, pos)
			_needles[idx] = "free"
		"claim":
			if body != null and idx == _held_needle():
				return  # we grabbed it at the same moment; keep ours
			if body != null:
				live.consume_needle(body)
			_needles[idx] = "away"
		"gone":
			if body != null and idx != _held_needle():
				live.consume_needle(body)
			_needles.erase(idx)


# ---------------------------------------------------------------- events / toasts

func _on_needle_found(_index: int, _pos: Vector3) -> void:
	if mp.active() and not _frozen:
		mp._rx_event.rpc("needle", {})


func _on_needle_discovered(type: int, _pos: Vector3) -> void:
	pass


func on_event(id: int, kind: String, _data: Dictionary) -> void:
	match kind:
		"needle":
			toast(mp.t("needle_found") % mp.player_name(id))


func toast(text: String, seconds: float = 3.5) -> void:
	var hud: Variant = world.get("hud")
	if hud != null and is_instance_valid(hud) and hud.has_method("show_toast"):
		hud.show_toast(text, seconds)
	else:
		mp.ui.notify(text)
