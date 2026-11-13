extends Node
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

# Belt contents.
#
# The host decides what is riding on the belts. A few times a second it sends
# the whole ride list, compressed; clients drop what they have and board the
# list they were given. Their own belts keep turning in between, so the items
# move smoothly and the snapshot only corrects the small drift.
#
# Machines that eat from a belt are switched off on clients, or both sides
# would turn the same hay into two bales.

const TICK := 0.25
const FULL_TICK := 2.0  # the list goes out at least this often, changed or not
const MAX_RAW := 8 << 20
const Snapshot = preload("res://mods/multiplayer/mp_belt_snapshot.gd")
const Routes = preload("res://mods/multiplayer/mp_belt_routes.gd")
const LiftCargo = preload("res://mods/multiplayer/mp_lift_cargo.gd")
const FrameSlots = preload("res://mods/multiplayer/mp_frame_slots.gd")
# A guest runs its belts itself between two lists from the host. A belt whose
# riders are where the host's list says they are by now (moved on by the time
# the list took to arrive) is left alone; resetting it made everything on it
# jump back a little four times a second and cost a full rebuild each time.
const LEAD_MAX := 0.3
# The most a list may be moved on for its whole age (taken, sent, applied).
const AGE_MAX := 1.5
# How far a rider may sit from the host's (moved-on) spot before the belt is
# reset. 0.25 m reset 91% of a big yard's belts on every update, and each
# reset woke the game's belt simulation, which then cost a guest more than
# anything else. A different rider, kind or count is still reset at once.
const MATCH_TOL := 1.0
# A rider in the middle of passing from one belt to the next (a corner, a
# junction) is on the next belt on one side and still on the last one on the
# other. Within this far of a belt's ends that alone does not reset the belt;
# the guest's own belts hand it over. Should it last, the belt is reset.
const EDGE := 0.7
const EDGE_PATIENCE_MS := 1000
# A guest runs only the belts near it. The game moves every belt in the yard
# on every machine, and a guest did all of that again on top of what the host
# sends, so its cost grew with the whole yard. Belts farther than this from
# the guest stand still and take the host's state from its lists (every 2 s
# out there; the host sends nearer belts four times a second).
const LOD_RANGE := 40.0
const LOD_TICK := 0.5
var _lod_t := 0.0
var _lod_disabled := false
var _lod_bounds := {}  # path instance id -> AABB of its line
var _lod_off := {}     # path instance id -> weakref, belts we stopped
var _lod_census_at := 0
var _muted := {}       # path instance id -> weakref, belts whose fall-offs we ignore

var mp: Node
var world: Node
var _clock: Node
var _clock_script: Script
var _t := 0.0
var _since := 0.0
var _last_hash := 0
var _carry: Node
var _carry_script: Script
var _pick_pending := false
var _pick_stack := false
var _cleanup_scripts := {}
var _mirror_holds := {}
var _pending_snapshot: Variant = null
var _stopped := false
var _retry_at := 0
var _send_slot := FrameSlots.new()
var _flush_slot := FrameSlots.new()
var _staged := {}
var _host_sequences := {}
var _received_sequences := {}
var _sent_paths := {}
var _lift_cargo := LiftCargo.new()
var switches := preload("res://mods/multiplayer/mp_belt_switches.gd").new()
var _route_index := preload("res://mods/multiplayer/mp_belt_route_index.gd").new()
var _edge_since := {}   # path instance id -> msec a hand-over difference was first let pass


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	world.builds.changed.connect(_invalidate_routes)
	get_tree().node_added.connect(_protect_belt_cleanup)
	for path in BeltPath._live:
		_protect_belt_cleanup(path)
	var player: Variant = world.get("player")
	if is_instance_valid(player):
		_carry = player.get("carry")
	if is_instance_valid(_carry):
		_carry_script = _carry.get_script()
		_replace_carry_script(load(mp.base_dir + "/mp_carry.gd"))
		_carry.set("mp_belts", self)
	switches.start(mp.world_sync)
	_clock = world.get_node_or_null("FactoryClock")
	if is_instance_valid(_clock) and _clock.get_script().resource_path == "res://scripts/build/factory_clock.gd":
		_clock_script = _clock.get_script()
		_replace_belt_script(_clock, load(mp.base_dir + "/mp_factory_clock.gd"))
		_clock.mp_watch_start(world.props)
		_clock.set("mp_guest", not mp.is_host)


# Hand the belt ends back, in case the world outlives the session.
func shutdown() -> void:
	_lod_release()
	_unmute_fall_offs()
	if is_instance_valid(_clock) and _clock_script != null:
		_clock.mp_watch_stop()
		_replace_belt_script(_clock, _clock_script)
	_clock = null
	_clock_script = null
	if is_instance_valid(world) and is_instance_valid(world.builds) and world.builds.changed.is_connected(_invalidate_routes):
		world.builds.changed.disconnect(_invalidate_routes)
	switches.clear()
	_route_index.clear()
	if is_inside_tree() and get_tree().node_added.is_connected(_protect_belt_cleanup):
		get_tree().node_added.disconnect(_protect_belt_cleanup)
	for path in BeltPath._live:
		if not is_instance_valid(path):
			continue
		for original in _cleanup_scripts:
			if path.get_script() == _cleanup_scripts[original]:
				_replace_belt_script(path, original)
				break
	_cleanup_scripts.clear()
	if is_instance_valid(_carry) and _carry_script != null:
		_replace_carry_script(_carry_script)
	_release_mirror_holds()
	_lift_cargo.clear()
	_pending_snapshot = null
	_host_sequences.clear()
	_received_sequences.clear()
	_sent_paths.clear()
	_staged = {}
	_stopped = true
	set_process(false)


func _mp_timed_process(delta: float) -> void:
	switches.step()
	while not _delayed.is_empty() and Time.get_ticks_msec() >= int(_delayed[0][0]):
		var d: Array = _delayed.pop_front()
		_take_belts(d[1], d[2])
	_flush_pending_belts()
	_lift_cargo.step(delta)
	if mp != null and mp.active() and not mp.is_host and not _drain.is_empty():
		_drain_step()
	if mp != null and mp.active() and not mp.is_host:
		_lod_t += delta
		if _lod_t >= LOD_TICK:
			_lod_t = 0.0
			_mute_fall_offs()
			if not _lod_disabled:
				_lod_step()
	if mp == null or not mp.is_host or not mp.active():
		return
	if multiplayer.multiplayer_peer == null:
		return
	if mp.players.size() < 2:
		_staged = {}
		return
	_t += delta
	_since += delta
	if not _staged.is_empty():
		if _send_slot.take():
			_advance_staged()
		return
	if _t < TICK:
		return
	if not _send_slot.take():
		return
	_t = 0.0
	_staged = _capture(0)


# Everyone, or one guest that just came in. Unchanged lists are skipped: an
# idle yard used to send the whole ride list four times a second.
func send_all(pid: int = 0) -> void:
	var snapshot := _capture(pid)
	_select(snapshot)
	_transmit(snapshot)


func _advance_staged() -> void:
	var snapshot := _staged
	_staged = {}
	_select(snapshot)
	_transmit(snapshot)


