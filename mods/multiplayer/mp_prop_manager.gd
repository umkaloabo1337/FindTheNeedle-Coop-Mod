extends "res://scripts/items/prop_manager.gd"
const __MPCost = preload("res://mods/multiplayer/mp_cost.gd")

var mp_props: Node

func _mp_timed_process(delta: float) -> void:
	if not is_instance_valid(mp_props) or not mp_props.mp.active():
		super._process(delta)
		return
	var local_settings := {}
	var policy: Dictionary = mp_props.cleanup_policy()
	for key in policy:
		local_settings[key] = Cfg.get(key)
		Cfg.set(key, policy[key])
	super._process(delta)
	for key in local_settings:
		Cfg.set(key, local_settings[key])

func _tuft_pass() -> void:
	if Cfg.auto_clean:
		super._tuft_pass()

func _drain_pass() -> void:
	if Cfg.auto_clean:
		super._drain_pass()


func to_array() -> Array:
	if not is_instance_valid(mp_props) or not mp_props.mp.active():
		return super.to_array()
	var original_items := items
	items = items.filter(func(item): return not is_instance_valid(item) or not mp_props.is_personal_tool_body(item))
	var data := super.to_array()
	items = original_items
	return data


func is_spoken_for(item: Carryable) -> bool:
	if is_instance_valid(mp_props) and item.has_meta("mp_id"):
		var id := int(item.get_meta("mp_id"))
		if bool(mp_props._held.get(id, false)) or mp_props._claim_pending.has(id):
			return true
	if is_instance_valid(mp_props) and is_instance_valid(mp_props.mp) and mp_props.mp.active() and preload("res://mods/multiplayer/mp_lift_cargo.gd").is_transported(item):
		return true
	return super.is_spoken_for(item)


func sweep_floor() -> int:
	if not preload("res://mods/multiplayer/mp_sweep.gd").native_allowed(self):
		return 0
	if is_instance_valid(mp_props) and is_instance_valid(mp_props.mp) and mp_props.mp.active():
		_unqueue_floor_litter()
	return super.sweep_floor()


# Something lying beside a belt it wants to join waits in that belt's queue,
# and the game's sweep leaves anything that waits. Beside a full belt it waits
# for good: in the host's yard 14 of 33 bricks on the hall floor stayed after
# every tidy-up (3 in the same yard alone). The tidy-up is asked to clear the
# floor, so a wait in a queue no longer keeps a thing there; riding a belt,
# being carried, held or claimed by an arm still does.
const _QUEUE_METAS := ["belt_joins_queue_until", "hold_until"]
func _unqueue_floor_litter() -> void:
	for item in items:
		if not is_instance_valid(item) or not (item is RigidBody3D) or (item as RigidBody3D).freeze:
			continue
		if not item.has_meta("belt_joins_queue_until") or item.has_meta("belt_rider") or item.has_meta(META_CLAIM):
			continue
		if item.has_method("is_held") and item.is_held():
			continue
		if not is_floor_litter(item):
			continue
		for m in _QUEUE_METAS:
			item.remove_meta(m)

var _material_batches: Array[Dictionary]=[]
var _material_tree: SceneTree
var _material_release_pending:=false

func remove(item: Carryable) -> void:
	if is_instance_valid(item) and (item is SandShovel or item is ToolProp) and items.has(item):
		var materials: Array[Material]=[]
		for mesh: MeshInstance3D in item._meshes:
			if not is_instance_valid(mesh):continue
			_keep_material(mesh.material_override,materials)
			_keep_material(mesh.material_overlay,materials)
			if mesh.mesh==null:continue
			for index in mesh.mesh.get_surface_count():
				_keep_material(mesh.get_surface_override_material(index),materials)
				_keep_material(mesh.mesh.surface_get_material(index),materials)
		if not materials.is_empty() and is_inside_tree():
			_material_batches.append({"frame":Engine.get_process_frames()+2,"materials":materials})
			_material_tree=get_tree()
			if not _material_tree.process_frame.is_connected(_material_frame):_material_tree.process_frame.connect(_material_frame)
	super.remove(item)

func _keep_material(material: Material,materials: Array[Material]) -> void:
	for index in 32:
		if material==null or materials.has(material):return
		materials.append(material)
		material=material.next_pass

func _material_frame() -> void:
	if _material_release_pending:return
	for batch: Dictionary in _material_batches:
		if int(batch.frame)<=Engine.get_process_frames():
			_material_release_pending=true
			_release_materials.call_deferred()
			return

func _release_materials() -> void:
	_material_release_pending=false
	var pending: Array[Dictionary]=[]
	for batch: Dictionary in _material_batches:
		if int(batch.frame)>Engine.get_process_frames():pending.append(batch)
	_material_batches=pending
	if _material_batches.is_empty() and is_instance_valid(_material_tree):
		if _material_tree.process_frame.is_connected(_material_frame):_material_tree.process_frame.disconnect(_material_frame)
		_material_tree=null

func _exit_tree() -> void:
	if is_instance_valid(_material_tree) and _material_tree.process_frame.is_connected(_material_frame):_material_tree.process_frame.disconnect(_material_frame)
	_material_tree=null
	_material_batches.clear()
	_material_release_pending=false


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_mp_timed_process(delta)
	__MPCost.add("prop_manager", Time.get_ticks_usec() - __t)
