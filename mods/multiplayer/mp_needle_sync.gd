extends Node
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

var mp: Node
var world_sync: Node
var applying := false
var _pending := {}
var _taking := {}
var _cabinet_scripts := {}
var _hand_script: Script
var _timer := 0.0
var _catalog_size := -1

func start(session: Node, sync: Node) -> void:
	mp = session
	world_sync = sync
	sync.economy.completed.connect(_completed)
	var hand: Node = sync.player.hand
	_hand_script = hand.get_script()
	sync.economy._replace(hand, load(mp.base_dir + "/mp_hand.gd"))
	hand.set("mp_needles", self)
	_hook_cabinets()
	world_sync.builds.changed.connect(_hook_cabinets)
	if mp.is_host:
		normalize_scanners()

func shutdown() -> void:
	if is_instance_valid(world_sync.builds) and world_sync.builds.changed.is_connected(_hook_cabinets):
		world_sync.builds.changed.disconnect(_hook_cabinets)
	for id in _cabinet_scripts:
		var saved: Dictionary = _cabinet_scripts[id]
		var cabinet: Variant = saved.node.get_ref()
		if is_instance_valid(cabinet):
			world_sync.economy._replace(cabinet, saved.script)
	_cabinet_scripts.clear()
	if is_instance_valid(world_sync.economy) and world_sync.economy.completed.is_connected(_completed):
		world_sync.economy.completed.disconnect(_completed)
	if is_instance_valid(world_sync.player) and is_instance_valid(world_sync.player.hand) and _hand_script != null:
		world_sync.economy._replace(world_sync.player.hand, _hand_script)
	_pending.clear()
	_taking.clear()

func active() -> bool:
	return is_instance_valid(mp) and mp.active()

func session_ended() -> void:
	_pending.clear()
	_taking.clear()
	_catalog_size = -1
	applying = false

func valid_index(index: int) -> bool:
	return index >= 0 and index < GameState.needle_positions.size() and index < GameState.needle_type.size()

func committed(index: int) -> bool:
	return GameState.mp_needle_committed.has(index)

func owns(index: int) -> bool:
	return world_sync._holder_of(index) == multiplayer.get_unique_id()

func _request(action: String, args: Dictionary) -> int:
	args["pile_seed"] = GameState.run_seed
	var seq: int = world_sync.economy.request(action, args)
	if seq > 0:
		_pending[seq] = {"action": action, "index": int(args.get("index", -1)), "mode": str(args.get("mode", "hand")), "pile_seed": GameState.run_seed, "at": Time.get_ticks_msec()}
	return seq

func take(body: RigidBody3D, mode: String) -> bool:
	if not active():
		return true
	var index := int(body.get_meta("needle_index", -1))
	if not valid_index(index) or committed(index):
		return false
	if applying or owns(index):
		return true
	if not _taking.has(index):
		var seq := _request("needle_take", {"index": index, "mode": mode, "at": body.global_position})
		if seq > 0:
			_taking[index] = seq
	return false

# A request the host never answered (a lost packet, a session that changed
# under it) would otherwise block every cabinet use for good.
func _busy() -> bool:
	var now := Time.get_ticks_msec()
	for seq in _pending.keys():
		if now - int(_pending[seq].get("at", now)) > 10000:
			_taking.erase(int(_pending[seq].index))
			_pending.erase(seq)
	return not _pending.is_empty()

func withdraw(cabinet: Node3D, type: int) -> bool:
	if _busy():
		return true
	return _request("needle_withdraw", {"type": type, "at": cabinet.global_position}) > 0

func deposit(index: int, cabinet: Node3D) -> bool:
	if _busy():
		return true
	# in our hand but not on our books (the claim got lost on the way): the
	# host decides, it only refuses a needle somebody else holds
	var holder: int = world_sync._holder_of(index)
	if not owns(index) and holder != 0:
		return false
	return _request("needle_deposit", {"index": index, "at": cabinet.global_position}) > 0

func _near(peer: int, at: Vector3, distance: float = 12.0) -> bool:
	var where: Variant = world_sync.player.global_position if peer == 1 else world_sync._last_at.get(peer)
	return where is Vector3 and where.is_finite() and at.is_finite() and where.distance_to(at) <= distance

func _cabinet(at: Vector3) -> Node3D:
	for node in world_sync.builds.cabinets:
		if is_instance_valid(node) and not node.placement_preview and node.global_position.distance_to(at) < 0.1:
			return node
	return null

func execute(peer: int, action: String, args: Dictionary) -> Dictionary:
	var result := _execute(peer, action, args)
	if not bool(result.get("ok", false)):
		# why a needle request was turned down; a guest's needle that would not
		# go into the cabinet left nothing in either log
		var why := str(result.get("why", "?"))
		var text := "needle %s from %d refused: %s (index %s, holder %s)" % [action, peer, why, str(args.get("index", "-")), str(world_sync._holder_of(int(args.index))) if args.get("index") is int else "-"]
		print("[needles] " + text)
		if mp.trace != null:
			mp.trace.note(text)
		result.erase("why")
	return result

