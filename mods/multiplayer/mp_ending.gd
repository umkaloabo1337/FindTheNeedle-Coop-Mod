extends Node

# The ending, for everyone: the needle case's button, the key it forges, the
# key turned in the floor hatch and the show in the control room below.
#
# The game runs all of it on the machine of whoever does it. In a session the
# others saw nothing: the key was forged on one screen only, the hatch stayed
# shut for the rest (that part was fixed in .88), and the show ended with the
# host leaving for the title screen, which ended the session for everyone.
#
# - A press of the case's button is pressed on every case (guest -> host ->
#   the rest), so every side forges its own key the game's own way.
# - The key is one key: whoever picks it up has it, the others' copies go;
#   where it is put down it lies for everyone.
# - The key turned in the hatch turns it everywhere.
# - The show started below starts for everyone; the others are brought down
#   to the one who started it. Afterwards everyone stays in the yard (the host
#   saves again; in single player the game goes back to the title screen and
#   loads the yard from there).

const TICK := 0.25

var mp: Node
var world: Node
var _t := 0.0
var _remote := false        # applying something another player did
var _held := false          # the key is in our hands
var _key_seen: Node = null  # our copy last tick
var _show_seen := false
var _show_hooked: Node = null
var _hatch_hooked: Node = null
var _title_was := true


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	if _has_show():
		_title_was = bool(EndingShow.to_title)
		# leaving for the title screen ends the session for everyone
		EndingShow.to_title = false


func shutdown() -> void:
	if _has_show():
		EndingShow.to_title = _title_was
	set_process(false)


static func _has_show() -> bool:
	return not Cfg.DEMO


func _process(delta: float) -> void:
	if not is_instance_valid(mp) or not mp.active() or not is_instance_valid(world):
		return
	_t += delta
	if _t < TICK:
		return
	_t = 0.0
	_hook_hatch()
	_watch_key()
	_watch_show()


# ---------------------------------------------------------------- the case

# mp_needle_cabinet: a press on our case
func on_local_press(cab: Node) -> void:
	if _remote or not mp.active():
		return
	var at: Vector3 = (cab as Node3D).global_position
	if mp.is_host:
		mp._rx_ending_press.rpc(at, mp._outgoing_world_seed())
	else:
		mp._rx_ending_press.rpc_id(1, at, mp._outgoing_world_seed())


func on_press(sender: int, at: Vector3) -> void:
	var cab := _cabinet_at(at)
	if cab == null:
		return
	_remote = true
	cab.press_ending()
	_remote = false
	if mp.is_host:
		for pid in mp.players.keys():
			if pid != 1 and pid != sender:
				mp._rx_ending_press.rpc_id(pid, at, mp._outgoing_world_seed())


func _cabinet_at(at: Vector3) -> Node:
	var best: Node = null
	var best_d := 4.0
	for cab in get_tree().get_nodes_in_group("needle_cabinets"):
		if not is_instance_valid(cab) or not cab.has_method("press_ending"):
			continue
		var d := (cab as Node3D).global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = cab
	return best


# ---------------------------------------------------------------- the key

func _key() -> Node:
	var key: Variant = world.get("hatch_key")
	return key if is_instance_valid(key) else null


func _watch_key() -> void:
	var key := _key()
	var held := key != null and key.has_method("is_held") and bool(key.is_held())
	if held and not _held:
		_send_key(true, (key as Node3D).global_transform)
	elif _held and not held and key != null and key == _key_seen:
		# put down or thrown: it lies where it lands, for everyone
		_send_key(false, (key as Node3D).global_transform)
	_held = held
	_key_seen = key


func _send_key(held: bool, xform: Transform3D) -> void:
	if mp.is_host:
		mp._rx_key.rpc(held, xform, mp._outgoing_world_seed())
	else:
		mp._rx_key.rpc_id(1, held, xform, mp._outgoing_world_seed())


func on_key(sender: int, held: bool, xform: Transform3D) -> void:
	if not xform.origin.is_finite():
		return
	var key := _key()
	if key != null and key.has_method("is_held") and bool(key.is_held()):
		pass  # ours is in our hands; theirs goes the other way round
	elif held:
		if key != null:
			# someone else carries it now
			world.set("hatch_key", null)
			key.queue_free()
			_key_seen = null
	elif world.has_method("_spawn_key") and _key_out():
		world.call("_spawn_key", xform, _home())
		_key_seen = _key()
	if mp.is_host:
		for pid in mp.players.keys():
			if pid != 1 and pid != sender:
				mp._rx_key.rpc_id(pid, held, xform, mp._outgoing_world_seed())


func _key_out() -> bool:
	return bool(GameState.get("key_taken"))


func _home() -> Vector3:
	for cab in get_tree().get_nodes_in_group("needle_cabinets"):
		if is_instance_valid(cab) and cab.has_method("read_position"):
			return cab.read_position()
	return GameState.get("key_at") if GameState.get("key_at") is Vector3 else Vector3.ZERO


# ---------------------------------------------------------------- the hatch

func _hook_hatch() -> void:
	var hatch: Variant = world.get("floor_hatch")
	if not is_instance_valid(hatch) or hatch == _hatch_hooked:
		return
	_hatch_hooked = hatch
	if hatch.has_signal("key_turned") and not hatch.key_turned.is_connected(_on_key_turned):
		hatch.key_turned.connect(_on_key_turned)


