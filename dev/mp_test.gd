# Automated two-instance test harness. Only active when the game is started
# with env vars, e.g.
#   MP_TEST_HOST=user://saves/slot_1.dat  FindTheNeedle.exe
#   MP_TEST_JOIN=127.0.0.1               FindTheNeedle.exe
# It drives a session on its own and prints [MPTEST] lines to stdout.
extends Node

var mp: Node
var role := ""
var arg := ""
var _t := 0.0
var _report_t := 0.0
var _world_t := -1.0
var _did := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# user args would make the game skip its menu (dev mode), so use env vars
	if OS.get_environment("MP_TEST_HOST") != "":
		role = "host"
		arg = OS.get_environment("MP_TEST_HOST")
	elif OS.get_environment("MP_TEST_JOIN") != "":
		role = "join"
		arg = OS.get_environment("MP_TEST_JOIN")
	elif OS.get_environment("MP_TEST_AVATAR") != "":
		role = "avatar"
		arg = OS.get_environment("MP_TEST_AVATAR")
	elif OS.get_environment("MP_TEST_STEAM") != "":
		role = "steam"
		_probe_steam.call_deferred()
	if role == "":
		queue_free()
		return
	# test copies get killed sometimes; clearing the sentinel avoids a false
	# "crash" dialog. (Do NOT disable CrashReport: it is what removes the
	# sentinel on a clean exit.)
	_clear_sentinel()
	print("[MPTEST] role=%s arg=%s" % [role, arg])


func _clear_sentinel() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_clear_sentinel()


func _process(delta: float) -> void:
	_t += delta
	var limit := float(OS.get_environment("MP_TEST_SECONDS")) if OS.get_environment("MP_TEST_SECONDS") != "" else 180.0
	if _t > limit and not _did.has("quit"):
		_did["quit"] = true
		print("[MPTEST] time is up, quitting")
		_clear_sentinel()
		get_tree().quit()
	if role == "avatar" and not _did.has("start") and _t > 3.0 and mp.is_menu(get_tree().current_scene):
		_did["start"] = true
		SaveManager.use_scratch_dir("user://mp_test_host")
		DirAccess.copy_absolute(ProjectSettings.globalize_path(arg), ProjectSettings.globalize_path(SaveManager.slot_path(0)))
		SaveManager.begin_load(0)
		Loading.show_screen("TEST", "AVATAR")
		Loading.enter_scene(mp.GAME_SCENE)
	if role == "avatar" and mp.world_sync != null and not _did.has("avatar"):
		_did["avatar"] = true
		_show_avatar()
	if role == "host" and not _did.has("start") and _t > 3.0 and mp.is_menu(get_tree().current_scene):
		_did["start"] = true
		mp.my_name = "Anfitrion"
		mp.host(mp.DEFAULT_PORT)
		SaveManager.use_scratch_dir("user://mp_test_host")
		var dst := SaveManager.slot_path(0)
		DirAccess.copy_absolute(ProjectSettings.globalize_path(arg), ProjectSettings.globalize_path(dst))
		SaveManager.begin_load(0)
		Loading.show_screen("TEST", "HOST")
		Loading.enter_scene(mp.GAME_SCENE)
	if role == "join" and not _did.has("start") and _t > 3.0 and mp.is_menu(get_tree().current_scene):
		_did["start"] = true
		mp.my_name = "Cliente"
		mp.join(arg, mp.DEFAULT_PORT)
	if mp.world_sync != null:
		if _world_t < 0.0:
			_world_t = _t
			print("[MPTEST] in world at %.1fs" % _t)
		var wt := _t - _world_t
		if wt > 12.0 and not _did.has("act1"):
			_did["act1"] = true
			_act()
		if wt > 20.0 and not _did.has("act2") and role == "join":
			_did["act2"] = true
			_act_remove()
		if wt > 15.0 and not _did.has("props"):
			_did["props"] = true
			_act_props()
		if wt > 26.0 and not _did.has("props2"):
			_did["props2"] = true
			_act_props_move()
		if wt > 22.0 and not _did.has("straws") and role == "host":
			_did["straws"] = true
			_act_straws()
		if wt > 26.0 and not _did.has("machine") and role == "host":
			_did["machine"] = true
			_act_machine()
		if wt > 31.0 and not _did.has("wiggle") and role == "host":
			_did["wiggle"] = true
			_wiggle_part()
		if wt > 30.0 and not _did.has("belt") and role == "host":
			_did["belt"] = true
			_act_belt()
		if wt > 34.0 and not _did.has("belt_shot"):
			_did["belt_shot"] = true
			_look_at_belt()
		if wt > 40.0 and not _did.has("grab") and role == "host":
			_did["grab"] = true
			_grab_theirs()
		if wt > 8.0 and not _did.has("shot_world"):
			_did["shot_world"] = true
			_look_at_avatar()
		if wt > 11.0 and not _did.has("shot_world2"):
			_did["shot_world2"] = true
			_shot("world")
	if role != "steam" and mp.is_menu(get_tree().current_scene) and _t > 6.0 and not _did.has("shot_menu"):
		_did["shot_menu"] = true
		mp.ui.open_panel()
		await get_tree().create_timer(1.0).timeout
		_shot("menu")
		mp.ui.close_panel()
	_report_t += delta
	if _report_t >= 4.0:
		_report_t = 0.0
		_report()


