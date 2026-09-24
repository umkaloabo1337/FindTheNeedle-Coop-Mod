# Find The Needle - Multiplayer mod (autoload "MPMod").
# Loaded from override.cfg. Owns the ENet session, the lobby flow, the world
# hand-off and every RPC. Per-world syncing lives in mp_world.gd.
extends Node

const VERSION := "0.10.0"
const DEFAULT_PORT := 7777
const MAX_PEERS := 8
const WORLD_CHUNK := 60000
const SESSION_DIR := "user://mp_session"
const SETTINGS_PATH := "user://mp_settings.cfg"
const GAME_SCENE := "res://scenes/main.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"

const COLORS := [
	Color(0.95, 0.35, 0.3), Color(0.3, 0.65, 0.98), Color(0.4, 0.85, 0.4),
	Color(0.98, 0.78, 0.25), Color(0.75, 0.45, 0.95), Color(0.3, 0.9, 0.85),
	Color(0.98, 0.55, 0.8), Color(0.9, 0.9, 0.9),
]

enum Phase { OFFLINE, HOSTING, CONNECTING, LOBBY, LOADING, IN_WORLD }

var base_dir := ""
var ui: Node = null
var world_sync: Node = null
var phase: int = Phase.OFFLINE
var is_host := false
var players := {}  # peer id -> {name, color, state}
var my_name := "Player"  # replaced by the Steam name or the saved one
var last_ip := "127.0.0.1"
var last_port := DEFAULT_PORT

var i18n: RefCounted = null  # mp_i18n.gd: UI strings in the game's language
var steam: Node = null  # mp_steam.gd: Steam relay transport (no port forwarding)
var over_steam := false  # is the current session running through Steam?

var _last_scene: Node = null
var _world_rx := {}
var _pending_world: Variant = null
var _mp_world_load := false  # client is loading a world sent by the host
var _world_watch: Node = null
var _steam_hosting := false  # waiting for our own lobby to be created
var _steam_joining := false  # we asked to join someone else (Steam also
# reports lobby_joined to the creator, which is not a join we should act on)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	base_dir = get_script().resource_path.get_base_dir()
	i18n = load(base_dir + "/mp_i18n.gd").new()
	_load_settings()
	ui = load(base_dir + "/mp_ui.gd").new()
	ui.mp = self
	add_child(ui)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	steam = load(base_dir + "/mp_steam.gd").new()
	steam.name = "MPSteam"
	add_child(steam)
	steam.lobby_created.connect(_on_steam_lobby_created)
	steam.lobby_joined.connect(_on_steam_lobby_joined)
	steam.join_requested.connect(_on_steam_join_requested)
	_start_steam.call_deferred()
	if OS.get_environment("MP_TEST_HOST") != "" or OS.get_environment("MP_TEST_JOIN") != "" or OS.get_environment("MP_TEST_STEAM") != "" or OS.get_environment("MP_TEST_AVATAR") != "":
		# the test harness is a dev-only file and is not shipped in releases
		var test_script: Script = load(base_dir + "/mp_test.gd") if FileAccess.file_exists(base_dir + "/mp_test.gd") else null
		if test_script != null:
			var test: Node = test_script.new()
			test.mp = self
			add_child(test)
	for f in ["mp_world.gd", "mp_avatar.gd", "mp_i18n.gd"]:
		var s: Script = load(base_dir + "/" + f)
		if s == null or not s.can_instantiate():
			push_error("[MPMod] %s failed to compile" % f)
	print("[MPMod] v%s loaded from %s" % [VERSION, base_dir])


# UI string in whatever language the game is set to.
func t(key: String) -> String:
	return i18n.t(key)


func _process(_delta: float) -> void:
	var cs := get_tree().current_scene
	if cs != _last_scene:
		_last_scene = cs
		_on_scene_changed(cs)
	if _world_watch != null and is_instance_valid(_world_watch) and world_sync == null:
		if bool(_world_watch.get("_built")):
			_start_world_sync(_world_watch)


# ---------------------------------------------------------------- scenes

func is_world(n: Node) -> bool:
	# exported scripts may be remapped to .gdc, so recognise the world by its members
	return n != null and "_built" in n and "field" in n and "builds" in n


func is_menu(n: Node) -> bool:
	return n != null and (n.scene_file_path == MENU_SCENE or n.has_method("_on_multiplayer"))