func _capture(pid: int) -> Dictionary:
	var paths: Array = []
	var live_paths := {}
	var index: Dictionary = _route_index.get_index(mp.world_sync, BeltPath._live)
	var full_snapshot := pid > 0 or _since >= FULL_TICK
	var watchers: Array = mp.world_sync.network_watchers() if not full_snapshot else []
	for path in BeltPath._live:
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		var path_id: int = path.get_instance_id()
		live_paths[path_id] = true
		if path.run.count() == 0:
			if full_snapshot or not _path_near(path, watchers):
				continue
		elif not full_snapshot and not _path_near(path, watchers):
			continue
		var ends: PackedVector3Array = path.save_ends()
		if ends.size() < 2:
			continue
		var rows: Array = []
		for i in range(path.run.first(), path.run.first() + path.run.count()):
			var row: Dictionary = path.run.record(i)
			row["gap"] = path.run.gap_of(i)
			var state: Dictionary = row.get("state") if row.get("state") is Dictionary else {}
			row["state"] = state
			rows.append(row)
		paths.append([path_id, {"a": ends[0], "b": ends[1], "line": path._line, "owner": index.owners.get(path_id, ""), "records": rows}])
	return {"pid": pid, "full": full_snapshot, "paths": paths, "live": live_paths, "lifts": LiftCargo.capture(mp.world_sync), "at": Time.get_ticks_usec()}


func _select(snapshot: Dictionary) -> void:
	var pid: int = snapshot.pid
	var full_snapshot: bool = snapshot.full
	var entries: Array = []
	for item in snapshot.paths:
		var path_id: int = item[0]
		var entry: Dictionary = item[1]
		if pid == 0:
			var encoded := var_to_bytes(entry)
			var unchanged: bool = _sent_paths.get(path_id) == encoded
			_sent_paths[path_id] = encoded
			if not full_snapshot and unchanged:
				continue
		entries.append(entry)
	if pid == 0 and full_snapshot:
		for path_id in _sent_paths.keys():
			if not snapshot.live.has(path_id):
				_sent_paths.erase(path_id)
	snapshot.erase("paths")
	snapshot["entries"] = entries


func _transmit(snapshot: Dictionary) -> void:
	var pid: int = snapshot.pid
	var full_snapshot: bool = snapshot.full
	var body := {"paths": snapshot.entries, "lifts": snapshot.lifts, "full": full_snapshot}
	var raw := var_to_bytes(body)
	if pid == 0:
		var h := hash(raw)
		if h == _last_hash and _since < FULL_TICK:
			return
		_last_hash = h
		if full_snapshot:
			_since = 0.0
	# how long the list waited here since it was taken (spread over frames), so
	# a guest knows how far the host's riders have moved on since
	body["held"] = float(Time.get_ticks_usec() - int(snapshot.get("at", Time.get_ticks_usec()))) / 1000000.0
	raw = var_to_bytes(body)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if pid > 0:
		mp._rx_belts.rpc_id(pid, packed, raw.size(), mp._outgoing_world_seed())
	else:
		mp._rx_belts.rpc(packed, raw.size(), mp._outgoing_world_seed())


func _path_near(path: Node, watchers: Array) -> bool:
	if watchers.is_empty() or path._line.size() < 2:
		return true
	var bounds := AABB(path._line[0], Vector3.ZERO)
	for point in path._line:
		bounds = bounds.expand(point)
	var expanded := bounds.grow(40.0)
	for watcher in watchers:
		if watcher is Vector3 and expanded.has_point(watcher):
			return true
	return false


# dev (MP_TEST_BELT_DELAY_MS): the lists arrive this much later, as over a
# slow line; the lead counts it as the ping would
var _test_delay_ms := int(OS.get_environment("MP_TEST_BELT_DELAY_MS")) if OS.get_environment("MP_TEST_BELT_DELAY_MS").is_valid_int() else 0
var _delayed: Array = []

func _mp_timed_on_belts(packed: PackedByteArray, raw_size: int) -> void:
	if _test_delay_ms > 0:
		_delayed.append([Time.get_ticks_msec() + _test_delay_ms, packed, raw_size])
		return
	_take_belts(packed, raw_size)


func _take_belts(packed: PackedByteArray, raw_size: int) -> void:
	if _stopped or not is_instance_valid(mp) or not mp.active() or mp.is_host:
		return
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return
	var payload: Variant = bytes_to_var(raw)
	var entries: Variant = payload.get("paths") if payload is Dictionary else payload
	var lifts: Variant = payload.get("lifts", []) if payload is Dictionary else []
	var full_snapshot := bool(payload.get("full", true)) if payload is Dictionary else true
	if not (entries is Array) or not Snapshot.valid(entries) or not LiftCargo.valid(lifts):
		return
	_retry_at = 0
	# when (on our clock) the host took this list: what it waited there, plus
	# the way over. Applying it can wait a few frames more here; the riders
	# are moved on by the whole age, not just the way over.
	var held := clampf(float(payload.get("held", 0.0)) if payload is Dictionary and (payload.get("held") is float) else 0.0, 0.0, 2.0)
	var born := Time.get_ticks_usec() - int((held + clampf(float(mp.one_way_s) + _test_delay_ms / 1000.0, 0.0, LEAD_MAX)) * 1000000.0)
	for entry in entries:
		entry["born"] = born
	_queue_belts(entries, lifts, full_snapshot)


func _queue_belts(entries: Array, lifts: Array, full_snapshot: bool) -> void:
	if _pending_snapshot != null and not full_snapshot:
		var combined := {}
		for entry in _pending_snapshot.paths + entries:
			combined[[entry.owner, entry.line]] = entry
		entries = combined.values()
		full_snapshot = bool(_pending_snapshot.full)
	_pending_snapshot = {"paths": entries, "lifts": lifts, "full": full_snapshot}


func _invalidate_routes() -> void:
	_route_index.clear()
	_sent_paths.clear()
	_staged = {}


func invalidate_builds() -> void:
	_lod_bounds.clear()
	_route_index.clear()
	_staged = {}
	_pending_snapshot = null
	_host_sequences.clear()
	_received_sequences.clear()
	_sent_paths.clear()
	_edge_since.clear()
	_alias.clear()
	_alias_of_host.clear()
	_linger.clear()
	_drain.clear()


func _flush_pending_belts() -> void:
	if _pending_snapshot == null or _stopped:
		return
	if not is_instance_valid(mp) or not mp.active() or mp.is_host:
		_pending_snapshot = null
		return
	var sync: Node = mp.world_sync
	if not is_instance_valid(sync) or sync.world != world:
		_pending_snapshot = null
		return
	if mp.phase != mp.Phase.IN_WORLD or sync._frozen or sync._applying_builds or sync._builds_dirty:
		return
	if Time.get_ticks_msec() < _retry_at:
		return
	if not _flush_slot.take():
		return
	var payload: Dictionary = _pending_snapshot
	var carriers_ready: bool = _lift_cargo.ready(sync, payload.lifts)
	if not carriers_ready and is_instance_valid(sync.diagnostics):
		sync.diagnostics.observe("belts", true, payload.lifts.size(), 1)
	if not carriers_ready or not _apply_belts(payload.paths, bool(payload.get("full", true))):
		_retry_at = Time.get_ticks_msec() + 250
		return
	_pending_snapshot = null
	_lift_cargo.apply(sync, payload.lifts)