func _act() -> void:
	var ws: Node = mp.world_sync
	var p: Node3D = ws.player
	var at := p.global_position + (-p.global_transform.basis.z) * 3.0
	if role == "host":
		var taken: PackedByteArray = GameState.needle_taken
		for i in taken.size():
			if taken[i] == 0:
				ws._live().reveal_needle(i, p.global_position + Vector3(0.5, 1.0, 0.0))
				print("[MPTEST] host revealed needle %d" % i)
				break
		GameState.add_money(100.0)
		var c := Vector3(2.0, 0.0, 2.0)
		var got: float = ws.field.carve_volume(c, 1.2, 3.0)
		print("[MPTEST] host carved %.3f at %s, +100 money" % [got, c])
	else:
		GameState.add_money(7.0)
		var c := Vector3(-2.0, 0.0, -2.0)
		var got: float = ws.field.carve_volume(c, 1.2, 3.0)
		ws.builds.add_platform(Vector3(at.x, 0.3, at.z), Vector2(2.0, 2.0))
		print("[MPTEST] client carved %.3f at %s, +7 money, platform at %s" % [got, c, at])


func _act_remove() -> void:
	var ws: Node = mp.world_sync
	for b in ws._live().needles:
		if is_instance_valid(b):
			print("[MPTEST] client consumes needle %d" % int(b.get_meta("needle_index", -1)))
			ws._live().consume_needle(b)
			break
	var decks: Array = ws.builds.platforms
	if decks.size() > 0:
		var d: Node3D = decks[decks.size() - 1]
		print("[MPTEST] client demolishing platform at %s" % d.global_position)
		ws.builds.demolish(d)


# each side drops an item of its own, then we check both lists match
func _act_props() -> void:
	var ws: Node = mp.world_sync
	var props: Node = ws.world.get("props")
	var id := "bucket" if role == "host" else "hay_bale"
	var it: Variant = props.spawn_at_feet(id, ws.player)
	print("[MPTEST] %s spawned %s -> %s" % [role, id, it != null])


func _act_props_move() -> void:
	var ws: Node = mp.world_sync
	var ps: Node = ws.props_sync
	for pid in ps._by_id:
		if not ps._mine(pid):
			continue
		var it: Node3D = ps._by_id[pid]
		if not is_instance_valid(it):
			continue
		it.global_position += Vector3(0.0, 1.5, 0.0)
		print("[MPTEST] %s nudged prop %d (%s) to %s" % [role, pid, it.item_id, it.global_position])
		return


# a belt with a few wads on it: the client should end up with the same ride
func _act_belt() -> void:
	var ws: Node = mp.world_sync
	var a: Vector3 = ws.world._seat(Vector3(6.0, 0.0, 8.0)) + Vector3.UP * 1.2
	var b: Vector3 = ws.world._seat(Vector3(12.0, 0.0, 8.0)) + Vector3.UP * 1.2
	var conv: Node = ws.builds.add_conveyor(a, b)
	await get_tree().process_frame
	var n := 0
	for i in 5:
		if conv.run.board(0, 20, -1, 0.25, 0.0, 0.0, 0.6 * float(i + 1), 0.0, {}, -1, false):
			n += 1
	print("[MPTEST] host laid a conveyor and boarded %d wads, run=%d" % [n, conv.run.count()])