func _on_scene_changed(cs: Node) -> void:
	_stop_world_sync()
	_world_watch = null
	if is_menu(cs):
		ui.hook_menu(cs)
		if active() and not is_host and phase == Phase.IN_WORLD:
			# client walked back to the title: that ends its session
			leave(t("left_game"))
		elif active() and is_host:
			# clients drop back to the lobby and get the world again when we return
			for pid in players.keys():
				if pid != 1:
					players[pid]["state"] = "lobby"
			_broadcast_host_in_world(false)
	elif is_world(cs):
		_world_watch = cs


func _start_world_sync(world: Node) -> void:
	world_sync = load(base_dir + "/mp_world.gd").new()
	world_sync.name = "MPWorld"
	world_sync.mp = self
	world_sync.world = world
	add_child(world_sync)
	if not active():
		return
	if is_host:
		_broadcast_host_in_world(true)
		for pid in players.keys():
			if pid != 1 and str(players[pid].get("state", "")) != "world":
				send_world(pid)
	elif _mp_world_load:
		_mp_world_load = false
		phase = Phase.IN_WORLD
		world_sync.place_at_spawn()
		ui.notify(t("connected_yard"))
		_rx_client_ready.rpc_id(1)


func _stop_world_sync() -> void:
	if world_sync != null:
		world_sync.shutdown()
		world_sync.queue_free()
		world_sync = null


func in_world() -> bool:
	return world_sync != null


func active() -> bool:
	return phase != Phase.OFFLINE


# ---------------------------------------------------------------- Steam session
# Steam's relay does the NAT work: both players connect out to Steam, so
# nobody opens a port and friends join from the Steam friends list.

func _start_steam() -> void:
	var res: Dictionary = steam.setup(base_dir)
	print("[MPMod] steam: ", res["status"])
	if not res["ok"]:
		ui.refresh()
		return
	if _custom_name == "":
		my_name = steam.persona.substr(0, 24)
	ui.refresh()
	# launched by accepting an invite while the game was closed
	var lobby: int = steam.lobby_from_command_line()
	if lobby != 0:
		join_steam(lobby)


func steam_ready() -> bool:
	return steam != null and steam.available


func host_steam() -> bool:
	if not steam_ready():
		ui.notify(t("steam_unavailable_long"))
		return false
	if active():
		leave()
	_steam_hosting = true
	_steam_joining = false
	ui.notify(t("steam_creating"))
	steam.host_lobby(MAX_PEERS)
	return true


func join_steam(lobby_id: int) -> bool:
	if not steam_ready():
		ui.notify(t("steam_unavailable"))
		return false
	if active():
		leave()
	ui.notify(t("steam_entering"))
	_steam_joining = true
	_steam_hosting = false
	phase = Phase.CONNECTING
	steam.join_lobby(lobby_id)
	ui.refresh()
	return true


func invite_friends() -> void:
	if steam_ready() and steam.lobby_id != 0:
		steam.invite_overlay()
	else:
		ui.notify(t("create_first"))


func _on_steam_lobby_created(ok: bool, id: int) -> void:
	if not _steam_hosting:
		return
	_steam_hosting = false
	if not ok:
		ui.notify(t("steam_create_failed"))
		return
	var peer: MultiplayerPeer = steam.make_peer()
	if peer == null:
		ui.notify(t("steam_peer_failed"))
		return
	peer.call("host_with_lobby", id)
	multiplayer.multiplayer_peer = peer
	over_steam = true
	_become_host()
	ui.notify(t("game_created"))


func _on_steam_lobby_joined(ok: bool, id: int, reason: String) -> void:
	if not _steam_joining:
		return  # Steam tells the creator it "joined" its own lobby; ignore that
	_steam_joining = false
	if not ok:
		leave(t("steam_join_failed") % reason)
		return
	var peer: MultiplayerPeer = steam.make_peer()
	if peer == null:
		leave(t("steam_peer_failed"))
		return
	peer.call("connect_to_lobby", id)
	multiplayer.multiplayer_peer = peer
	over_steam = true
	is_host = false
	phase = Phase.CONNECTING
	ui.refresh()


func _on_steam_join_requested(lobby_id: int) -> void:
	# invite accepted (overlay or friends list) while the game is running
	join_steam(lobby_id)


# ---------------------------------------------------------------- session

