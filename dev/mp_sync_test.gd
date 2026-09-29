# Two-player sync checks (dev only, not shipped): a host and a guest on one PC
# over the IP connection. Each check prints a PASS or FAIL line: the pile,
# money and hay, mission payouts, a tech rank bought by both at once, a needle
# grabbed by both at once, a guest's building on the host, a guest pile that
# drifted, and a guest quitting with a needle in hand.
#
# Copy it next to mp.gd as mp_test.gd for the run (it takes the regular
# harness's place), then start both from the game folder:
#   host:  MP_TEST_HOST=1 FindTheNeedle.exe --headless -- --mptest
#          (the user arg makes the game skip the menu; the host loads slot 0)
#   guest: MP_TEST_JOIN=127.0.0.1 FindTheNeedle.exe --headless
# The host drives the steps and prints "[MPTEST] SUMMARY n/m passed"; both quit
# when done. MP_TEST_SKIP=needle leaves the needle steps out, MP_TEST_SKIP=all
# only joins and quits.
extends Node

const PORT := 7777
const JOIN_DELAY := 6.0

var mp: Node
var _host := false
var _results: Array = []   # [name, ok, detail]
var _grab_body: Node = null


func _init() -> void:
	name = "MPTest"  # same path on both sides, for the RPCs below


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_host = OS.get_environment("MP_TEST_HOST") != ""
	if _host:
		if SaveManager.has_save(0):
			SaveManager.begin_load(0)
		else:
			SaveManager.begin_new_game(0)
		mp.host.call_deferred(PORT)
		_run_host.call_deferred()
	else:
		_run_guest.call_deferred()


func _log(text: String) -> void:
	print("[MPTEST] ", text)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout


func _world() -> Node:
	return mp.world_sync.world if mp.world_sync != null else null


# ------------------------------------------------------------------ guest

func _run_guest() -> void:
	await _wait(JOIN_DELAY)
	_log("joining 127.0.0.1:%d" % PORT)
	mp.join(OS.get_environment("MP_TEST_JOIN"), PORT)
	var t := 0.0
	while mp.world_sync == null or mp.phase != mp.Phase.IN_WORLD:
		await _wait(0.5)
		t += 0.5
		if t > 180.0:
			_log("guest never got into the world")
			get_tree().quit(2)
			return
	_log("guest in the world")
	await _wait(120.0)
	_log("guest timed out waiting for the host to finish")
	get_tree().quit(3)


@rpc("authority", "call_remote", "reliable", 0)
func _g_dig(count: int, seed_value: int) -> void:
	var f: Node = _world().field
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for k in count:
		var c := Vector3(rng.randf_range(-3.0, 3.0), 0.0, rng.randf_range(-3.0, 3.0))
		c.y = f.height_at(c.x, c.z)
		var got: float = f.carve_volume(c, 0.5, 0.08)
		GameState.remove_hay(got * Cfg.PACKING / Cfg.STRAND_VOLUME)
		await _wait(0.2)
	_log("guest dug %d scoops" % count)


# The mod only sends a vertex once it moved more than HAY_EPS (2 mm), so the
# two piles agree to within that, not bit for bit.
# Knock our pile out of step without telling anyone (as a lost update or a
# slide that went differently here would), to see whether it gets put right.
@rpc("authority", "call_remote", "reliable", 3)
func _g_drift() -> void:
	var f: Node = _world().field
	var nv: int = f.get("_nv")
	var h: PackedFloat32Array = f.heights
	var c := nv / 2
	for j in range(c - 4, c + 4):
		for i in range(c - 4, c + 4):
			h[j * nv + i] = maxf(0.0, h[j * nv + i] - 0.3)
	f.heights = h
	mp.world_sync._hay_base = f.heights.duplicate()
	_log("guest pile knocked out of step by 0.3 m over 64 vertices")


@rpc("authority", "call_remote", "reliable", 3)
func _g_check_pile(packed: PackedByteArray, raw_size: int, label: String = "pile matches the host's") -> void:
	var theirs: PackedFloat32Array = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	var mine: PackedFloat32Array = _world().field.heights
	var worst := 0.0
	var off := 0
	for i in mini(theirs.size(), mine.size()):
		var d := absf(theirs[i] - mine[i])
		worst = maxf(worst, d)
		if d > 0.003:
			off += 1
	_report.rpc_id(1, label, theirs.size() == mine.size() and worst <= 0.01,
		"%d vertices, largest gap %.4f m, %d over 3 mm" % [mine.size(), worst, off])


@rpc("authority", "call_remote", "reliable", 0)
func _g_check_money(host_money: float, host_dug: float) -> void:
	var ok := absf(GameState.money - host_money) < 0.01 and absf(GameState.hay_dug - host_dug) < 0.5
	_report.rpc_id(1, "money and hay match the host's", ok,
		"host $%.2f / %.1f dug, guest $%.2f / %.1f dug" % [host_money, host_dug, GameState.money, GameState.hay_dug])