# walk up to an item the other player owns and try to pick it up: the copy
# has to carry its collision shape with it or the aim ray goes straight past
func _grab_theirs() -> void:
	var ws: Node = mp.world_sync
	var ps: Node = ws.props_sync
	var target: Node3D = null
	var tid := 0
	for pid in ps._by_id:
		if ps._mine(pid):
			continue
		var it: Variant = ps._by_id[pid]
		if it != null and is_instance_valid(it) and it.item_id != "sand_shovel":
			target = it
			tid = pid
			break
	if target == null:
		print("[MPTEST] %s has nothing of theirs to grab" % role)
		return
	var p: Node3D = ws.player
	var at: Vector3 = target.global_position
	p.global_position = ws.world._seat(Vector3(at.x + 1.0, 0.0, at.z))
	p.velocity = Vector3.ZERO
	await get_tree().create_timer(0.6).timeout
	# aim from the eye, not from the feet, or the ray goes over the item
	var d: Vector3 = at - p.eye_position()
	p.set_look(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))
	await get_tree().create_timer(0.8).timeout
	print("[MPTEST] %s reach=%.2f distance=%.2f" % [role, Tech.carry_reach(), d.length()])
	var hit: Variant = p.carry._probe()
	var ok: bool = p.carry.try_pick()
	await get_tree().create_timer(0.5).timeout
	print("[MPTEST] %s grabbing %s (id=%d): ray hit %s, picked=%s, carrying=%s, now mine=%s" % [
		role, target.item_id, tid,
		hit.item_id if hit != null else "nothing",
		ok, p.carry.is_carrying(), ps._mine(tid)])
	await _shot("grab")


# both sides look at the belt, so the screenshots can be put side by side
func _look_at_belt() -> void:
	var ws: Node = mp.world_sync
	var p: Node3D = ws.player
	var mid: Vector3 = ws.world._seat(Vector3(9.0, 0.0, 8.0)) + Vector3.UP * 1.2
	# not the same spot on both sides, or one camera ends up inside the other
	# player's farmer
	var side := -0.8 if role == "host" else 0.8
	var from: Vector3 = ws.world._seat(Vector3(9.0 + side, 0.0, 2.5)) + Vector3.UP * 0.4
	p.global_position = from
	var d := mid - from
	p.set_look(atan2(-d.x, -d.z), -0.12)
	await get_tree().create_timer(1.5).timeout
	await _shot("belt")
	var riders := 0
	for b in BeltPath._live:
		if is_instance_valid(b) and b.is_inside_tree():
			riders += b.run.count()
	print("[MPTEST] %s sees %d riders on the belts" % [role, riders])


func _props_line() -> String:
	var ws: Node = mp.world_sync
	var ps: Variant = ws.props_sync
	if ps == null:
		return "props=?"
	var mine := 0
	var copies := 0
	for pid in ps._by_id:
		if ps._mine(pid):
			mine += 1
		else:
			copies += 1
	var total: int = ws.world.get("props").items.size()
	var paths := 0
	var riders := 0
	for b in BeltPath._live:
		if not is_instance_valid(b) or not b.is_inside_tree():
			continue
		paths += 1
		riders += b.run.count()
	var tally := {}
	for it in ws.world.get("props").items:
		if is_instance_valid(it):
			tally[it.item_id] = int(tally.get(it.item_id, 0)) + 1
	var ids: Array = tally.keys()
	ids.sort()
	var parts: Array = []
	for k in ids:
		parts.append("%s:%d" % [k, tally[k]])
	return "props=%d tracked=%d mine=%d copies=%d belts=%d riders=%d [%s]" % [
		total, ps._by_id.size(), mine, copies, paths, riders, ",".join(parts)]


func _report() -> void:
	var ws: Node = mp.world_sync
	if ws == null:
		var cs: Node = get_tree().current_scene
		print("[MPTEST] phase=%d players=%d scene=%s world=%s built=%s watch=%s" % [
			mp.phase, mp.players.size(), str(cs.name) if cs else "-",
			mp.is_world(cs), cs.get("_built") if cs else "-", mp._world_watch != null])
		return
	var h: PackedFloat32Array = ws.field.heights
	var sum := 0.0
	for v in h:
		sum += v
	var nb: int = ws.builds.to_array().size()
	var nn := 0
	for b in ws._live().needles:
		if is_instance_valid(b):
			nn += 1
	print("[MPTEST] needles=%d money=%.2f hay_total=%.1f hay_dug=%.1f heights_sum=%.3f builds=%d avatars=%d tech=%d players=%d %s" % [
		nn, GameState.money, GameState.hay_total, GameState.hay_dug, sum, nb, ws.avatars.size(), Tech.ranks.size(), mp.players.size(), _props_line() + " " + _mach_line() + " " + _probe_part() + " " + _straw_line()])