func _become_host() -> void:
	is_host = true
	phase = Phase.HOSTING
	players = {1: {"name": my_name, "color": COLORS[0], "state": "world" if in_world() else "menu"}}
	_mp_guard_online_services()
	if world_sync != null:
		world_sync.rebaseline()
		world_sync.apply_session_rules()
	if not in_world():
		ui.notify(t("now_load"))
	ui.refresh()


func host(port: int) -> bool:
	if active():
		leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		ui.notify(t("port_failed") % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	over_steam = false
	last_port = port
	_save_settings()
	ui.notify(t("server_open") % port)
	_become_host()
	return true


func join(ip: String, port: int) -> bool:
	if active():
		leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		ui.notify(t("peer_failed") % err)
		return false
	multiplayer.multiplayer_peer = peer
	over_steam = false
	is_host = false
	phase = Phase.CONNECTING
	last_ip = ip
	last_port = port
	_save_settings()
	ui.notify(t("connecting"))  # no addresses on screen: people stream this
	ui.refresh()
	return true


func leave(reason: String = "") -> void:
	var was_client := active() and not is_host
	var was_in_mp_world := was_client and in_world()
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_ready():
		steam.leave_lobby()
	over_steam = false
	_steam_hosting = false
	_steam_joining = false
	phase = Phase.OFFLINE
	is_host = false
	players.clear()
	_world_rx.clear()
	_mp_world_load = false
	if world_sync != null:
		world_sync.clear_avatars()
	if was_client:
		SaveManager.block_save = false
		SaveManager.use_player_saves()
	if reason != "":
		ui.notify(reason)
	ui.refresh()
	if was_in_mp_world:
		# the client's world is a borrowed copy; never let it linger or save
		get_tree().change_scene_to_file(MENU_SCENE)


func _mp_guard_online_services() -> void:
	# keep modded runs off the public leaderboard
	var lb := get_node_or_null("/root/Leaderboard")
	if lb != null and "enabled" in lb:
		lb.enabled = false


func _on_peer_connected(id: int) -> void:
	if is_host:
		print("[MPMod] peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		ui.notify(t("left") % players[id]["name"])
		players.erase(id)
	if world_sync != null:
		world_sync.remove_avatar(id)
	if is_host:
		_rx_players.rpc(players)
		if world_sync != null:
			world_sync.forget_peer(id)
	ui.refresh()


func _on_connected() -> void:
	phase = Phase.LOBBY
	ui.notify(t("connected_waiting"))
	_rx_hello.rpc_id(1, my_name, VERSION)
	ui.refresh()


func _on_connection_failed() -> void:
	leave(t("connect_failed"))


func _on_server_disconnected() -> void:
	leave(t("host_closed"))


func _broadcast_host_in_world(on: bool) -> void:
	if players.has(1):
		players[1]["state"] = "world" if on else "menu"
	_rx_players.rpc(players)
	ui.refresh()


func player_name(id: int) -> String:
	if players.has(id):
		return str(players[id]["name"])
	return t("player_fallback") % id


func player_color(id: int) -> Color:
	if players.has(id):
		return players[id]["color"]
	return Color.WHITE


# ---------------------------------------------------------------- lobby RPCs

@rpc("any_peer", "call_remote", "reliable")
func _rx_hello(pname: String, ver: String) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if ver != VERSION:
		_rx_kick.rpc_id(id, t("version_mismatch") % [VERSION, ver])
		return
	var used := {}
	for p in players.values():
		used[p["color"]] = true
	var col: Color = COLORS[players.size() % COLORS.size()]
	for c in COLORS:
		if not used.has(c):
			col = c
			break
	pname = pname.strip_edges().substr(0, 24)
	if pname == "":
		pname = t("player_fallback") % id
	players[id] = {"name": pname, "color": col, "state": "lobby"}
	ui.notify(t("joined") % pname)
	_rx_players.rpc(players)
	ui.refresh()
	if in_world():
		send_world(id)


@rpc("authority", "call_remote", "reliable")
func _rx_kick(reason: String) -> void:
	leave(reason)


@rpc("authority", "call_remote", "reliable")
func _rx_players(list: Dictionary) -> void:
	var before := players.keys()
	players = list
	if world_sync != null:
		for id in before:
			if not players.has(id):
				world_sync.remove_avatar(id)
	if not is_host and players.has(1) and phase == Phase.IN_WORLD and in_world() 	and str(players[1].get("state", "")) == "menu":
		phase = Phase.LOBBY
		SaveManager.block_save = false
		SaveManager.use_player_saves()
		ui.notify(t("host_back_menu"))
		get_tree().change_scene_to_file(MENU_SCENE)
	elif not is_host and players.has(1) and phase == Phase.LOBBY:
		if str(players[1].get("state", "")) != "world":
			ui.set_status(t("host_in_menu"))
	ui.refresh()


@rpc("any_peer", "call_remote", "reliable")
func _rx_client_ready() -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		players[id]["state"] = "world"
		_rx_players.rpc(players)
	if world_sync != null:
		world_sync.send_full_sync(id)
	ui.refresh()


@rpc("any_peer", "call_remote", "reliable")
func _rx_chat(text: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	ui.chat_line(player_name(id), player_color(id), text.substr(0, 200))


func send_chat(text: String) -> void:
	text = text.strip_edges()
	if text == "" or not active():
		return
	_rx_chat.rpc(text)
	ui.chat_line(my_name, player_color(multiplayer.get_unique_id()), text)


# ---------------------------------------------------------------- world hand-off

func send_world(id: int) -> void:
	if world_sync == null:
		return
	var payload: Dictionary = world_sync.build_payload(id)
	var raw := var_to_bytes(payload)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var n := int(ceil(float(packed.size()) / WORLD_CHUNK))
	if players.has(id):
		players[id]["state"] = "loading"
	print("[MPMod] sending world to %d: %d KB (%d KB raw), %d chunks" % [id, packed.size() / 1024, raw.size() / 1024, n])
	_rx_world_begin.rpc_id(id, raw.size(), packed.size(), n)
	for i in n:
		_rx_world_chunk.rpc_id(id, i, packed.slice(i * WORLD_CHUNK, mini((i + 1) * WORLD_CHUNK, packed.size())))
	_rx_world_end.rpc_id(id)


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_begin(raw_size: int, packed_size: int, chunks: int) -> void:
	_world_rx = {"raw": raw_size, "size": packed_size, "n": chunks, "parts": {}}
	phase = Phase.LOADING
	ui.set_status(t("receiving_world"))
	ui.set_progress(0.0)


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_chunk(i: int, data: PackedByteArray) -> void:
	if _world_rx.is_empty():
		return
	_world_rx["parts"][i] = data
	ui.set_progress(float(_world_rx["parts"].size()) / maxf(1.0, float(_world_rx["n"])))


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_end() -> void:
	if _world_rx.is_empty():
		return
	var packed := PackedByteArray()
	for i in int(_world_rx["n"]):
		if not _world_rx["parts"].has(i):
			leave(t("world_incomplete"))
			return
		packed.append_array(_world_rx["parts"][i])
	var raw := packed.decompress(int(_world_rx["raw"]), FileAccess.COMPRESSION_ZSTD)
	_world_rx.clear()
	var payload: Variant = bytes_to_var(raw)
	if typeof(payload) != TYPE_DICTIONARY:
		leave(t("world_unreadable"))
		return
	ui.set_progress(-1.0)
	_enter_mp_world(payload)


func _enter_mp_world(payload: Dictionary) -> void:
	_stop_world_sync()
	SaveManager.use_scratch_dir(SESSION_DIR)
	var path := SaveManager.slot_path(0)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		leave(t("world_write_failed") % FileAccess.get_open_error())
		return
	f.store_var(payload, true)
	f.close()
	SaveManager.block_save = false
	SaveManager.begin_load(0)
	_mp_world_load = true
	phase = Phase.LOADING
	ui.set_status(t("loading_world"))
	ui.close_panel()
	Loading.show_screen("FIND THE NEEDLE", "ENTRANDO AL PAJAR DE %s" % player_name(1).to_upper())
	Loading.enter_scene(GAME_SCENE)


# Host: re-send the whole world to every client (after a new pile, or on demand).
func resync_all() -> void:
	if not is_host or world_sync == null:
		return
	for pid in players.keys():
		if pid != 1:
			send_world(pid)


@rpc("any_peer", "call_remote", "reliable")
func _rx_request_world() -> void:
	if is_host and world_sync != null:
		send_world(multiplayer.get_remote_sender_id())


func request_resync() -> void:
	if not active():
		return
	if is_host:
		resync_all()
		ui.notify(t("resyncing_all"))
	else:
		_rx_request_world.rpc_id(1)
		ui.notify(t("asking_world"))


# ---------------------------------------------------------------- in-world RPCs (forwarded to mp_world)

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _rx_pose(pos: Vector3, yaw: float, pitch: float, tool: int, crouch: float, moving: float) -> void:
	if world_sync != null:
		world_sync.on_pose(multiplayer.get_remote_sender_id(), pos, yaw, pitch, tool, crouch, moving)


@rpc("any_peer", "call_remote", "reliable", 3)
func _rx_hay(idx: PackedInt32Array, vals: PackedFloat32Array) -> void:
	if world_sync != null:
		world_sync.on_hay(idx, vals)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rx_builds(adds: Array, removes: Array) -> void:
	if world_sync != null:
		world_sync.on_builds(adds, removes)


@rpc("any_peer", "call_remote", "reliable", 5)
func _rx_state_delta(seq: int, delta: Dictionary) -> void:
	if is_host and world_sync != null:
		world_sync.on_state_delta(multiplayer.get_remote_sender_id(), seq, delta)


@rpc("authority", "call_remote", "reliable", 5)
func _rx_state_snap(ack: int, snap: Dictionary) -> void:
	if world_sync != null:
		world_sync.on_state_snap(ack, snap)


@rpc("any_peer", "call_remote", "reliable", 5)
func _rx_tech(id: String, rank: int) -> void:
	if world_sync != null:
		world_sync.on_tech(id, rank)


@rpc("authority", "call_remote", "reliable", 6)
func _rx_full_sync(heights: PackedFloat32Array, builds: Array, tech: Dictionary, needles: Array) -> void:
	if world_sync != null:
		world_sync.on_full_sync(heights, builds, tech, needles)


@rpc("any_peer", "call_remote", "reliable", 5)
func _rx_new_pile_request() -> void:
	if is_host and world_sync != null:
		world_sync.host_new_pile_for_client(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable", 3)
func _rx_needle(kind: String, idx: int, pos: Vector3) -> void:
	if world_sync != null:
		world_sync.on_needle(kind, idx, pos)


@rpc("any_peer", "call_remote", "reliable", 5)
func _rx_event(kind: String, data: Dictionary) -> void:
	if world_sync != null:
		world_sync.on_event(multiplayer.get_remote_sender_id(), kind, data)


# ---------------------------------------------------------------- loose items

func _props() -> Node:
	if world_sync == null:
		return null
	return world_sync.props_sync


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_add(id: int, item_id: String, xf: Transform3D, state: Dictionary) -> void:
	var p := _props()
	if p != null:
		p.on_add(multiplayer.get_remote_sender_id(), id, item_id, xf, state)


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_del(ids: PackedInt64Array) -> void:
	var p := _props()
	if p != null:
		p.on_del(ids)


@rpc("any_peer", "call_remote", "unreliable_ordered", 8)
func _rx_prop_move(ids: PackedInt64Array, xfs: Array) -> void:
	var p := _props()
	if p != null:
		p.on_move(multiplayer.get_remote_sender_id(), ids, xfs)


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_state(ids: PackedInt64Array, states: Array) -> void:
	var p := _props()
	if p != null:
		p.on_state(multiplayer.get_remote_sender_id(), ids, states)


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_claim(id: int) -> void:
	var p := _props()
	if p != null:
		p.on_claim(multiplayer.get_remote_sender_id(), id)


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_want(ids: PackedInt64Array) -> void:
	var p := _props()
	if p != null:
		p.on_want(multiplayer.get_remote_sender_id(), ids)


@rpc("any_peer", "call_remote", "reliable", 7)
func _rx_prop_census(ids: PackedInt64Array) -> void:
	var p := _props()
	if p != null:
		p.on_census(multiplayer.get_remote_sender_id(), ids)


@rpc("authority", "call_remote", "reliable", 7)
func _rx_prop_reset(first: bool, ids: PackedInt64Array, owners: PackedInt32Array, entries: Array) -> void:
	var p := _props()
	if p != null:
		p.on_reset(first, ids, owners, entries)


@rpc("authority", "call_remote", "reliable", 7)
func _rx_prop_reset_end() -> void:
	var p := _props()
	if p != null:
		p.on_reset_end()


@rpc("authority", "call_remote", "reliable", 9)
func _rx_belts(packed: PackedByteArray, raw_size: int) -> void:
	if world_sync == null or world_sync.belts_sync == null:
		return
	world_sync.belts_sync.on_belts(packed, raw_size)


# ---------------------------------------------------------------- machines

@rpc("authority", "call_remote", "unreliable_ordered", 10)
func _rx_machines(packed: PackedByteArray, raw_size: int) -> void:
	if world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_poses(packed, raw_size)


@rpc("authority", "call_remote", "reliable", 10)
func _rx_machine_fields(batch: Dictionary) -> void:
	if world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_fields(batch)


# ---------------------------------------------------------------- loose straw

func _straws() -> Node:
	if world_sync == null:
		return null
	return world_sync.strands_sync


@rpc("any_peer", "call_remote", "reliable", 11)
func _rx_straw_add(adds: Array) -> void:
	var s := _straws()
	if s != null:
		s.on_add(multiplayer.get_remote_sender_id(), adds)


@rpc("any_peer", "call_remote", "unreliable_ordered", 12)
func _rx_straw_move(ids: PackedInt64Array, rows: PackedFloat32Array) -> void:
	var s := _straws()
	if s != null:
		s.on_move(ids, rows)


@rpc("any_peer", "call_remote", "reliable", 11)
func _rx_straw_del(ids: PackedInt64Array) -> void:
	var s := _straws()
	if s != null:
		s.on_del(ids)


@rpc("any_peer", "call_remote", "reliable", 11)
func _rx_straw_census(ids: PackedInt64Array) -> void:
	var s := _straws()
	if s != null:
		s.on_census(multiplayer.get_remote_sender_id(), ids)


# ---------------------------------------------------------------- settings

var _custom_name := ""  # a name typed in the panel; empty = use the Steam name


func _load_settings() -> void:
	var c := ConfigFile.new()
	if c.load(SETTINGS_PATH) == OK:
		_custom_name = str(c.get_value("mp", "custom_name", ""))
		last_ip = str(c.get_value("mp", "ip", last_ip))
		last_port = int(c.get_value("mp", "port", DEFAULT_PORT))
	my_name = _custom_name if _custom_name != "" else default_name()


func _save_settings() -> void:
	var c := ConfigFile.new()
	c.set_value("mp", "custom_name", _custom_name)
	c.set_value("mp", "ip", last_ip)
	c.set_value("mp", "port", last_port)
	c.save(SETTINGS_PATH)


# Called by the panel when the player edits the name field.
func set_player_name(n: String) -> void:
	n = n.strip_edges().substr(0, 24)
	if n == "":
		return
	my_name = n
	_custom_name = "" if n == default_name() else n
	_save_settings()


func default_name() -> String:
	var steam := steam_name()
	if steam != "":
		return steam.substr(0, 24)
	var user := OS.get_environment("USERNAME")
	return user.substr(0, 24) if user != "" else t("default_name")


var _steam_name_cache: Variant = null


# The demo has no Steam API, so read the persona name Steam keeps on disk
# (config/loginusers.vdf): the MostRecent account, else the newest login.
func steam_name() -> String:
	if _steam_name_cache != null:
		return _steam_name_cache
	_steam_name_cache = ""
	var roots: Array[String] = []
	var out: Array = []
	if OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"], out) == 0 and not out.is_empty():
		var rx := RegEx.create_from_string("SteamPath\\s+REG_SZ\\s+(.+)")
		var hit := rx.search(str(out[0]))
		if hit != null:
			roots.append(hit.get_string(1).strip_edges())
	var pf := OS.get_environment("ProgramFiles(x86)")
	if pf != "":
		roots.append(pf.replace("\\", "/") + "/Steam")
	for root in roots:
		var f := FileAccess.open(root + "/config/loginusers.vdf", FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		var best := ""
		var best_stamp := -1
		var block_rx := RegEx.create_from_string("\"\\d+\"\\s*\\{([^}]*)\\}")
		var name_rx := RegEx.create_from_string("\"PersonaName\"\\s*\"([^\"]*)\"")
		var stamp_rx := RegEx.create_from_string("\"Timestamp\"\\s*\"(\\d+)\"")
		var recent_rx := RegEx.create_from_string("\"MostRecent\"\\s*\"1\"")
		for b in block_rx.search_all(text):
			var body := b.get_string(1)
			var n := name_rx.search(body)
			if n == null:
				continue
			var stamp := 0
			var s := stamp_rx.search(body)
			if s != null:
				stamp = int(s.get_string(1))
			if recent_rx.search(body) != null:
				stamp = 1 << 62
			if stamp > best_stamp:
				best_stamp = stamp
				best = n.get_string(1)
		if best != "":
			_steam_name_cache = best
			break
	return _steam_name_cache
