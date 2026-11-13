extends Node
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

# Delivery contracts.
#
# The game's DeliveryDirector calls the truck, counts what lands in its bed and
# pays when the order is full. Left running on every player it did all of that
# once per player: each had their own truck on their own timer, and a finished
# contract paid on the guest too, which reached the host as more money, so the
# bonus came twice.
#
# Only the host's director runs now. A guest's is stopped, and the host sends
# the contract as it stands; the guest's truck, stack and board follow it.

const TICK := 0.5
const FULL_TICK := 3.0   # everything again now and then, for a guest that just came in
const MAX_CALL_WAIT := 3600.0
const MAX_SIGN_OFF := 60.0
# EA v14 keeps part of a contract's progress and the depot it draws from in
# GameState fields of their own. The host's copy is the one that counts.
const HOST_DICTS := ["contract_parts", "depot_stock", "depot_refused", "depot_limits"]
const MAX_DICT := 512
# What a player sets on the depot's panel. A guest's change goes to the host;
# until the host echoes it, the host's older value does not undo it.
const DEPOT_SETTINGS := ["depot_refused", "depot_limits"]
const PENDING_MS := 3000

var mp: Node
var world: Node
var _t := 0.0
var _full_t := 0.0
var _last := {}
var _stopped := false
var _agreed := {}    # guest: depot setting -> value both sides last agreed on
var _pending := {}   # guest: depot setting -> [value sent, msec]
var _rigged := false # guest: truck set up for the current contract
var _load_tried := [] # guest: [contract, host's count] we last rebuilt the truck for
var _cd_hooked := false # guest: our bay door no longer opens on our own countdown
var _cd_opened := false # guest: the host's countdown ran out and ours opened
var _rates := preload("res://mods/multiplayer/mp_depot_rates.gd").new()
var _host_door := -1.0  # guest: the bay door's opening the host last stated


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node


func shutdown() -> void:
	var dd := _director()
	if _stopped and dd != null:
		dd.set_process(true)
	_stopped = false
	_rates.shutdown()
	var board := _countdown_board()
	if _cd_hooked and board != null and world.has_method("_on_countdown_expired") 			and not board.expired.is_connected(world._on_countdown_expired):
		board.expired.connect(world._on_countdown_expired)
	_cd_hooked = false
	_cd_opened = false


func _director() -> Node:
	var dd: Variant = world.get("deliveries") if world != null and is_instance_valid(world) else null
	return dd if dd != null and is_instance_valid(dd) else null


func _truck() -> Node:
	var tr: Variant = world.get("truck") if world != null and is_instance_valid(world) else null
	return tr if tr != null and is_instance_valid(tr) else null


func _mp_timed_process(delta: float) -> void:
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if not mp.is_host:
		var dd := _director()
		if dd != null and dd.is_processing():
			dd.set_process(false)
			_stopped = true
		_send_depot_settings()
		_hook_countdown()
		return
	if mp.players.size() < 2:
		return
	_t += delta
	_full_t += delta
	if _t < TICK:
		return
	_t = 0.0
	var now := _state()
	if now == _last and _full_t < FULL_TICK:
		return
	_full_t = 0.0
	_last = now
	mp._rx_contract.rpc(now, mp._outgoing_world_seed())


func _send_depot_settings() -> void:
	for field in DEPOT_SETTINGS:
		if not _agreed.has(field) or not (field in GameState):
			continue
		var local: Variant = GameState.get(field)
		if not (local is Dictionary) or local == _agreed[field]:
			continue
		_agreed[field] = local.duplicate(true)
		_pending[field] = [local.duplicate(true), Time.get_ticks_msec()]
		mp._rx_depot_setting.rpc_id(1, field, local, mp._outgoing_world_seed())


static func valid_setting(field: String, value: Variant) -> bool:
	if field not in DEPOT_SETTINGS or not (value is Dictionary) or value.size() > MAX_DICT:
		return false
	for key in value:
		if not (key is String or key is StringName or key is int):
			return false
		var v: Variant = value[key]
		if not (v is bool or v is int or (v is float and is_finite(v))):
			return false
	return true


# Host: a guest worked the depot panel.
func on_setting(field: String, value: Variant) -> void:
	if not mp.is_host or not valid_setting(field, value) or not (field in GameState):
		return
	GameState.set(field, value.duplicate(true))
	if GameState.has_signal("depot_changed"):
		GameState.depot_changed.emit()
	_full_t = FULL_TICK