@rpc("authority", "call_remote", "reliable", 0)
func _g_check_missions() -> void:
	var paid := 0
	for i in MissionBook.count():
		if GameState.missions_paid.has(String(MissionBook.id_at(i))):
			paid += 1
	_report.rpc_id(1, "guest leaves mission payouts to the host", paid == MissionBook.count(),
		"%d of %d marked paid" % [paid, MissionBook.count()])


@rpc("authority", "call_remote", "reliable", 0)
func _g_buy(id: String) -> void:
	var ok := Tech.buy(id)
	_log("guest bought %s: %s" % [id, ok])


@rpc("authority", "call_remote", "reliable", 3)
func _g_grab(idx: int) -> void:
	var body: Variant = mp.world_sync._needle_bodies().get(idx)
	if body == null:
		_log("guest has no needle %d to grab" % idx)
		return
	_world().player.hand._grab(body)
	_log("guest grabbed needle %d" % idx)


@rpc("authority", "call_remote", "reliable", 0)
func _g_report_needle(idx: int) -> void:
	_report.rpc_id(1, "needle holder (guest)", true, str(_world().player.hand.held_needle_index() == idx))


@rpc("authority", "call_remote", "reliable", 0)
func _g_add_building(d: Dictionary) -> void:
	mp.world_sync._add_buildings([d])
	_log("guest placed a %s" % d.get("type", "?"))


@rpc("authority", "call_remote", "reliable", 0)
func _g_quit() -> void:
	await _wait(1.0)
	get_tree().quit(0)


# ------------------------------------------------------------------ host

@rpc("any_peer", "call_remote", "reliable", 0)
func _report(what: String, ok: bool, detail: String) -> void:
	_results.append([what, ok, detail])
	_log("%s %s (%s)" % ["PASS" if ok else "FAIL", what, detail])


func _check(what: String, ok: bool, detail: String) -> void:
	_report(what, ok, detail)


func _guest_id() -> int:
	for pid in mp.players:
		if pid != 1 and str(mp.players[pid].get("state", "")) == "world":
			return int(pid)
	return 0


