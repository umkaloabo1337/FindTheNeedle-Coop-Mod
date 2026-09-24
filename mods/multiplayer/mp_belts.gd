extends Node

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
const MAX_RAW := 8 << 20

var mp: Node
var world: Node
var _t := 0.0


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node


# Hand the belt ends back, in case the world outlives the session.
func shutdown() -> void:
	for item in BeltPath._live:
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		if not item._records_held:
			continue
		item._records_held = false
		item._eats = Callable()
		item.run.hold_for = Callable()
		item._sync_run_links()


func _process(delta: float) -> void:
	if mp == null or not mp.is_host or not mp.active():
		return
	if multiplayer.multiplayer_peer == null:
		return
	if mp.players.size() < 2:
		return
	_t += delta
	if _t < TICK:
		return
	_t = 0.0
	send_all()


func send_all(pid: int = 0) -> void:
	var entries: Array = BeltPath.belts_to_array()
	# the transform is only there for the "could not board it" fallback, which
	# clients do not use: dropping it takes most of the packet away
	for e in entries:
		var rows: Array = e.get("records", [])
		for row in rows:
			if row is Dictionary:
				row.erase("xform")
				if row.get("state") is Dictionary and (row["state"] as Dictionary).is_empty():
					row.erase("state")
	var raw := var_to_bytes(entries)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if pid > 0:
		mp._rx_belts.rpc_id(pid, packed, raw.size())
	else:
		mp._rx_belts.rpc(packed, raw.size())


func on_belts(packed: PackedByteArray, raw_size: int) -> void:
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	var entries: Variant = bytes_to_var(raw)
	if not (entries is Array):
		return
	for item in BeltPath._live:
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		item.run.clear()
		# A belt that reaches its end turns the ride into a real item. The host
		# does that and sends us the item, so hold our own end shut: the same
		# switch a machine sitting at the end of a belt uses.
		if not item._records_held:
			item.hold_records(Callable())
	# no PropManager: a ride we cannot place is dropped instead of becoming a
	# loose item that only this player would have
	var got: Dictionary = BeltPath.belts_from_array(entries, null)
	if OS.get_environment("MP_DEBUG_PROPS") != "":
		var rows := 0
		for e in entries:
			rows += (e.get("records", []) as Array).size()
		print("[MPBELTS] %d paths, %d rows -> %s" % [entries.size(), rows, got])