# Host: the whole contract to one guest at once (join or F2 resync).
func send_to(pid: int) -> void:
	if mp == null or not mp.is_host:
		return
	mp._rx_contract.rpc_id(pid, _state(), mp._outgoing_world_seed())


func _state() -> Dictionary:
	var tr := _truck()
	var state := {
		"index": GameState.contract_index,
		"delivered": GameState.contract_delivered,
		"done": GameState.contracts_done.keys(),
		"truck": int(tr.get("state")) if tr != null else -1,
		"truck_here": bool(GameState.get("contract_truck_here")),
		# what the host's truck shows, so a guest can tell its own is behind
		"shown": int(tr.load_shown()) if tr != null and tr.has_method("load_shown") else -1,
		"load": truck_load(tr),
	}
	var board := _countdown_board()
	if board != null:
		# the bay door's countdown (the forcetron behind it) is counted in each
		# player's profile per save slot; a guest's slot is its own, so it
		# follows the host's instead
		state["cd"] = {"spent": maxi(0, int(CountdownBoard.TOTAL_SECONDS) - int(board.remaining())), "done": bool(board.is_spent())}
	var door: Variant = world.get("bay_door") if is_instance_valid(world) else null
	if is_instance_valid(door) and door.has_method("open_amount"):
		state["door"] = snappedf(float(door.open_amount()), 0.05)
	for field in HOST_DICTS:
		var value: Variant = GameState.get(field)
		if value is Dictionary:
			state[field] = value.duplicate(true)
	var dd := _director()
	if dd != null:
		state["call_in"] = _timer(dd.get("_call_in"), -1.0, -1.0, MAX_CALL_WAIT)
		state["sign_off"] = _timer(dd.get("_sign_off"), 0.0, 0.0, MAX_SIGN_OFF)
	if is_instance_valid(world):
		state["rates"] = _rates.host_rates(self, world.get("builds"))
	return state