func _mp_timed_apply_belts(entries: Array, full_snapshot: bool = true) -> bool:
	# dev-only switch for measuring what applying belt lists costs a guest
	if OS.get_environment("MP_TEST_NO_BELTS") != "" or __MPCost.is_off("belts"):
		return true
	var resolved: Dictionary = Routes.resolve(mp.world_sync, entries, BeltPath._live, _route_index.get_index(mp.world_sync, BeltPath._live))
	if not resolved.ready:
		if is_instance_valid(mp.world_sync.diagnostics):
			mp.world_sync.diagnostics.observe("belts", true, entries.size(), 1)
		return false
	mp.trace.note("belts begin: %d paths" % entries.size())
	for id in _mirror_holds.keys():
		if not is_instance_valid(_mirror_holds[id]["path"].get_ref()):
			_mirror_holds.erase(id)
	var lead: float = clampf(float(mp.one_way_s), 0.0, LEAD_MAX)
	var kept := {}
	var patient := {}  # kept while a rider passes a seam: differs from the host for a moment, on purpose
	var leads := {}
	for assignment in resolved.assignments:
		var path: Node = assignment[0]
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		var age := lead
		if assignment.size() > 2 and int(assignment[2]) > 0:
			age = clampf(float(Time.get_ticks_usec() - int(assignment[2])) / 1000000.0, 0.0, AGE_MAX)
		if OS.get_environment("MP_TEST_JUMPS") != "":
			_jumps["age_sum"] = float(_jumps.get("age_sum", 0.0)) + age
			_jumps["age_n"] = int(_jumps.get("age_n", 0)) + 1
		var shifts := _lead_shifts(assignment[1], age, float(path.run.length()))
		leads[path] = shifts
		_mark_drain(path, assignment[1])
		if OS.get_environment("MP_TEST_JUMPS") != "":
			_probe_motion(path, assignment[1], shifts)
		var verdict := _compare(path, assignment[1], shifts)
		var path_id: int = path.get_instance_id()
		if verdict == MATCH:
			kept[path] = true
			_edge_since.erase(path_id)
		elif verdict == HANDING_OVER and _plain_seams(path):
			# A rider passing from one conveyor to the next is on the next one
			# here and still on the last one at the host, or the other way
			# round; both belts were reset for it, and everything on them
			# jumped: some 100 riders a second vanished on one belt and came
			# back on the next around a walking guest, most of the stutter
			# seen in corners. Between two plain conveyors the guest's own
			# belts hand it over within a moment; should it last, the belt is
			# reset after all. Where a machine sits at the seam this does not
			# apply (a frozen wrapper there let bales through unwrapped, .82).
			var since: int = int(_edge_since.get(path_id, 0))
			if since == 0:
				_edge_since[path_id] = Time.get_ticks_msec()
				kept[path] = true
				patient[path] = true
			elif Time.get_ticks_msec() - since < EDGE_PATIENCE_MS:
				kept[path] = true
				patient[path] = true
			else:
				_edge_since.erase(path_id)
		else:
			_edge_since.erase(path_id)
		if not kept.has(path) and not _lod_off.has(path_id) and not _hard_resets:
			var soft := _soft_fix(path, assignment[1], shifts)
			var fixed := soft != SOFT_FAIL
			if fixed:
				_jumps["_last_soft"] = path_id
			if soft == SOFT_WAITING:
				patient[path] = true
			if fixed:
				kept[path] = true
			if OS.get_environment("MP_TEST_JUMPS") != "":
				_jumps["soft" if fixed else "hard"] = int(_jumps.get("soft" if fixed else "hard", 0)) + 1
		if not kept.has(path) and OS.get_environment("MP_TEST_JUMPS") != "":
			_note_jump(path, assignment[1], shifts)
		if OS.get_environment("MP_TEST_JUMPS") != "":
			var how := "keep"
			if not kept.has(path):
				how = "off" if _lod_off.has(path_id) else "hard"
			elif path in patient:
				how = "wait"
			elif _jumps.get("_last_soft") == path_id:
				how = "soft"
			_outcome[path_id] = how + "_" + (_probe_class(path) if not _lod_off.has(path_id) else "")
	var checked_paths: Array = BeltPath._live if full_snapshot else resolved.assignments.map(func(row: Array): return row[0])
	for item in checked_paths:
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		if kept.has(item):
			_hold_mirrored_path(item)
			continue
		item.run.clear()
		_hold_mirrored_path(item)
	if full_snapshot:
		_host_sequences.clear()
		_received_sequences.clear()
	else:
		for assignment in resolved.assignments:
			for seq in _received_sequences.get(assignment[0].get_instance_id(), []):
				_host_sequences.erase(seq)
	var restored := 0
	for assignment in resolved.assignments:
		if not kept.has(assignment[0]):
			Routes.restore(assignment[0], _shifted(assignment[1], leads.get(assignment[0], PackedFloat32Array())))
		var sequences := []
		for row in assignment[1]:
			_host_sequences[row.seq] = true
			sequences.append(row.seq)
		_received_sequences[assignment[0].get_instance_id()] = sequences
		restored += assignment[1].size()
		if OS.get_environment("MP_TEST_JUMPS") != "":
			_probe_mark(assignment[0])
	var got := {"boarded": restored, "lost": 0}
	mp.trace.note("belts end: %d restored, %d unmatched, %d of %d paths kept, %d handing over" % [int(got.get("boarded", 0)), int(got.get("lost", 0)), kept.size(), resolved.assignments.size(), _edge_since.size()])
	if is_instance_valid(mp.world_sync) and is_instance_valid(mp.world_sync.diagnostics):
		mp.world_sync.diagnostics.observe("belts", false, 0, 1)
		var compared_entries: Array = entries
		var compared_paths: Array = checked_paths
		if not patient.is_empty():
			# A belt waiting for a rider to pass its seam is not a sync
			# problem; counting it made the warning come up every few minutes.
			var skipped := {}
			for assignment in resolved.assignments:
				if patient.has(assignment[0]):
					for row in assignment[1]:
						skipped[int(row.seq)] = true
			var records: Array = []
			for entry in entries:
				for row in entry.get("records", []):
					if not skipped.has(int(row.seq)):
						records.append(row)
			compared_entries = [{"records": records}]
			compared_paths = checked_paths.filter(func(p): return not patient.has(p))
		mp.world_sync.diagnostics.check_belts(compared_entries, compared_paths)
	if OS.get_environment("MP_DEBUG_PROPS") != "":
		var rows := 0
		for entry in entries:
			rows += entry["records"].size()
		print("[MPBELTS] %d paths, %d rows -> %s" % [entries.size(), rows, got])
	return true


# A belt whose ends meet only other belts: not part of a machine that is frozen
# here, not feeding one (a mouth that eats from it) and not handing on to one.
static func _plain_seams(path: Node) -> bool:
	var parent: Node = path.get_parent()
	if parent == null or parent.has_meta("mp_stopped"):
		return false
	var eats: Variant = path.get("_eats")
	if eats is Callable and (eats as Callable).is_valid():
		return false
	var down: Variant = path.get("downstream")
	if down != null and is_instance_valid(down):
		var down_parent: Node = (down as Node).get_parent()
		if down_parent == null or down_parent.has_meta("mp_stopped"):
			return false
	return true


# How far each of the host's riders has moved on by the time the list is
# applied. A rider never gains on the one in front of it, so a queue behind a
# stopped front stays where it is.
static func _lead_shifts(rows: Array, lead: float, length: float) -> PackedFloat32Array:
	var shifts := PackedFloat32Array()
	shifts.resize(rows.size())
	var limit := INF
	for i in rows.size():
		var row: Dictionary = rows[i]
		var shift := maxf(0.0, float(row.speed)) * lead
		if i == 0:
			shift = minf(shift, maxf(0.0, length - float(row.s)))
		shift = minf(shift, limit)
		shifts[i] = shift
		limit = shift
	return shifts


# Dev measurement (MP_TEST_JUMPS): how far riders a player could see jump
# when a belt is reset, written to the trace every 10 s
var _jumps := {"resets": 0, "seen": 0, "moved": 0, "sum": 0.0, "max": 0.0, "gone": 0, "new": 0}
var _jumps_at := 0