func _run_host() -> void:
	var t := 0.0
	while _guest_id() == 0:
		await _wait(0.5)
		t += 0.5
		if t > 240.0:
			_log("no guest reached the world")
			get_tree().quit(2)
			return
	var gid := _guest_id()
	_log("guest %d is in the world" % gid)
	await _wait(4.0)
	var ws: Node = mp.world_sync
	var w: Node = _world()
	if "all" in OS.get_environment("MP_TEST_SKIP").split(","):
		_log("SUMMARY join only")
		_g_quit.rpc_id(gid)
		await _wait(2.0)
		get_tree().quit(0)
		return

	# 1. both dig at once; the host's pile settles and is the reference
	_g_dig.rpc_id(gid, 10, 7)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in 5:
		var c := Vector3(rng.randf_range(-2.0, 2.0), 0.0, rng.randf_range(-2.0, 2.0))
		c.y = w.field.height_at(c.x, c.z)
		var got: float = w.field.carve_volume(c, 0.5, 0.08)
		GameState.remove_hay(got * Cfg.PACKING / Cfg.STRAND_VOLUME)
		await _wait(0.3)
	await _wait(10.0)
	w.field.settle_join()
	ws._hay_tick(true)
	var raw := var_to_bytes(w.field.heights)
	_g_check_pile.rpc_id(gid, raw.compress(FileAccess.COMPRESSION_ZSTD), raw.size())
	await _wait(1.5)

	# 2. shared money, right behind a state snapshot on the same channel
	ws._state_tick()
	_g_check_money.rpc_id(gid, GameState.money, GameState.hay_dug)
	await _wait(1.0)

	# 3. missions pay on the host only
	_g_check_missions.rpc_id(gid)
	await _wait(1.0)

	# 4. both buy the same tech rank at the same moment
	var card := ""
	for id in TechTree.ids():
		var cb: Dictionary = Tech.can_buy(String(id))
		if cb.get("ok", false) and float(cb.get("cost", 0.0)) > 0.0 \
		and float(cb.get("cost", 0.0)) * 3.0 < GameState.money:
			card = String(id)
			break
	if card == "":
		_check("tech bought twice is refunded", false, "no affordable card to test with")
	else:
		var rank_before := int(Tech.ranks.get(card, 0))
		var refunds_before := int(ws.get("tech_refunds")) if ws.get("tech_refunds") != null else 0
		_g_buy.rpc_id(gid, card)
		Tech.buy(card)
		await _wait(3.0)
		var rank_now := int(Tech.ranks.get(card, 0))
		var refunds := (int(ws.get("tech_refunds")) if ws.get("tech_refunds") != null else 0) - refunds_before
		_check("tech bought twice is refunded", refunds == 1 and rank_now == rank_before + 1,
			"%s rank %d -> %d, %d refund(s)" % [card, rank_before, rank_now, refunds])

	# 5. both grab the same needle; exactly one may keep it
	var skip := OS.get_environment("MP_TEST_SKIP").split(",")
	var idx := -1
	for i in GameState.needle_taken.size():
		if GameState.needle_taken[i] == 0:
			idx = i
			break
	if "needle" in skip:
		_log("needle step skipped")
	elif idx < 0:
		_check("needle grabbed by both is held once", false, "no buried needle left to test with")
	else:
		var at: Vector3 = w.player.global_position + Vector3(0.0, 1.0, 0.0)
		GameState.needle_taken[idx] = 1
		w.live.reveal_needle(idx, at)
		await _wait(2.0)
		var body: Variant = ws._needle_bodies().get(idx)
		_g_grab.rpc_id(gid, idx)
		if body != null:
			w.player.hand._grab(body)
		await _wait(2.5)
		var host_holds: bool = w.player.hand.held_needle_index() == idx
		var holders: Variant = ws.get("_holder")
		var holder := int(holders.get(idx, 0)) if holders is Dictionary else -1
		_g_report_needle.rpc_id(gid, idx)
		await _wait(1.0)
		var guest_holds := false
		for r in _results:
			if r[0] == "needle holder (guest)":
				guest_holds = r[2] == "true"
		_check("needle grabbed by both is held once", host_holds != guest_holds and (holder == -1 or holder == (1 if host_holds else gid)),
			"host holds %s, guest holds %s, host says holder %d" % [host_holds, guest_holds, holder])

	# 6. a guest's building must not wipe the host's withheld demo buildings
	var marker := {"type": "mp_test_marker"}
	w.builds.demo_withheld.append(marker)
	var count_before: int = w.builds.to_array().size()
	var sample: Dictionary = {}
	var types := {}
	for d in w.builds.to_array():
		if d is Dictionary:
			types[str(d.get("type", ""))] = true
	_log("building types in this yard: %s" % ", ".join(PackedStringArray(types.keys())))
	for want in ["work_lamp", "wall", "railing", "platform", "deck", "power_pole", "paint_board", "stairs"]:
		for d in w.builds.to_array():
			if d is Dictionary and str(d.get("type", "")) == want and d.has("position"):
				sample = (d as Dictionary).duplicate(true)
				break
		if not sample.is_empty():
			break
	if sample.is_empty():
		_check("guest building keeps the host's withheld list", false, "no simple building to copy")
	else:
		sample["position"] = (sample["position"] as Vector3) + Vector3(0.0, 0.0, 1.5)
		_g_add_building.rpc_id(gid, sample)
		await _wait(3.0)
		var kept: bool = w.builds.demo_withheld.has(marker)
		var added: int = w.builds.to_array().size() - count_before
		_check("guest building keeps the host's withheld list", kept and added == 1,
			"withheld kept %s, buildings +%d (%s)" % [kept, added, sample.get("type", "")])
	w.builds.demo_withheld.erase(marker)

	# 7. a guest pile that drifted gets put right again
	_g_drift.rpc_id(gid)
	await _wait(9.0)
	w.field.settle_join()
	ws._hay_tick(true)
	var raw2 := var_to_bytes(w.field.heights)
	_g_check_pile.rpc_id(gid, raw2.compress(FileAccess.COMPRESSION_ZSTD), raw2.size(), "drifted guest pile is repaired")
	await _wait(1.5)

	# 8. a guest who quits holding a needle drops it where it stood
	var idx2 := -1
	for i in GameState.needle_taken.size():
		if GameState.needle_taken[i] == 0:
			idx2 = i
			break
	var guest_gone := false
	if idx2 >= 0 and ws.get("_last_at") != null:
		GameState.needle_taken[idx2] = 1
		w.live.reveal_needle(idx2, w.player.global_position + Vector3(1.5, 1.0, 0.0))
		await _wait(2.0)
		_g_grab.rpc_id(gid, idx2)
		await _wait(2.5)
		var was_at: Vector3 = ws._last_at.get(gid, Vector3.ZERO)
		var gone_before: bool = not ws._needle_bodies().has(idx2)
		_g_quit.rpc_id(gid)
		guest_gone = true
		await _wait(6.0)
		var body: Variant = ws._needle_bodies().get(idx2)
		var near: bool = body != null and (body as Node3D).global_position.distance_to(was_at) < 3.0
		_check("needle held by a guest who quits is dropped", gone_before and near,
			"left the host while held: %s, back near the guest: %s" % [gone_before, near])

	var passed := 0
	for r in _results:
		if r[0] != "needle holder (guest)" and r[1]:
			passed += 1
	var total := 0
	for r in _results:
		if r[0] != "needle holder (guest)":
			total += 1
	_log("SUMMARY %d/%d passed" % [passed, total])
	if not guest_gone:
		_g_quit.rpc_id(gid)
	await _wait(2.0)
	get_tree().quit(0 if passed == total else 1)