func _timer(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	if not (value is float or value is int):
		return fallback
	var seconds := float(value)
	return seconds if is_finite(seconds) and seconds >= minimum and seconds <= maximum else fallback


func on_state(s: Dictionary) -> void:
	if mp.is_host:
		return
	_rates.apply(world, s.get("rates", {}))
	var index := int(s.get("index", GameState.contract_index))
	var delivered := int(s.get("delivered", 0))
	var was_index: int = GameState.contract_index
	var was_delivered: int = GameState.contract_delivered
	var tr := _truck()
	# a contract closed on the host: tick it off here too
	if index > was_index:
		var dd := _director()
		if dd != null and dd.get("panel") != null:
			dd.panel.mark_complete(DeliveryBook.title_of(was_index))
		Audio.play("sell_register", -2.0)
		Audio.play_delayed("coins", 0.18, -3.0)
		was_delivered = 0
	GameState.contract_index = index
	GameState.contract_delivered = delivered
	var done := {}
	for id in s.get("done", []):
		done[str(id)] = true
	# which contracts, not how many: one finished on each side kept the count
	# equal and the list wrong
	var theirs: Array = done.keys()
	theirs.sort()
	var ours: Array = []
	for id in GameState.contracts_done:
		ours.append(str(id))
	ours.sort()
	if theirs != ours:
		GameState.contracts_done = done
		GameState.contracts_changed.emit()
	_apply_countdown(s.get("cd"))
	_apply_door(s.get("door"))
	if s.get("truck_here") is bool and "contract_truck_here" in GameState:
		GameState.set("contract_truck_here", s.truck_here)
	var parts_changed := false
	var depot_changed := false
	for field in HOST_DICTS:
		var value: Variant = s.get(field)
		if not (value is Dictionary) or value.size() > MAX_DICT or not (field in GameState):
			continue
		if field in DEPOT_SETTINGS:
			var pending: Variant = _pending.get(field)
			if pending != null:
				if pending[0] != value and Time.get_ticks_msec() - int(pending[1]) < PENDING_MS:
					continue
				_pending.erase(field)
			_agreed[field] = value.duplicate(true)
		if GameState.get(field) != value:
			GameState.set(field, value.duplicate(true))
			if field == "contract_parts":
				parts_changed = true
			else:
				depot_changed = true
	if parts_changed:
		GameState.contracts_changed.emit()
	if depot_changed and GameState.has_signal("depot_changed"):
		GameState.depot_changed.emit()
	if tr != null:
		_follow_truck(tr, int(s.get("truck", -1)))
		# EA contracts count each kind on its own (the dairy: bales and
		# wrapped bales); the truck lays its bed out from those counts
		if index != was_index:
			_rigged = false
		# A truck that drives off clears its bed (DeliveryTruck._run_leaving),
		# and the host's director lays it out again when it calls the truck
		# for the next contract. The new contract starts while the old truck
		# is still leaving, so ours was laid out once, cleared on the way out
		# and stayed bare for good (contract 17: the host's truck 57, ours 0).
		# Lay it out whenever it is bare, once it is no longer driving off.
		var bed: Variant = tr.get("_load")
		var bare: bool = bed is Dictionary and (bed as Dictionary).is_empty() and not DeliveryBook.load_plan(index).is_empty()
		var leaving := int(tr.get("state")) == DeliveryTruck.State.LEAVING
		if (not _rigged or bare) and not leaving:
			# the host's director sets the truck (and the trailer of a big
			# order) up for each new contract; ours is stopped, so do it here
			var rig := _director()
			if rig != null and rig.has_method("_rig"):
				rig._rig(index)
				_rigged = true
				parts_changed = true
		var host_load: Variant = s.get("load")
		_match_load(tr, index, delivered, int(s.get("shown", -1)), parts_changed,
			host_load if host_load is Dictionary and host_load.size() <= 32 else {})
	var dd2 := _director()
	if dd2 != null:
		if s.has("call_in"):
			dd2.set("_call_in", _timer(s.call_in, float(dd2.get("_call_in")), -1.0, MAX_CALL_WAIT))
		if s.has("sign_off"):
			dd2.set("_sign_off", _timer(s.sign_off, float(dd2.get("_sign_off")), 0.0, MAX_SIGN_OFF))
		dd2._restate()


func _countdown_board() -> Node:
	var door: Variant = world.get("bay_door") if world != null and is_instance_valid(world) else null
	var board: Variant = door.get("countdown") if is_instance_valid(door) else null
	return board if is_instance_valid(board) and board.has_signal("expired") else null


# Guest: our own countdown must not open the bay door; the host's does.
func _hook_countdown() -> void:
	if _cd_hooked:
		return
	var board := _countdown_board()
	if board == null or not world.has_method("_on_countdown_expired"):
		return
	if board.expired.is_connected(world._on_countdown_expired):
		board.expired.disconnect(world._on_countdown_expired)
	_cd_hooked = true


func _apply_countdown(cd: Variant) -> void:
	if mp.is_host or not (cd is Dictionary) or not (cd.get("spent") is int) or not (cd.get("done") is bool):
		return
	_hook_countdown()
	var board := _countdown_board()
	var pf := get_node_or_null("/root/Profile")
	if board == null or pf == null:
		return
	var spent: Variant = pf.get("countdown_spent")
	var slot := int(board.slot())
	if spent is Array and slot >= 0 and slot < spent.size():
		spent[slot] = clampi(int(cd.spent), 0, int(CountdownBoard.TOTAL_SECONDS))
	if bool(cd.done) and not _cd_opened:
		_cd_opened = true
		world._on_countdown_expired()


# Guest: the bay door stands as the host's does. It is the forcetron's door and
# the loading door the delivery truck comes through, so it opens on the host
# for either reason. (Shutting it on a guest whenever the host's countdown
# still ran kept the truck's door shut there.)
func _apply_door(amount: Variant) -> void:
	if mp.is_host or not (amount is float or amount is int) or not is_finite(float(amount)):
		return
	var door: Variant = world.get("bay_door")
	if not is_instance_valid(door) or not door.has_method("open_amount") or door.is_moving():
		return
	var want := clampf(float(amount), 0.0, 1.0)
	# only when the host's door moved: a guest may work the door itself
	if is_equal_approx(want, _host_door):
		return
	_host_door = want
	if absf(float(door.open_amount()) - want) <= 0.05:
		return
	if want >= 0.95 and door.has_method("open"):
		door.open(1.0, -80.0)
	elif want <= 0.05 and door.has_method("snap_shut"):
		door.snap_shut()
	elif door.has_method("set_open_amount"):
		door.set_open_amount(want)


# Guest: make our truck show what the host's shows. It used to follow single
# events (one more delivered: stack one), and a missed one, or a new contract
# starting, left it empty for good. Now the truck is laid out again from the
# contract's state whenever its count differs from the host's.
func _match_load(tr: Node, index: int, delivered: int, host_shown: int, parts_changed: bool, host_load: Dictionary = {}) -> void:
	if not tr.has_method("restore_load"):
		return
	var ours := int(tr.load_shown()) if tr.has_method("load_shown") else -1
	var behind := host_shown >= 0 and ours >= 0 and ours != host_shown
	if not host_load.is_empty() and _named(truck_load(tr), index) != _named(host_load, index):
		behind = true
	if not parts_changed and not behind:
		_load_tried = []
		return
	if not parts_changed and _load_tried == [index, host_shown, host_load]:
		return
	# the host's truck, kind by kind, when it told us; else the contract
	tr.restore_load(_named(host_load, index) if not host_load.is_empty() else _load_parts(index, delivered))
	_load_tried = [index, host_shown, host_load]
	var now := int(tr.load_shown()) if tr.has_method("load_shown") else -1
	if host_shown >= 0 and now != host_shown and mp.trace != null:
		mp.trace.note("truck load: host shows %d, ours %d after rebuild, contract %d, parts %s, delivered %d" % [host_shown, now, index, str(GameState.contract_parts).left(200), delivered])


# How many of each kind a truck shows ({kind: count}).
static func truck_load(tr: Node) -> Dictionary:
	var out := {}
	if tr == null:
		return out
	var load: Variant = tr.get("_load")
	if not (load is Dictionary):
		return out
	for kind in load:
		var mmi: Variant = load[kind]
		if mmi is MultiMeshInstance3D and (mmi as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			var shown: int = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
			# a kind laid out with none shows the same as one never laid out
			# (a guest's rebuilt truck has the first, the host's the second)
			if shown > 0:
				out[str(kind)] = shown
	return out


# The host's per-kind load for this contract's kinds only, 0 for a kind it
# does not list, so restore_load() sets every kind (it leaves unnamed ones).
static func _named(host_load: Dictionary, index: int) -> Dictionary:
	var out := {}
	for row in DeliveryBook.load_plan(index):
		if row is Array and row.size() >= 2:
			var kind := str(row[0])
			var v: Variant = host_load.get(kind, 0)
			out[kind] = clampi(int(v) if (v is int or v is float) else 0, 0, int(row[1]))
	return out


# What the current contract has had loaded, by kind. The truck's
# restore_load() replaces only the kinds it is given (an empty one changes
# nothing), so every kind of this contract is named, 0 where nothing came yet,
# and nothing left over from the contract before. Tested on every contract in
# the book: the truck shows exactly these counts.
static func _load_parts(index: int, delivered: int) -> Dictionary:
	var have: Dictionary = GameState.contract_parts if GameState.contract_parts is Dictionary else {}
	var plan: Array = DeliveryBook.load_plan(index)
	var parts := {}
	for row in plan:
		if not (row is Array) or row.size() < 2:
			continue
		var kind := str(row[0])
		var count := int(have.get(kind, 0))
		if plan.size() == 1:
			count = maxi(count, delivered)
		parts[kind] = clampi(count, 0, int(row[1]))
	return parts


# The one kind a contract asks for. The demo kept it in "want"; EA contracts
# list their kinds under "wants", and one with several is counted per kind.
static func _single_want(index: int) -> String:
	var contract: Dictionary = DeliveryBook.contract(index)
	var want := str(contract.get("want", ""))
	if want != "":
		return want
	var wants: Variant = contract.get("wants")
	if wants is Array and wants.size() == 1 and wants[0] is Dictionary:
		return str(wants[0].get("item", wants[0].get("want", "")))
	return ""


# The truck drives itself once told to come or go, so only the moves are sent.
func _follow_truck(tr: Node, want: int) -> void:
	var st := int(tr.get("state"))
	if want < 0 or want == st:
		return
	match want:
		DeliveryTruck.State.ARRIVING:
			tr.arrive()
		DeliveryTruck.State.PARKED:
			if st == DeliveryTruck.State.AWAY:
				tr.snap_parked()
		DeliveryTruck.State.LEAVING, DeliveryTruck.State.AWAY:
			if st == DeliveryTruck.State.ARRIVING:
				tr.snap_parked()
			tr.depart()


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_process(delta)
	__MPCost.add("contracts", Time.get_ticks_usec() - __t)