func _note_jump(path: Node, rows: Array, shifts: PackedFloat32Array) -> void:
	var eye: Variant = _lod_eye()
	if not (eye is Vector3):
		return
	var line: PackedVector3Array = path._line
	if line.is_empty() or (line[0] as Vector3).distance_to(eye) > 25.0 and (line[line.size() - 1] as Vector3).distance_to(eye) > 25.0:
		return
	_jumps.resets += 1
	var run = path.run
	var local := {}
	for at in range(run.first(), run.first() + run.count()):
		local[run.seq_of(at)] = float(run.s_of(at))
	var host := {}
	for i in rows.size():
		host[int(rows[i].seq)] = true
		var seq := int(rows[i].seq)
		if not local.has(seq):
			_jumps.new += 1
			continue
		var signed_d: float = local[seq] - (float(rows[i].s) + (shifts[i] if i < shifts.size() else 0.0))
		var d := absf(signed_d)
		_jumps["ahead_sum"] = float(_jumps.get("ahead_sum", 0.0)) + signed_d
		if float(rows[i].speed) <= 0.01:
			_jumps["host_still"] = int(_jumps.get("host_still", 0)) + 1
		_jumps.seen += 1
		if d > 0.1:
			_jumps.moved += 1
			_jumps.sum += d
			_jumps.max = maxf(_jumps.max, d)
	var gone_s: Array = []
	for seq in local:
		if not host.has(seq):
			_jumps.gone += 1
			gone_s.append(local[seq])
	# dev: a rider only the host has, sitting where one only we have sits: the
	# same rider under another number
	for i in rows.size():
		if local.has(int(rows[i].seq)):
			continue
		var hs := float(rows[i].s) + (shifts[i] if i < shifts.size() else 0.0)
		for k in gone_s.size():
			if absf(float(gone_s[k]) - hs) < 0.5:
				_jumps["renamed"] = int(_jumps.get("renamed", 0)) + 1
				gone_s.remove_at(k)
				break
	if _compare_unnumbered(path, rows, shifts):
		_jumps["same_but_numbers"] = int(_jumps.get("same_but_numbers", 0)) + 1
	if Time.get_ticks_msec() - _jumps_at > 10000:
		_jumps_at = Time.get_ticks_msec()
		mp.trace.note("belt jumps near player (10 s): %s" % str(_jumps))
		_jumps = {"resets": 0, "seen": 0, "moved": 0, "sum": 0.0, "max": 0.0, "gone": 0, "new": 0}


enum { DIFFERENT, MATCH, HANDING_OVER }

static func _compare(path: Node, rows: Array, shifts: PackedFloat32Array) -> int:
	var run = path.run
	var first: int = run.first()
	var length := float(run.length())
	var local_seqs := {}
	for at in range(first, first + run.count()):
		local_seqs[run.seq_of(at)] = at
	var host_seqs := {}
	for row in rows:
		host_seqs[int(row.seq)] = true
	var edge := false
	# riders only the host has: fine at either end, they are on their way
	var host_rows: Array = []
	for i in rows.size():
		var row: Dictionary = rows[i]
		var s := float(row.s) + shifts[i]
		if not local_seqs.has(int(row.seq)):
			if s < EDGE or s > length - EDGE:
				edge = true
				continue
			return DIFFERENT
		host_rows.append([row, s])
	# riders only we have: the same
	var local_rows: Array = []
	for at in range(first, first + run.count()):
		if not host_seqs.has(run.seq_of(at)):
			var s := float(run.s_of(at))
			if s < EDGE or s > length - EDGE:
				edge = true
				continue
			return DIFFERENT
		local_rows.append(at)
	if host_rows.size() != local_rows.size():
		return DIFFERENT
	for i in host_rows.size():
		var row: Dictionary = host_rows[i][0]
		var at: int = local_rows[i]
		if run.seq_of(at) != int(row.seq) or run.kind_of(at) != int(row.kind) 				or run.strands_of(at) != int(row.strands) or run.needle_of(at) != int(row.needle):
			return DIFFERENT
		if absf(float(run.s_of(at)) - float(host_rows[i][1])) > MATCH_TOL:
			return DIFFERENT
	return HANDING_OVER if edge else MATCH


# dev: would the belt match if the riders' numbers were ignored (same count,
# order, kinds, and spots within MATCH_TOL)?
static func _compare_unnumbered(path: Node, rows: Array, shifts: PackedFloat32Array) -> bool:
	var run = path.run
	if run.count() != rows.size():
		return false
	var first: int = run.first()
	var order: Array = []
	for i in rows.size():
		order.append(i)
	order.sort_custom(func(a, b): return float(rows[a].s) + shifts[a] > float(rows[b].s) + shifts[b])
	var local: Array = []
	for at in range(first, first + run.count()):
		local.append(at)
	local.sort_custom(func(a, b): return float(run.s_of(a)) > float(run.s_of(b)))
	for k in order.size():
		var row: Dictionary = rows[order[k]]
		var at: int = local[k]
		if run.kind_of(at) != int(row.kind) or run.strands_of(at) != int(row.strands):
			return false
		if absf(float(run.s_of(at)) - float(row.s) - shifts[order[k]]) > MATCH_TOL:
			return false
	return true


static func _shifted(rows: Array, shifts: PackedFloat32Array) -> Array:
	if shifts.size() != rows.size():
		return rows
	var out: Array = []
	for i in rows.size():
		var row: Dictionary = rows[i]
		if shifts[i] > 0.0:
			row = row.duplicate()
			row["s"] = float(row.s) + shifts[i]
		out.append(row)
	return out


func _lod_eye() -> Variant:
	var sync: Variant = mp.world_sync if is_instance_valid(mp) else null
	var player: Variant = sync.get("player") if is_instance_valid(sync) else null
	if is_instance_valid(player) and player is Node3D:
		return (player as Node3D).global_position
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam != null else null


func _lod_step() -> void:
	var eye: Variant = _lod_eye()
	if not (eye is Vector3):
		return
	var live := {}
	for path in BeltPath._live:
		if not is_instance_valid(path) or not path.is_inside_tree() or not path.has_method("set_ticking"):
			continue
		var id: int = path.get_instance_id()
		live[id] = true
		var box: Variant = _lod_bounds.get(id)
		if box == null:
			var line: PackedVector3Array = path._line
			if line.size() < 2:
				continue
			var b := AABB(line[0], Vector3.ZERO)
			for point in line:
				b = b.expand(point)
			box = b.grow(LOD_RANGE)
			_lod_bounds[id] = box
		# A belt inside a machine the host runs (a wrapper's, a press's)
		# never runs here: the machine is frozen on a guest, so its belt
		# carried bales straight through unwrapped until the host's list put
		# them right. It shows the host's state instead.
		var parent := path.get_parent()
		var in_frozen: bool = parent != null and parent.has_meta("mp_stopped") 			and not (parent is HayLift or parent is HayStairs) and _stops_belts(parent)
		var near: bool = not in_frozen and (box as AABB).has_point(eye)
		if near and _lod_off.has(id):
			_lod_off.erase(id)
			path.set_ticking(true)
			path.wake()
		elif not near and not _lod_off.has(id):
			_lod_off[id] = weakref(path)
			path.set_ticking(false)
	if OS.get_environment("MP_TEST_JUMPS") != "" and Time.get_ticks_msec() - _lod_census_at > 10000:
		_lod_census_at = Time.get_ticks_msec()
		var census := {}
		for oid in _lod_off:
			var p: Variant = _lod_off[oid].get_ref()
			if not is_instance_valid(p) or not _lod_bounds.has(oid) or not (_lod_bounds[oid] as AABB).has_point(eye):
				continue
			var par: Node = (p as Node).get_parent()
			var key: String = par.get_script().resource_path.get_file() if par != null and par.get_script() != null else "-"
			census[key] = int(census.get(key, 0)) + 1
		mp.trace.note("stopped belts near player by parent: %s" % str(census))
	for id in _lod_bounds.keys():
		if not live.has(id):
			_lod_bounds.erase(id)
			_lod_off.erase(id)