# both players meet at the (open) new-game spawn; the client looks at the host
func _look_at_avatar() -> void:
	var ws: Node = mp.world_sync
	if role == "host":
		ws.player.global_position = ws.world._seat(Vector3(13.2, 0.4, 2.6))
		return
	await get_tree().create_timer(1.0).timeout
	for id in ws.avatars:
		var a: Node3D = ws.avatars[id]
		var p: Node3D = ws.player
		var d := a.global_position - p.global_position
		d.y = 0.0
		var yaw := atan2(-d.x, -d.z)
		p.set_look(yaw, -0.1)
		print("[MPTEST] avatar %d at %s, me at %s" % [id, a.global_position, p.global_position])
		return


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "D:/FindTheNeedleMP/test/shot_%s_%s.png" % [role, tag]
	img.save_png(path)
	print("[MPTEST] screenshot ", path)


# Diagnostics for the Steam route: load the extension, start Steam, and print
# what the extension actually gives us.
func _probe_steam() -> void:
	await get_tree().create_timer(4.0).timeout
	print("[MPSTEAM] steam_ready=%s persona=%s status=%s" % [mp.steam_ready(), mp.steam.persona, mp.steam.load_status])
	mp.ui.open_panel()
	await get_tree().create_timer(1.0).timeout
	_shot("panel")
	mp.host_steam()
	await get_tree().create_timer(6.0).timeout
	var peer: Object = multiplayer.multiplayer_peer
	print("[MPSTEAM] phase=%d over_steam=%s is_host=%s lobby=%d" % [mp.phase, mp.over_steam, mp.is_host, mp.steam.lobby_id])
	print("[MPSTEAM] peer=%s status=%s unique_id=%d" % [peer, peer.get_connection_status() if peer != null else -1, multiplayer.get_unique_id()])
	print("[MPSTEAM] players=", mp.players)
	_shot("panel_hosting")
	await get_tree().create_timer(2.0).timeout
	mp.leave("fin de la prueba")
	await get_tree().create_timer(1.0).timeout
	print("[MPSTEAM] after leave phase=%d" % mp.phase)
	_clear_sentinel()
	get_tree().quit()


# Single-instance look at the remote-player puppet: put one in front of the
# player on open ground and photograph it.
func _show_avatar() -> void:
	var ws: Node = mp.world_sync
	var p: Node3D = ws.player
	p.global_position = ws.world._seat(Vector3(12.4, 0.0, 12.4))
	await get_tree().create_timer(1.0).timeout
	# same tool twice, close up: left = current, right = turned 180 degrees
	var mid: Vector3 = ws.world._seat(Vector3(9.6, 0.0, 10.6))
	var tool_id := int(OS.get_environment("MP_TEST_TOOL")) if OS.get_environment("MP_TEST_TOOL") != "" else 1
	for i in 2:
		var av: Node3D = load(mp.base_dir + "/mp_avatar.gd").new()
		av.setup("A" if i == 0 else "B (180)", Color(0.3, 0.65, 0.98))
		av.flip_tool = i == 1
		ws.world.add_child(av)
		av.set_target(mid + Vector3(float(i) * 2.4 - 1.2, 0.0, 0.0), PI, 0.0, tool_id, 0.0, 0.0)
	var d := mid - p.global_position
	p.set_look(atan2(-d.x, -d.z), -0.05)
	await get_tree().create_timer(2.0).timeout
	await _shot("tool%d" % tool_id)
	print("[MPTEST] tool shot done for tool %d" % tool_id)
	mp.host_steam()
	await get_tree().create_timer(5.0).timeout
	ws.player.set_look(ws.player.rotation.y, -1.15)
	await get_tree().create_timer(1.5).timeout
	await _shot("firstperson")
	mp.ui._toggle_debug_menu()
	await get_tree().create_timer(1.5).timeout
	await _shot("debugmenu")
	var dm: Variant = ws.world.get("debug_menu")
	print("[MPTEST] debug menu open=%s" % (dm != null and dm.is_open()))
	_clear_sentinel()
	get_tree().quit()


var _mach_prev := {}