func _refused(why: String) -> Dictionary:
	return {"ok": false, "why": why}

func _execute(peer: int, action: String, args: Dictionary) -> Dictionary:
	if not mp.is_host or not mp.players.has(peer) or world_sync._frozen or args.get("pile_seed") != GameState.run_seed:
		return _refused("not now (frozen, unknown player or another pile)")
	var index: int = args.index if args.get("index") is int else -1
	if action == "needle_withdraw":
		if not (args.get("at") is Vector3) or not (args.get("type") is int):
			return _refused("bad request")
		if not _near(peer, args.at):
			return _refused("player not near the cabinet")
		if _cabinet(args.at) == null:
			return _refused("no cabinet there")
		var cabinet := _cabinet(args.at)
		applying = true
		index = cabinet.withdraw(args.type)
		applying = false
		if index < 0:
			return _refused("none of that type in the cabinet")
		publish_catalog()
		_claim(index, peer)
		return {"ok": true, "index": index, "at": cabinet.slot_position(args.type), "mode": "hand"}
	if not (args.get("index") is int) or not valid_index(index):
		return _refused("no such needle")
	if committed(index):
		return _refused("already handed in")
	var owner: int = world_sync._holder_of(index)
	if action == "needle_take":
		if str(args.get("mode", "")) not in ["hand", "vacuum"]:
			return _refused("bad mode")
		var body: Variant = world_sync._needle_bodies().get(index)
		if owner != 0 and owner != peer:
			return _refused("somebody else holds it")
		if not is_instance_valid(body):
			if not (args.get("at") is Vector3) or not _near(peer, args.at):
				return _refused("player not near where the needle is")
			if _bank_contains(index):
				return _refused("banked in a scanner")
			body = world_sync._live().reveal_needle(index, args.at)
		if not is_instance_valid(body):
			return _refused("could not uncover it")
		if not _near(peer, body.global_position):
			return _refused("player not near the needle")
		if owner == 0 and world_sync._live().has_method("is_held_by_a_tool") and world_sync._live().is_held_by_a_tool(body):
			return _refused("held by a tool")
		var at: Vector3 = body.global_position
		_claim(index, peer)
		return {"ok": true, "index": index, "at": at, "mode": args.mode}
	if action == "needle_deposit":
		# Nobody holding it here is fine: the guest has it in hand, and this
		# side lost track of the claim (a resync, a drop that crossed it). Only
		# somebody else's claim says no; it used to say no to every one of
		# these, and the needle fell in front of the cabinet on the guest's
		# screen while it lay in the pile on the host's.
		if owner != peer and owner != 0:
			return _refused("somebody else holds it")
		if not (args.get("at") is Vector3):
			return _refused("bad request")
		if not _near(peer, args.at):
			return _refused("player not near the cabinet")
		if _cabinet(args.at) == null:
			return _refused("no cabinet there")
		applying = true
		_cabinet(args.at).accept(index)
		applying = false
		world_sync._holder.erase(index)
		world_sync._apply_needle("gone", index, Vector3.ZERO, 0)
		world_sync._needle_out("gone", index, Vector3.ZERO, 0)
		return {"ok": true, "index": index}
	if action == "needle_release":
		if owner != peer:
			return _refused("not theirs")
		if not (args.get("at") is Vector3) or not _near(peer, args.at):
			return _refused("player not near")
		world_sync._holder.erase(index)
		world_sync._apply_needle("spawn", index, args.at, 0)
		world_sync._needle_out("spawn", index, args.at, 0)
		return {"ok": true, "index": index}
	return _refused("unknown action")

func _claim(index: int, peer: int) -> void:
	world_sync._holder[index] = peer
	world_sync._apply_needle("claim", index, Vector3.ZERO, peer)
	world_sync._needle_out("claim", index, Vector3.ZERO, peer)

func _completed(seq: int, result: Dictionary) -> void:
	if not _pending.has(seq):
		return
	var entry: Dictionary = _pending[seq]
	_pending.erase(seq)
	_taking.erase(entry.index)
	if entry.pile_seed != GameState.run_seed or not result.get("ok", false):
		return
	var index := int(result.get("index", -1))
	if entry.action not in ["needle_take", "needle_withdraw"] or not valid_index(index):
		return
	var mode := str(result.get("mode", entry.mode))
	world_sync._holder[index] = multiplayer.get_unique_id()
	world_sync._needles[index] = "held"
	applying = true
	var accepted := false
	if mode == "vacuum":
		var body: RigidBody3D = world_sync._needle_bodies().get(index)
		if body == null:
			body = world_sync._live().reveal_needle(index, result.at)
		if is_instance_valid(body) and is_instance_valid(world_sync.player.yard_vac):
			accepted = world_sync.player.yard_vac.mp_accept_needle(body)
	else:
		accepted = world_sync.player.hand.take_needle(index, result.at)
	applying = false
	if not accepted:
		_request("needle_release", {"index": index, "at": world_sync.player.global_position + Vector3.UP * 0.5})