# Guest: what falls off the end of a belt is the host's to make. Our copy of a
# belt runs up to a machine that is frozen here and takes nothing, so its load
# fell off and the game made real straw of it, some 20 straws a second at the
# scanners of a big yard. Nothing ever ate them; they piled up awake in front
# of the machines, the physics worked them every tick and a guest lost a few
# frames a second for as long as the session ran. The host's straw from a real
# fall-off reaches us as its copy like any other.
func _mute_fall_offs() -> void:
	for path in BeltPath._live:
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		var id: int = path.get_instance_id()
		if _muted.has(id):
			continue
		var run: Variant = path.get("run")
		if run == null or not (run is Object) or not (run as Object).has_signal("fell_off"):
			continue
		var handler := Callable(path, "_on_run_fell_off")
		if (run as Object).is_connected("fell_off", handler):
			(run as Object).disconnect("fell_off", handler)
			_muted[id] = weakref(path)
	if _muted.size() > 4 * BeltPath._live.size() + 64:
		for id in _muted.keys():
			if not is_instance_valid(_muted[id].get_ref()):
				_muted.erase(id)


func _unmute_fall_offs() -> void:
	for id in _muted:
		var path: Variant = _muted[id].get_ref()
		if not is_instance_valid(path):
			continue
		var run: Variant = path.get("run")
		var handler := Callable(path, "_on_run_fell_off")
		if run is Object and (run as Object).has_signal("fell_off") and not (run as Object).is_connected("fell_off", handler):
			(run as Object).connect("fell_off", handler)
	_muted.clear()


func _lod_release() -> void:
	for id in _lod_off:
		var path: Variant = _lod_off[id].get_ref()
		if is_instance_valid(path):
			path.set_ticking(true)
			path.wake()
	_lod_off.clear()
	_lod_bounds.clear()


func _hold_mirrored_path(item: Node) -> void:
	if item._records_held:
		return
	var saved := {"path": weakref(item), "eats": item._eats, "hold_for": item.run.hold_for}
	item.hold_records(Callable())
	saved["applied_hold"] = item.run.hold_for
	_mirror_holds[item.get_instance_id()] = saved


func _release_mirror_holds() -> void:
	for saved in _mirror_holds.values():
		var item: Variant = saved["path"].get_ref()
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		if not item._records_held or item._eats.is_valid() or item.run.hold_for != saved["applied_hold"]:
			continue
		item._records_held = false
		item._eats = saved["eats"]
		item.run.hold_for = saved["hold_for"]
		item._sync_run_links()
	_mirror_holds.clear()


func _replace_carry_script(script: Script) -> void:
	var values := {}
	for property in _carry.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			values[property.name] = _carry.get(property.name)
	_carry.set_script(script)
	for key in values:
		if key in _carry:
			_carry.set(key, values[key])


func request_pick(record: Dictionary, onto_stack: bool) -> bool:
	if _pick_pending:
		return true
	var seq := int(record.get("seq", -1))
	seq = int(_alias.get(seq, seq))
	if not _host_sequences.has(seq):
		return false
	_pick_pending = true
	_pick_stack = onto_stack
	mp._rx_belt_pick.rpc_id(1, seq, mp._outgoing_world_seed())
	return true


func on_pick(sender: int, seq: int) -> void:
	for path in BeltPath._live.duplicate():
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		for i in range(path.run.first(), path.run.first() + path.run.count()):
			if path.run.seq_of(i) != seq:
				continue
			var item: Variant = path.materialize_record(i)
			if not is_instance_valid(item):
				mp._rx_belt_pick_result.rpc_id(sender, sender, 0, mp._outgoing_world_seed())
				return
			var id := int(item.get_meta("mp_id", 0))
			if id == 0:
				mp._rx_belt_pick_result.rpc_id(sender, sender, 0, mp._outgoing_world_seed())
				return
			mp.world_sync.props_sync._assign_owner(id, sender, true)
			mp._rx_belt_pick_result.rpc(sender, id, mp._outgoing_world_seed())
			send_all()
			return
	mp._rx_belt_pick_result.rpc_id(sender, sender, 0, mp._outgoing_world_seed())


func on_pick_result(owner: int, id: int) -> void:
	var sync: Node = mp.world_sync.props_sync
	if owner != multiplayer.get_unique_id():
		return
	_pick_pending = false
	var item: Variant = sync._by_id.get(id)
	if not is_instance_valid(item) or not is_instance_valid(_carry):
		return
	if _pick_stack and _carry.can_stack(item):
		_carry.stack_on(item)
	elif not _carry.is_carrying():
		_carry.take(item)


func _protect_belt_cleanup(node: Node) -> void:
	if not (node is BeltPath):
		return
	# A wrapper's own belts keep the game's script. Swapped for even an empty
	# copy of it, the wrapper let about one bale in five through unwrapped, as
	# host and in single player alike (721 wrapped and 1 not in four minutes
	# of a big yard without the mod, 661 and 156 with it). Nothing in the
	# patch is needed there: on a guest the wrapper is frozen and its belts do
	# not run, on the host they ran the game's code anyway.
	if node.get_parent() is HayWrapper:
		return
	var original: Script = node.get_script()
	if original == null or not original.resource_path.begins_with("res://scripts/"):
		return
	if not _cleanup_scripts.has(original):
		var patch := GDScript.new()
		patch.source_code = "extends %s\nvar _mp_native_end_hold := Callable()\nfunc _sync_run_links() -> void:\n\tsuper._sync_run_links()\n\t_mp_native_end_hold = run.end_held_for\n\tvar processor = get_parent()\n\tif is_instance_valid(processor) and processor.has_method(\"_mp_holds_output_kind\"):\n\t\trun.end_held_for = _mp_end_held\nfunc _mp_end_held(kind: int) -> bool:\n\tvar processor = get_parent()\n\treturn (is_instance_valid(processor) and processor.has_method(\"_mp_holds_output_kind\") and processor._mp_holds_output_kind(kind)) or (_mp_native_end_hold.is_valid() and bool(_mp_native_end_hold.call(kind)))\nfunc _shed_over_cap() -> void:\n\tvar session = get_node_or_null(\"/root/MPMod\")\n\tif is_instance_valid(session) and session.active():\n\t\tif not session.is_host or not Cfg.auto_clean:\n\t\t\treturn\n\tsuper._shed_over_cap()\nfunc _spill_records() -> void:\n\tvar session = get_node_or_null(\"/root/MPMod\")\n\tif is_instance_valid(session) and session.active() and not session.is_host:\n\t\trun.clear()\n\t\treturn\n\tsuper._spill_records()\nfunc _materialize_head() -> void:\n\tvar session = get_node_or_null(\"/root/MPMod\")\n\tif is_instance_valid(session) and session.active() and not session.is_host:\n\t\treturn\n\tsuper._materialize_head()\nfunc _keeps_at_seam(r: Rider) -> bool:\n\tvar session = get_node_or_null(\"/root/MPMod\")\n\tif is_instance_valid(session) and session.active() and is_instance_valid(downstream) and downstream.is_inside_tree() and not downstream.is_queued_for_deletion():\n\t\tvar body = r.body\n\t\tif is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion() and is_same(body.get_meta(LiveStrandManager.META_RIDER, null), self):\n\t\t\treturn true\n\treturn super._keeps_at_seam(r)\nfunc materialize_record(i: int) -> Carryable:\n\treturn preload(\"res://mods/multiplayer/mp_belt_items.gd\").materialize(self, i)\nfunc pass_record_to(seq: int, other: BeltPath) -> bool:\n\treturn preload(\"res://mods/multiplayer/mp_belt_items.gd\").transfer(self, seq, other)\n" % JSON.stringify(original.resource_path)
		patch.source_code += "\nfunc _follow_tech() -> void:\n\tsuper._follow_tech()\n\tpreload(\"res://mods/multiplayer/mp_distributor_drive.gd\").apply(self)\n"
		patch.source_code += preload("res://mods/multiplayer/mp_belt_switches.gd").PATCH
		if patch.reload() != OK:
			return
		_cleanup_scripts[original] = patch
	_replace_belt_script(node, _cleanup_scripts[original])
	if node.is_node_ready():
		node._follow_tech()