func _on_key_turned() -> void:
	if _remote or not mp.active():
		return
	if mp.is_host:
		mp._rx_key_turned.rpc(mp._outgoing_world_seed())
	else:
		mp._rx_key_turned.rpc_id(1, mp._outgoing_world_seed())


func on_key_turned(sender: int) -> void:
	var hatch: Variant = world.get("floor_hatch")
	if is_instance_valid(hatch) and hatch.has_method("turn_key") and hatch.has_method("is_locked") \
			and bool(hatch.is_locked()) and not (hatch.has_method("is_turning") and bool(hatch.is_turning())):
		var key := _key()
		if key != null:
			# the key is in the hatch now; ours was a copy
			var carry: Variant = world.get("player").get("carry") if is_instance_valid(world.get("player")) else null
			if carry != null and carry.has_method("held") and carry.held() == key and carry.has_method("stow"):
				carry.stow()
			world.set("hatch_key", null)
			key.queue_free()
			_key_seen = null
			_held = false
		_remote = true
		hatch.turn_key(null)
		_remote = false
	if mp.is_host:
		for pid in mp.players.keys():
			if pid != 1 and pid != sender:
				mp._rx_key_turned.rpc_id(pid, mp._outgoing_world_seed())


# ---------------------------------------------------------------- the show

func _watch_show() -> void:
	if not _has_show():
		return
	var running: Variant = EndingShow.running
	var on := is_instance_valid(running)
	if on and not _show_seen:
		if is_instance_valid(running) and (running as Node).has_signal("finished") \
				and not running.finished.is_connected(_on_show_finished):
			running.finished.connect(_on_show_finished)
		if not _remote:
			var player: Variant = world.get("player")
			var at: Vector3 = (player as Node3D).global_position if is_instance_valid(player) else Vector3.ZERO
			if mp.is_host:
				mp._rx_ending_show.rpc(at, mp._outgoing_world_seed())
			else:
				mp._rx_ending_show.rpc_id(1, at, mp._outgoing_world_seed())
	_show_seen = on


func on_show(sender: int, at: Vector3) -> void:
	if mp.is_host:
		for pid in mp.players.keys():
			if pid != 1 and pid != sender:
				mp._rx_ending_show.rpc_id(pid, at, mp._outgoing_world_seed())
	if not _has_show() or is_instance_valid(EndingShow.running) or not at.is_finite():
		return
	var room: Variant = world.get("control_room")
	if not is_instance_valid(room):
		# the room is built when the hatch opens; open it here first
		if is_instance_valid(mp.world_sync):
			mp.world_sync.open_hatch_here()
		room = world.get("control_room")
	if not is_instance_valid(room) or not room.has_method("start_ending"):
		return
	# come down to the one who started it
	var player: Variant = world.get("player")
	if is_instance_valid(player):
		(player as Node3D).global_position = at
		if "velocity" in player:
			player.velocity = Vector3.ZERO
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(room) or is_instance_valid(EndingShow.running):
		return
	if not bool(room.get("below")) and room.has_method("_set_below"):
		room.call("_set_below", true)
	_remote = true
	_show_seen = true
	room.start_ending()
	_remote = false
	if is_instance_valid(EndingShow.running) and not EndingShow.running.finished.is_connected(_on_show_finished):
		EndingShow.running.finished.connect(_on_show_finished)


# The show is over and everyone is still in the yard. The game had stopped
# saving until the ending was done (it goes back to the title screen and
# loads the yard again); the host saves again from here.
func _on_show_finished() -> void:
	if not mp.active() or not mp.is_host or not is_instance_valid(world):
		return
	world.set("block_save", false)
	if "block_save" in SaveManager:
		SaveManager.block_save = false
	if world.has_method("save_now"):
		world.call("save_now")


# ---------------------------------------------------------------- lost key

# "/schluessel" or "/key" in the chat: the forged key comes to the feet of the
# one who typed it, for everyone. A key that got buried under hay or behind a
# machine held the next load back with no way to find it (the board says to
# turn it in the hatch first).
func request_key(at: Vector3) -> void:
	if mp.is_host:
		fetch_key(1, at)
	else:
		mp._rx_key_fetch.rpc_id(1, at, mp._outgoing_world_seed())


func fetch_key(sender: int, at: Vector3) -> void:
	if not mp.is_host or not at.is_finite() or not _key_out():
		mp.ui.notify("Kein Schlüssel draußen. / No key is out.")
		return
	var key := _key()
	if key != null and key.has_method("is_held") and bool(key.is_held()):
		return  # in the host's hands
	var xform := Transform3D(Basis(Vector3.BACK, PI * 0.5), at + Vector3.UP * 0.4)
	if key != null:
		(key as Node3D).global_transform = xform
		if key is RigidBody3D:
			(key as RigidBody3D).linear_velocity = Vector3.ZERO
			(key as RigidBody3D).angular_velocity = Vector3.ZERO
	elif world.has_method("_spawn_key"):
		world.call("_spawn_key", xform, _home())
	_key_seen = _key()
	mp._rx_key.rpc(false, xform, mp._outgoing_world_seed())
	mp.ui.notify("Schlüssel geholt / key fetched: %s" % mp.player_name(sender))