func can_deposit(index: int) -> bool:
	return valid_index(index) and not committed(index) and (mp.is_host or applying)

func can_bank(index: int, scanner: Node) -> bool:
	if not mp.is_host or not valid_index(index) or committed(index) or world_sync._holder_of(index) != 0:
		return false
	for node in world_sync.builds.scanners:
		if not is_instance_valid(node):
			continue
		if node.banked.has(index) or (node != scanner and node._pending.has(index)) or node._flying.has(index):
			return false
	return true

func normalize_scanners() -> void:
	if not mp.is_host:
		return
	var seen := {}
	var changed := false
	for scanner in world_sync.builds.scanners:
		if not is_instance_valid(scanner):
			continue
		for field in ["banked", "_pending", "_flying"]:
			var clean := PackedInt32Array()
			for index in scanner.get(field):
				if not valid_index(index) or committed(index) or world_sync._holder_of(index) != 0 or seen.has(index):
					changed = true
					continue
				seen[index] = true
				clean.append(index)
			if clean != scanner.get(field):
				scanner.set(field, clean)
				scanner._refresh_screen()
				scanner._apply_lamps()
	if changed and is_instance_valid(world_sync.scanner_sync):
		world_sync.scanner_sync.changed()

func _mp_timed_process(delta: float) -> void:
	if not is_instance_valid(mp) or not mp.active() or world_sync._frozen:
		return
	_timer += delta
	if _timer < 1.0:
		return
	_timer = 0.0
	if mp.is_host:
		normalize_scanners()
		if _catalog_size != GameState.needle_positions.size():
			publish_catalog()

func publish_catalog(peer: int = 0) -> void:
	if not mp.is_host:
		return
	_catalog_size = GameState.needle_positions.size()
	var data := {"positions": GameState.needle_positions, "types": GameState.needle_type, "taken": GameState.needle_taken, "out": GameState.needle_out, "committed": GameState.mp_needle_committed}
	if peer > 1:
		mp._rx_needle_catalog.rpc_id(peer, world_sync.economy.epoch, data, mp._outgoing_world_seed())
	else:
		mp._rx_needle_catalog.rpc(world_sync.economy.epoch, data, mp._outgoing_world_seed())

func on_catalog(epoch: String, data: Dictionary) -> void:
	if mp.is_host or epoch != world_sync.economy.epoch or not (data.get("positions") is PackedVector3Array) or not (data.get("types") is PackedByteArray) or not (data.get("taken") is PackedByteArray) or not (data.get("out") is PackedInt32Array) or not (data.get("committed") is Dictionary):
		return
	var count: int = data.positions.size()
	if count > 65536 or data.types.size() != count or data.taken.size() != count:
		return
	GameState.needle_positions = data.positions.duplicate()
	GameState.needle_type = data.types.duplicate()
	GameState.needle_taken = data.taken.duplicate()
	GameState.needle_out = data.out.duplicate()
	GameState.mp_needle_committed = data.committed.duplicate()

func _bank_contains(index: int) -> bool:
	for scanner in world_sync.builds.scanners:
		if is_instance_valid(scanner) and (scanner.banked.has(index) or scanner._pending.has(index) or scanner._flying.has(index)):
			return true
	return false

func released(body: RigidBody3D) -> void:
	if not active():
		return
	if not is_instance_valid(body) or not body.has_meta("needle_index"):
		return
	var index := int(body.get_meta("needle_index"))
	if not valid_index(index) or not owns(index):
		return
	world_sync._holder.erase(index)
	world_sync._needles[index] = "free"
	if mp.is_host:
		world_sync._needle_out("spawn", index, body.global_position, 0, body.linear_velocity)
	else:
		mp._rx_needle_req.rpc_id(1, "drop", index, body.global_position, body.linear_velocity, mp._outgoing_world_seed())

func _hook_cabinets() -> void:
	for cabinet in world_sync.builds.cabinets:
		if not is_instance_valid(cabinet) or cabinet.placement_preview or _cabinet_scripts.has(cabinet.get_instance_id()):
			continue
		var script: Script = cabinet.get_script()
		if script == null or script.resource_path != "res://scripts/build/needle_cabinet.gd":
			continue
		_cabinet_scripts[cabinet.get_instance_id()] = {"node": weakref(cabinet), "script": script}
		world_sync.economy._replace(cabinet, load(mp.base_dir + "/mp_needle_cabinet.gd"))
		cabinet.set("mp_needles", self)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_process(delta)
	__MPCost.add("needle_sync", Time.get_ticks_usec() - __t)