func _replace_belt_script(node: Node, script: Script) -> void:
	var values := {}
	for property in node.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			values[property.name] = node.get(property.name)
	node.set_script(script)
	for key in values:
		node.set(key, values[key])


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_process(delta)
	__MPCost.add("belts", Time.get_ticks_usec() - __t)


func on_belts(packed: PackedByteArray, raw_size: int) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_on_belts(packed, raw_size)
	__MPCost.add("belts.on_belts", Time.get_ticks_usec() - __t)


func _apply_belts(entries: Array, full_snapshot: bool = true) -> bool:
	var __t := Time.get_ticks_usec()
	var __r = _mp_timed_apply_belts(entries, full_snapshot)
	__MPCost.add("belts._apply_belts", Time.get_ticks_usec() - __t)
	return __r


# dev (MP_TEST_JUMPS): how far each rider moved here since the last list, and
# how far the host says it moved in the same time
var _probe_ref := {}   # seq -> [s after the last apply, usec]
var _probe := {"n": 0, "local": 0.0, "host": 0.0, "dt": 0.0, "stuck": 0, "lod_off": 0, "asleep": 0}
var _probe_at := 0

func _probe_motion(path: Node, rows: Array, shifts: PackedFloat32Array) -> void:
	var eye: Variant = _lod_eye()
	if not (eye is Vector3):
		return
	var line: PackedVector3Array = path._line
	if line.is_empty() or (line[0] as Vector3).distance_to(eye) > 25.0 and (line[line.size() - 1] as Vector3).distance_to(eye) > 25.0:
		return
	var run = path.run
	var now := Time.get_ticks_usec()
	var local := {}
	for at in range(run.first(), run.first() + run.count()):
		local[run.seq_of(at)] = float(run.s_of(at))
	_vis_pre[path.get_instance_id()] = local.duplicate()
	for i in rows.size():
		var seq := int(rows[i].seq)
		if not local.has(seq) or not _probe_ref.has(seq):
			continue
		var ref: Array = _probe_ref[seq]
		var dt := float(now - int(ref[1])) / 1000000.0
		if dt <= 0.0 or dt > 1.0:
			continue
		var lm: float = local[seq] - float(ref[0])
		var hm: float = float(rows[i].s) + shifts[i] - float(ref[0])
		var tag := "off_" if _lod_off.has(path.get_instance_id()) else _probe_class(path)
		_probe[tag + "n"] = int(_probe.get(tag + "n", 0)) + 1
		_probe[tag + "local"] = float(_probe.get(tag + "local", 0.0)) + lm
		_probe[tag + "host"] = float(_probe.get(tag + "host", 0.0)) + hm
		if absf(lm) < 0.01 and hm > 0.1:
			_probe[tag + "stuck"] = int(_probe.get(tag + "stuck", 0)) + 1
			if tag == "plain_" and _probe_samples < 40:
				_probe_samples += 1
				_probe_sample(path, seq, rows[i])
		if hm < -0.05:
			_probe[tag + "host_back"] = int(_probe.get(tag + "host_back", 0)) + 1
		if lm > hm + 0.3:
			_probe[tag + "local_ahead"] = int(_probe.get(tag + "local_ahead", 0)) + 1
		_probe.dt += dt
		if absf(lm) < 0.01 and hm > 0.1:
			_probe.stuck += 1
	if _lod_off.has(path.get_instance_id()):
		_probe.lod_off += 1
	if run.has_method("is_flowing") and not run.is_flowing():
		_probe.asleep += 1
	if Time.get_ticks_msec() - _probe_at > 10000:
		_probe_at = Time.get_ticks_msec()
		mp.trace.note("belt motion near player (10 s): %s" % str(_probe))
		_probe = {"n": 0, "local": 0.0, "host": 0.0, "dt": 0.0, "stuck": 0, "lod_off": 0, "asleep": 0}


func _probe_mark(path: Node) -> void:
	_vis_post(path)
	var run = path.run
	var now := Time.get_ticks_usec()
	for at in range(run.first(), run.first() + run.count()):
		_probe_ref[run.seq_of(at)] = [float(run.s_of(at)), now]
	if _probe_ref.size() > 20000:
		_probe_ref.clear()


func _probe_class(path: Node) -> String:
	var eats: Variant = path.get("_eats")
	if eats is Callable and (eats as Callable).is_valid():
		return "eats_"
	var down: Variant = path.get("downstream")
	if down == null or not is_instance_valid(down):
		return "end_"
	if _lod_off.has((down as Node).get_instance_id()):
		return "intooff_"
	var dp: Node = (down as Node).get_parent()
	if dp != null and dp.has_meta("mp_stopped"):
		return "intofrozen_"
	return "plain_"


var _probe_samples := 0

func _probe_sample(path: Node, seq: int, row: Dictionary) -> void:
	var run = path.run
	var at := -1
	for k in range(run.first(), run.first() + run.count()):
		if run.seq_of(k) == seq:
			at = k
	var down: Node = path.get("downstream")
	var dp: Node = down.get_parent() if down != null else null
	var ds := "-"
	if down != null:
		ds = "%s cnt=%d len=%.1f off=%s flowing=%s first_s=%s" % [down.name, down.run.count(), float(down.run.length()), _lod_off.has(down.get_instance_id()), down.run.is_flowing() if down.run.has_method("is_flowing") else "?", str(snappedf(float(down.run.s_of(down.run.first())), 0.01)) if down.run.count() > 0 else "-"]
	mp.trace.note("stuck rider: path=%s parent=%s(%s) cnt=%d len=%.1f idx=%d s=%.2f group=%s speed=%.2f host_s=%.2f host_speed=%.2f gap=%.2f | down=%s parent=%s(%s) stopped=%s" % [
		path.name, dp_name(path.get_parent()), path.get_parent().get_class() if path.get_parent() else "-", run.count(), float(run.length()), at - run.first(),
		float(run.s_of(at)) if at >= 0 else -1.0, str(run.row_group(at)) if at >= 0 and run.has_method("row_group") else "?",
		float(run.speed_of(at)) if at >= 0 else -1.0, float(row.s), float(row.speed), float(row.gap),
		ds, dp_name(dp), dp.get_script().resource_path.get_file() if dp != null and dp.get_script() != null else "-", dp.has_meta("mp_stopped") if dp != null else false])


static func dp_name(n: Node) -> String:
	if n == null:
		return "-"
	var s: Script = n.get_script()
	return "%s[%s]" % [n.name, s.resource_path.get_file() if s != null else "-"]