# how many machine parts moved since the last report: on a client that only
# happens if the host's poses are arriving
func _mach_line() -> String:
	var ws: Node = mp.world_sync
	var ms: Variant = ws.machines_sync
	if ms == null:
		return "mach=?"
	var n := 0
	var parts := 0
	var moved := 0
	for key in ms._nodes:
		n += 1
		var list: Array = ms._parts_of(key)
		parts += list.size()
		for i in list.size():
			var node: Variant = list[i]
			if node == null or not is_instance_valid(node):
				continue
			var k := "%s#%d" % [key, i]
			var xf: Transform3D = (node as Node3D).transform
			var was: Variant = _mach_prev.get(k)
			if was != null and (was as Transform3D).origin.distance_to(xf.origin) > 0.002:
				moved += 1
			_mach_prev[k] = xf
	return "mach=%d parts=%d moved=%d" % [n, parts, moved]


# Build a rake and drive its clip by hand: the host's factory may be idle, and
# what we are testing is whether the movement reaches the other side.
func _act_machine() -> void:
	var ws: Node = mp.world_sync
	var at: Vector3 = ws.world._seat(Vector3(6.0, 0.0, 12.0))
	var rake: Variant = ws.builds.add_piston_rake(at, 0.0)
	if rake == null:
		print("[MPTEST] could not place a rake")
		return
	await get_tree().create_timer(2.0).timeout
	var ap: AnimationPlayer = _find_anim(rake)
	if ap == null:
		print("[MPTEST] the rake carries no AnimationPlayer")
		return
	var list: PackedStringArray = ap.get_animation_list()
	if list.is_empty():
		print("[MPTEST] the rake's player has no clips")
		return
	ap.process_mode = Node.PROCESS_MODE_ALWAYS
	ap.speed_scale = 0.3
	ap.play(list[0])
	print("[MPTEST] host drives rake clip '%s' of %d" % [list[0], list.size()])


func _find_anim(n: Node) -> AnimationPlayer:
	for child in n.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer
		var deeper := _find_anim(child)
		if deeper != null:
			return deeper
	return null


# the same part on both sides, to compare where each one thinks it is
func _probe_part() -> String:
	var ws: Node = mp.world_sync
	var ms: Variant = ws.machines_sync
	if ms == null or ms._nodes.is_empty():
		return "probe=-"
	var keys: Array = ms._nodes.keys()
	keys.sort()
	var parts: Array = ms._parts_of(keys[0])
	if parts.size() < 9:
		return "probe=short"
	var p: Node3D = parts[8]
	return "probe=%s#8 %.3f,%.3f,%.3f" % [String(keys[0]).substr(0, 14),
		p.transform.origin.x, p.transform.origin.y, p.transform.origin.z]


# throw a handful of real straws where the other player is standing
func _act_straws() -> void:
	var ws: Node = mp.world_sync
	var live: Node = ws._live()
	var at: Vector3 = ws.player.global_position + Vector3(0.0, 1.4, 0.0)
	var made := 0
	for i in 30:
		var p := at + Vector3(randf_range(-0.6, 0.6), randf_range(0.0, 0.5), randf_range(-0.6, 0.6))
		var b: Variant = live.spawn(p, Basis(), Vector3(randf_range(-1.0, 1.0), 1.5, randf_range(-1.0, 1.0)),
			Color(0.86, 0.72, 0.36))
		if b != null:
			made += 1
	print("[MPTEST] %s threw %d straws at %v" % [role, made, at])


func _straw_line() -> String:
	var ws: Node = mp.world_sync
	var ss: Variant = ws.strands_sync
	if ss == null:
		return "straw=?"
	var live: Node = ws._live()
	var total := 0
	if live != null and live.has_method("active_count"):
		total = int(live.active_count())
	return "straw=%d mine=%d copies=%d" % [total, ss._mine.size(), ss._ghost.size()]


# The rake will not run without power, so move one of its parts by hand for a
# few seconds: what we are checking is that the movement reaches the client.
func _wiggle_part() -> void:
	var ws: Node = mp.world_sync
	var ms: Variant = ws.machines_sync
	if ms == null or ms._nodes.is_empty():
		print("[MPTEST] no machine to wiggle")
		return
	var keys: Array = ms._nodes.keys()
	keys.sort()
	var parts: Array = ms._parts_of(keys[0])
	if parts.size() < 9:
		print("[MPTEST] machine has only %d parts" % parts.size())
		return
	var p: Node3D = parts[8]
	var base: Vector3 = p.position
	print("[MPTEST] host wiggling part 8 of %s from %v" % [keys[0], base])
	for i in 420:
		p.position = base + Vector3(0.0, sin(float(i) * 0.06) * 0.3, 0.0)
		await get_tree().process_frame
	p.position = base
	print("[MPTEST] host stopped wiggling")