# A belt that differs from the host's list is put right rider by rider instead
# of being emptied and filled again. Measured with a guest walking a big yard:
# about 900 belts a 10 s were reset that way and 80% of the riders on them
# jumped, 0.8 m on average and up to 10 m. Nearly all of it came from two
# things a reset cannot help:
# - A queue in front of a machine. The machine is frozen here and eats
#   nothing, so the queue stood still while the host's crept on. Each list
#   moved every rider of it forward at once. Now the riders the host's
#   machine took leave the front here as well, and our own belt moves the
#   rest up the way it does at the host.
# - A rider passing a seam gets a new number on each side. It was taken for a
#   different rider and the belt was reset for it; now a rider of the same
#   kind at the same spot counts as the same one (and a pick of it asks the
#   host for it under the host's number).
# Anything this cannot place (a rider in the wrong order, too far off, a new
# one in the middle of a queue) still resets the belt.
const RENAME_TOL := 0.5
# how far apart a rider may run here before it is put back: this long at its
# speed, but at least MATCH_TOL and at most SOFT_TOL_MAX
const SOFT_LAG_S := 0.4
const SOFT_TOL_MAX := 2.5
var _force_middle := OS.get_environment("MP_NO_FORCE_MIDDLE") == ""
var _hard_resets := OS.get_environment("MP_BELT_HARD") != ""
var _alias := {}          # our rider number -> the host's
var _alias_of_host := {}  # the host's rider number -> ours
var _linger := {}         # "L<seq>"/"H<seq>" -> msec a rider at a seam was first let wait

enum { SOFT_FAIL, SOFT_DONE, SOFT_WAITING }

func _soft_fix(path: Node, rows: Array, shifts: PackedFloat32Array) -> int:
	var run = path.run
	var first: int = run.first()
	var n: int = run.count()
	var length := float(run.length())
	var local_by_seq := {}
	for at in range(first, first + n):
		local_by_seq[run.seq_of(at)] = at
	var pair := {}   # host row -> our row
	var used := {}   # our row -> true
	for i in rows.size():
		var seq := int(rows[i].seq)
		var at: int = int(local_by_seq.get(seq, -1))
		if at < 0 and _alias_of_host.has(seq):
			at = int(local_by_seq.get(_alias_of_host[seq], -1))
		if at >= 0 and not used.has(at):
			pair[i] = at
			used[at] = true
	var renamed := {}
	for i in rows.size():
		if pair.has(i):
			continue
		var hs := float(rows[i].s) + shifts[i]
		var best := -1
		var best_d := RENAME_TOL
		for at in range(first, first + n):
			if used.has(at) or run.kind_of(at) != int(rows[i].kind) or run.strands_of(at) != int(rows[i].strands) \
					or run.needle_of(at) != int(rows[i].needle):
				continue
			var d := absf(float(run.s_of(at)) - hs)
			if d < best_d:
				best_d = d
				best = at
		if best >= 0:
			pair[i] = best
			used[best] = true
			renamed[i] = best
	# The riders both have: same kind and in the same order. One that sits too
	# far from the host's spot is taken off and put back where the host has
	# it; a little apart is left to our belt (the host's belts and ours stop
	# and go at slightly different moments; at 5 m/s that is soon a metre).
	var far := {}
	for i in rows.size():
		if not pair.has(i):
			continue
		var at: int = pair[i]
		if run.kind_of(at) != int(rows[i].kind) or run.strands_of(at) != int(rows[i].strands) \
				or run.needle_of(at) != int(rows[i].needle):
			return _soft_fail("r2")
		var tol := clampf(absf(float(rows[i].speed)) * SOFT_LAG_S, MATCH_TOL, SOFT_TOL_MAX)
		if absf(float(run.s_of(at)) - float(rows[i].s) - shifts[i]) > tol:
			far[i] = true
	# Out of order (a merger here let them in the other way round): the
	# longest run of riders already in the host's order stays, the few others
	# are put back where the host has them.
	var order: Array = []
	for i in rows.size():
		if pair.has(i) and not far.has(i):
			order.append(i)
	var keep := _in_order(order, pair)
	if keep.size() < order.size():
		if order.size() - keep.size() > maxi(2, order.size() / 3):
			return _soft_fail("r1")
		for i in order:
			if not keep.has(i):
				far[i] = true
	for i in far:
		used.erase(pair[i])
		renamed.erase(i)
		pair.erase(i)
	var now := Time.get_ticks_msec()
	var plain := _plain_seams(path)
	var waiting := false
	# riders only we have: gone at the host (eaten, picked, passed on)
	var drop: Array = []
	for at in range(first, first + n):
		if used.has(at):
			continue
		var s := float(run.s_of(at))
		if plain and s > length - EDGE and _wait("L%d" % run.seq_of(at), now):
			waiting = true  # on its way to the next belt here too
			continue
		drop.append(at)
	# riders only the host has: new, moved, or about to be handed in here too
	var add: Array = []
	for i in rows.size():
		if pair.has(i):
			continue
		var hs := clampf(float(rows[i].s) + shifts[i], 0.0, length)
		if hs < EDGE and not far.has(i) and _wait("H%d" % int(rows[i].seq), now):
			waiting = true
			continue
		add.append(i)
	if drop.size() + add.size() > maxi(4, (n + rows.size()) / 2):
		return _soft_fail("r5")  # most of it differs: a reset is cheaper
	for i in renamed:
		var ours: int = run.seq_of(renamed[i])
		_alias[ours] = int(rows[i].seq)
		_alias_of_host[int(rows[i].seq)] = ours
	for k in range(drop.size() - 1, -1, -1):
		_linger.erase("L%d" % run.seq_of(drop[k]))
		run.remove_at(drop[k])
	for i in add:
		var row: Dictionary = rows[i]
		_linger.erase("H%d" % int(row.seq))
		var hs := clampf(float(row.s) + shifts[i], 0.0, length)
		var count: int = run.count()
		var tail := float(run.s_of(run.first() + count - 1)) if count > 0 else INF
		if hs < tail:
			var index: int = run.first() + count
			run._insert_row(index, hs, row.reach, row.gap, row.side, row.lift, row.speed, row.kind,
				row.strands, row.needle, row.seq, row.state)
			run._ev_board(index)
		elif not _board_between(run, row, hs):
			# no room at the host's spot here: the belt is put right whole after all
			if OS.get_environment("MP_TEST_JUMPS") != "":
				_jumps["board_failed"] = int(_jumps.get("board_failed", 0)) + 1
			run.clear()
			Routes.restore(path, _shifted(rows, shifts))
			return SOFT_DONE
	if not drop.is_empty() or not add.is_empty():
		run.wake()
	if _alias.size() > 20000:
		_alias.clear()
		_alias_of_host.clear()
	if _linger.size() > 5000:
		_linger.clear()
	return SOFT_WAITING if waiting else SOFT_DONE


# true while a rider at a seam may still wait for our belts to hand it over
func _wait(key: String, now: int) -> bool:
	var since: int = int(_linger.get(key, 0))
	if since == 0:
		_linger[key] = now
		return true
	return now - since < EDGE_PATIENCE_MS


func _soft_fail(why: String) -> int:
	if OS.get_environment("MP_TEST_JUMPS") != "":
		_jumps["fail_" + why] = int(_jumps.get("fail_" + why, 0)) + 1
	return SOFT_FAIL


# A rider the host has between two of ours: boarded the way the game puts one
# onto a belt mid-way (a hand-over by place), at the host's spot. The game may
# give it its own number; it then answers to the host's.
func _board_between(run: Object, row: Dictionary, s: float) -> bool:
	var rec := row.duplicate()
	rec["s"] = s
	var was: bool = run.catching
	run.catching = true
	var ok: bool = run.board_record(rec, s, float(row.speed), false)
	run.catching = was
	if not ok:
		if not _force_middle:
			return false
		# no room by the game's own spacing (ours sit a little apart from the
		# host's): put it in its place in the row as the lists do
		var index: int = run.first() + run.count()
		for at in range(run.first(), run.first() + run.count()):
			if float(run.s_of(at)) < s:
				index = at
				break
		run._insert_row(index, s, row.reach, row.gap, row.side, row.lift, row.speed, row.kind,
			row.strands, row.needle, row.seq, row.state)
		run._ev_board(index)
		if OS.get_environment("MP_TEST_JUMPS") != "":
			_jumps["forced"] = int(_jumps.get("forced", 0)) + 1
		return true
	var host_seq := int(row.seq)
	var best := -1
	var best_d := 0.05
	for at in range(run.first(), run.first() + run.count()):
		if run.kind_of(at) != int(row.kind):
			continue
		var d := absf(float(run.s_of(at)) - s)
		if d <= best_d:
			best_d = d
			best = at
	if best >= 0 and run.seq_of(best) != host_seq:
		_alias[run.seq_of(best)] = host_seq
		_alias_of_host[host_seq] = run.seq_of(best)
	return true


# dev (MP_TEST_JUMPS): what a player near the belt sees when a list is applied,
# however it was applied: riders that moved by more than a hand's width, and
# riders that vanished or popped up
var _vis_pre := {}
var _outcome := {}
var _vis := {"riders": 0, "jumped": 0, "sum": 0.0, "max": 0.0, "vanished": 0, "appeared": 0}
var _vis_at := 0

func _vis_post(path: Node) -> void:
	var pre: Variant = _vis_pre.get(path.get_instance_id())
	_vis_pre.erase(path.get_instance_id())
	if not (pre is Dictionary):
		return
	var how: String = str(_outcome.get(path.get_instance_id(), "?"))
	var run = path.run
	var post := {}
	var post_kind := {}
	for at in range(run.first(), run.first() + run.count()):
		post[run.seq_of(at)] = float(run.s_of(at))
		post_kind[run.seq_of(at)] = run.kind_of(at)
	var matched := {}
	for seq in pre:
		_vis.riders += 1
		_vis[how + "n"] = int(_vis.get(how + "n", 0)) + 1
		var to := -1
		if post.has(seq):
			to = seq
		elif post.has(int(_alias.get(seq, -1))):
			to = int(_alias[seq])
		if to < 0:
			# the same rider under the host's number: nearest one not yet taken
			var best := 0.6
			for k in post:
				if matched.has(k) or pre.has(k):
					continue
				var d := absf(float(post[k]) - float(pre[seq]))
				if d < best:
					best = d
					to = k
		if to < 0:
			_vis.vanished += 1
			_vis[how + "v"] = int(_vis.get(how + "v", 0)) + 1
			continue
		matched[to] = true
		var d := absf(float(post[to]) - float(pre[seq]))
		if d > 0.3:
			_vis.jumped += 1
			_vis[how + "j"] = int(_vis.get(how + "j", 0)) + 1
			_vis[how + "m"] = snappedf(float(_vis.get(how + "m", 0.0)) + d, 0.1)
			_vis.sum += d
			_vis.max = maxf(_vis.max, d)
	for k in post:
		if not matched.has(k) and not pre.has(k):
			_vis.appeared += 1
			_vis[how + "a"] = int(_vis.get(how + "a", 0)) + 1
	if Time.get_ticks_msec() - _vis_at > 10000:
		_vis_at = Time.get_ticks_msec()
		mp.trace.note("belt view near player (10 s): %s" % str(_vis))
		_vis = {"riders": 0, "jumped": 0, "sum": 0.0, "max": 0.0, "vanished": 0, "appeared": 0}


# The biggest set of host rows whose riders here are already in the same
# order (longest increasing run of our row numbers), as {host row: true}.
static func _in_order(order: Array, pair: Dictionary) -> Dictionary:
	var n := order.size()
	var best := PackedInt32Array()
	var prev := PackedInt32Array()
	best.resize(n)
	prev.resize(n)
	var top := -1
	for k in n:
		best[k] = 1
		prev[k] = -1
		for j in k:
			if int(pair[order[j]]) < int(pair[order[k]]) and best[j] + 1 > best[k]:
				best[k] = best[j] + 1
				prev[k] = j
		if top < 0 or best[k] > best[top]:
			top = k
	var out := {}
	while top >= 0:
		out[order[top]] = true
		top = prev[top]
	return out


# A guest's belt into a machine that stands still here (its own belt is the
# host's picture) stood in a queue: our machine eats nothing, so the queue
# moved up only when a list from the host took the front rider away, four
# times a second, in steps, while the host's crept on smoothly. While the
# host's front rider on such a belt is moving, ours leaves at the mouth as it
# arrives there, as if eaten; the next list puts back anything the host's
# machine had not taken after all.
const DRAIN_AT := 0.35
var _drain := {}  # path instance id -> weakref, belts whose front leaves at the mouth here
var _drain_samples := 0

func _mark_drain(path: Node, rows: Array) -> void:
	var id: int = path.get_instance_id()
	if _lod_off.has(id) or not _feeds_still_machine(path) or rows.is_empty() or float(rows[0].speed) <= 0.05:
		_drain.erase(id)
		return
	_drain[id] = weakref(path)


func _feeds_still_machine(path: Node) -> bool:
	var eats: Variant = path.get("_eats")
	if eats is Callable and (eats as Callable).is_valid():
		var owner: Variant = (eats as Callable).get_object()
		if owner is Node and (owner as Node).has_meta("mp_stopped"):
			return true
	var down: Variant = path.get("downstream")
	return down != null and is_instance_valid(down) and _lod_off.has((down as Node).get_instance_id())


func _drain_step() -> void:
	for id in _drain.keys():
		var path: Variant = _drain[id].get_ref()
		if not is_instance_valid(path) or not path.is_inside_tree():
			_drain.erase(id)
			continue
		var run = path.run
		if run.count() == 0:
			continue
		var head: int = run.first()
		if OS.get_environment("MP_TEST_JUMPS") != "" and _drain_samples < 30 and float(run.speed_of(head)) <= 0.05:
			_drain_samples += 1
			mp.trace.note("drain head: s=%.2f len=%.2f reach=%.2f count=%d" % [float(run.s_of(head)), float(run.length()), float(run.reach_of(head)), run.count()])
		if float(run.s_of(head)) < float(run.length()) - DRAIN_AT or float(run.speed_of(head)) > 0.05:
			continue
		if run.needle_of(head) >= 0:
			continue  # a needle is the host's to hand on
		run.remove_at(head)
		run.wake()
		if OS.get_environment("MP_TEST_JUMPS") != "":
			_jumps["drained"] = int(_jumps.get("drained", 0)) + 1


# Machines whose belts stand still on a guest (the host's picture is shown).
# Letting the belts of machines that only eat from their end run here helped
# in one yard and made another worse (riders seen jumping: 8.0% -> 6.9% in a
# big mid-game yard, 9.5-16.9% -> 16.3-19.2% in an endgame yard), so they
# stand still unless MP_RUN_MACHINE_BELTS is set. Wrappers, depots, scanners
# and cranes work on what rides through them and always stand still.
var _run_machine_belts := OS.get_environment("MP_RUN_MACHINE_BELTS") != ""

func _stops_belts(machine: Node) -> bool:
	return not _run_machine_belts or machine is HayWrapper or machine is HaystackScanner or machine is SkylineCrane
