# Place the held tools on the remote-player farmer by hand. Starts a throwaway
# game and puts a farmer in front of you holding the selected tool; move it
# around its hand until it looks right and save.
#
#   1-6        tool (spade, pitchfork, broom, toy shovel, detector, yard vac)
#   F10        free mouse for the panel on the right (again to look around)
#   G / R      nudge keys move / rotate
#   J L        X (right)       U O   Y (up)       I K   Z (forward)
#   + -        length
#   Shift = coarse steps, Alt = fine steps
#   mouse (free, over the 3D view): left drag moves, right drag rotates,
#   wheel changes the length
#   PgUp/PgDn  look pitch, Home = level
#   F5 camera  F6 idle/walk/run  F7 crouch  B bring it in front again
#   F8         back to automatic for this tool
#   F9         save
#
# The pose is relative to the farmer's hand: -Z where they face, +Y up, +X to
# their right, and it tilts with the look pitch. Saved to tool_poses.cfg next
# to mp_avatar.gd (the mod folder) and printed to the console. Tools with no
# entry keep the automatic fit.
#
# To use it, add a second autoload to the game's override.cfg under MPMod:
#   ToolPoser="*C:/path/to/dev/tool_poser.gd"
# and remove it again when done. Your own saves are not touched.
extends Node

const OUT_FILE := "tool_poses.cfg"
const TOOLS := {1: "Pala", 2: "Horca", 3: "Escoba", 4: "Pala de juguete",
	5: "Detector de metales", 6: "Aspiradora de hojas"}
const MOVES := [0.0, 1.3, 4.2]
const MOVE_NAMES := ["quieto", "andando", "corriendo"]
const VIEWS := ["jugador", "frente", "lado", "mano de cerca"]
# field -> [label, min, max, step]
const FIELDS := {
	"px": ["pos X", -1.0, 1.0, 0.001], "py": ["pos Y", -1.0, 1.0, 0.001],
	"pz": ["pos Z", -1.0, 1.0, 0.001], "rx": ["rot X", -180.0, 180.0, 0.1],
	"ry": ["rot Y", -180.0, 180.0, 0.1], "rz": ["rot Z", -180.0, 180.0, 0.1],
	"len": ["largo", 0.1, 2.5, 0.005],
}

var mp: Node
var _t := 0.0
var _started := false
var _spawning := false
var av: Node3D
var player: Node3D
var world: Node
var save_dir := ""
var spot := Vector3.ZERO
var yaw := 0.0

var tool := 1
var pitch := 0.0
var crouch := false
var move := 0
var view := 0
var rotating := false
var free_mouse := false
var dirty := false
var msg := ""

var cam: Camera3D
var _player_cam: Camera3D
var _axes: MeshInstance3D
var _palm: MeshInstance3D
var _drag := 0  # mouse button held over the 3D view
var _syncing := false
var _rows := {}  # field -> [slider, spinbox]
var _help: Label
var _title: Label
var _state: Label
var _tool_btns := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	mp = get_node_or_null("/root/MPMod")
	if mp == null:
		return  # standalone, someone calls attach()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = Vector2i(1600, 900)
	w.title = "Find The Needle - POSICIONADOR DE HERRAMIENTAS"
	save_dir = mp.base_dir


func _process(d: float) -> void:
	_t += d
	if mp != null:
		_game_tick()
	if av == null or not is_instance_valid(av):
		return
	av.set_target(spot, yaw, pitch, tool, 1.0 if crouch else 0.0, MOVES[move])
	if free_mouse and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_cam()
	_update_axes()
	_update_text()


# start a scratch game like avatar_calib.gd and spawn the farmer once in
func _game_tick() -> void:
	var cs := get_tree().current_scene
	if not _started and cs != null and cs.name == "MainMenu" and _t > 4.0:
		_started = true
		var sm := get_node("/root/SaveManager")
		sm.use_scratch_dir("user://tool_poser")
		sm.begin_new_game(0, true)
		get_node("/root/Loading").enter_scene(mp.GAME_SCENE)
	if mp.world_sync == null:
		av = null
		return
	if av == null and not _spawning:
		_spawn_in_game()


func _spawn_in_game() -> void:
	_spawning = true
	await get_tree().create_timer(2.0).timeout
	_spawning = false
	if mp.world_sync == null or av != null:
		return
	var p: Node3D = mp.world_sync.player
	var w: Node = mp.world_sync.world
	# open yard by the pile, same spot as avatar_calib.gd
	var open_spot := Vector3(9.6, 0.0, 12.0)
	p.global_position = w._seat(open_spot) if w.has_method("_seat") else open_spot
	if p.has_method("set_look"):
		p.set_look(0.0, 0.0)
	await get_tree().process_frame
	attach(load(mp.base_dir + "/mp_avatar.gd"), w, p, mp.base_dir)


# the core, also used by a standalone test scene with a fake player
func attach(avatar_script: Script, w: Node, p: Node3D, dir: String) -> void:
	world = w
	player = p
	save_dir = dir
	av = avatar_script.new()
	av.setup("Maniqui", Color(0.3, 0.65, 0.98))
	world.add_child(av)
	cam = Camera3D.new()
	cam.fov = 60.0
	world.add_child(cam)
	_axes = _make_axes(0.22)
	world.add_child(_axes)
	_palm = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.018
	dot.height = 0.036
	_palm.mesh = dot
	_palm.material_override = _flat(Color(1, 1, 0.2))
	world.add_child(_palm)
	bring()
	av.set_target(spot, yaw, 0.0, tool, 0.0, 0.0)
	_sync_ui()


# a couple of metres in front of the player, facing them
func bring() -> void:
	var fwd := -player.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	spot = player.global_position + fwd.normalized() * 2.0
	if world.has_method("_seat"):
		spot = world._seat(spot)
	var to := player.global_position - spot
	yaw = atan2(-to.x, -to.z)
	if av != null and av.is_inside_tree():
		av.global_position = spot
		av.rotation.y = yaw


# ---------------------------------------------------------------- pose data

# what the farmer holds now: the saved pose, or the automatic fit read back
# off the holder so editing starts from what you see
func current_pose() -> Dictionary:
	var p: Dictionary = av.tool_pose(tool)
	if not p.is_empty():
		return p.duplicate()
	var lengths: Dictionary = av.get_script().get_script_constant_map().get("TOOL_LENGTHS", {})
	var out := {"pos": Vector3.ZERO, "rot": Vector3.ZERO, "length": float(lengths.get(tool, 1.2))}
	var holder: Node3D = av.get("_tool_node")
	if holder != null and is_instance_valid(holder) and not holder.is_queued_for_deletion():
		out.pos = holder.position
		out.rot = holder.rotation_degrees
	return out


func set_pose(p: Dictionary) -> void:
	p.pos = p.pos.snappedf(0.001)
	p.rot = Vector3(_wrap(p.rot.x), _wrap(p.rot.y), _wrap(p.rot.z)).snappedf(0.1)
	p.length = clampf(snappedf(p.length, 0.005), 0.1, 2.5)
	av.set_tool_pose(tool, p)
	dirty = true
	_sync_ui()


func has_pose() -> bool:
	return not av.tool_pose(tool).is_empty()


func edit(field: String, v: float) -> void:
	var p := current_pose()
	match field:
		"px": p.pos.x = v
		"py": p.pos.y = v
		"pz": p.pos.z = v
		"rx": p.rot.x = v
		"ry": p.rot.y = v
		"rz": p.rot.z = v
		"len": p.length = v
	set_pose(p)


func nudge(axis: int, dir: float, coarse: bool, fine: bool) -> void:
	var p := current_pose()
	var k := 5.0 if coarse else (0.2 if fine else 1.0)
	if rotating:
		p.rot[axis] += dir * 2.0 * k
	else:
		p.pos[axis] += dir * 0.01 * k
	set_pose(p)


func stretch(dir: float, coarse: bool, fine: bool) -> void:
	var p := current_pose()
	p.length += dir * (0.05 if coarse else (0.002 if fine else 0.01))
	set_pose(p)


func select_tool(id: int) -> void:
	if not TOOLS.has(id):
		return
	tool = id
	msg = ""
	av.set_target(spot, yaw, pitch, tool, 1.0 if crouch else 0.0, MOVES[move])
	_sync_ui()


func reset_tool() -> void:
	av.set_tool_pose(tool, {})
	dirty = true
	msg = "%s vuelve a automatico (F9 para guardarlo)" % TOOLS[tool]
	_sync_ui()


func save() -> void:
	var cfg := ConfigFile.new()
	var names: Array = av.get_script().get_script_constant_map().get("TOOL_NAMES", [])
	var lines := []
	for id in TOOLS:
		var p: Dictionary = av.tool_pose(id)
		if p.is_empty():
			continue
		var sec := "tool_%d" % id
		cfg.set_value(sec, "name", names[id] if id < names.size() else TOOLS[id])
		cfg.set_value(sec, "pos", p.pos)
		cfg.set_value(sec, "rot", p.rot)
		cfg.set_value(sec, "length", p.length)
		lines.append("[%s] pos=%s rot=%s length=%.3f" % [sec, p.pos, p.rot, p.length])
	var path := ProjectSettings.globalize_path(save_dir.path_join(OUT_FILE))
	var err := cfg.save(path)
	if err != OK:
		# mod folder not writable, keep it somewhere at least
		path = ProjectSettings.globalize_path("user://" + OUT_FILE)
		err = cfg.save(path)
	if err == OK:
		dirty = false
		msg = ">> GUARDADO en %s (%d herramientas)" % [path, lines.size()]
	else:
		msg = ">> ERROR %d al guardar" % err
	print("[ToolPoser] ", path, " error=", err)
	for l in lines:
		print("[ToolPoser] ", l)


func _wrap(a: float) -> float:
	return wrapf(a, -180.0, 180.0)


func _angle_gap(a: Vector3, b: Vector3) -> float:
	return absf(_wrap(a.x - b.x)) + absf(_wrap(a.y - b.y)) + absf(_wrap(a.z - b.z))


# ---------------------------------------------------------------- input

func _input(e: InputEvent) -> void:
	if av == null or not is_instance_valid(av):
		return
	var k := e as InputEventKey
	if k == null or not k.pressed:
		return
	# typing a number into a box
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit and k.keycode != KEY_F9 and k.keycode != KEY_F10:
		return
	var coarse := k.shift_pressed
	var fine := k.alt_pressed
	var used := true
	match k.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			select_tool(k.keycode - KEY_0)
		KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6:
			select_tool(k.keycode - KEY_KP_0)
		KEY_F10:
			set_free_mouse(not free_mouse)
		KEY_G:
			rotating = false
		KEY_R:
			rotating = true
		KEY_J: nudge(0, -1.0, coarse, fine)
		KEY_L: nudge(0, 1.0, coarse, fine)
		KEY_U: nudge(1, 1.0, coarse, fine)
		KEY_O: nudge(1, -1.0, coarse, fine)
		KEY_I: nudge(2, -1.0, coarse, fine)
		KEY_K: nudge(2, 1.0, coarse, fine)
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			stretch(1.0, coarse, fine)
		KEY_MINUS, KEY_KP_SUBTRACT:
			stretch(-1.0, coarse, fine)
		KEY_PAGEUP:
			pitch = clampf(pitch + 0.1, -1.4, 1.4)
		KEY_PAGEDOWN:
			pitch = clampf(pitch - 0.1, -1.4, 1.4)
		KEY_HOME:
			pitch = 0.0
		KEY_F5:
			view = (view + 1) % VIEWS.size()
		KEY_F6:
			move = (move + 1) % MOVES.size()
		KEY_F7:
			crouch = not crouch
		KEY_B:
			bring()
		KEY_F8:
			reset_tool()
		KEY_F9:
			save()
		_:
			used = false
	if used:
		get_viewport().set_input_as_handled()


# left drag moves in the camera plane, right drag turns around the camera
# axes, wheel changes the length. only over the 3D view, the panel eats its own
func _unhandled_input(e: InputEvent) -> void:
	if not free_mouse or av == null or not is_instance_valid(av):
		return
	var b := e as InputEventMouseButton
	if b != null:
		if b.button_index == MOUSE_BUTTON_WHEEL_UP and b.pressed:
			stretch(1.0, b.shift_pressed, b.alt_pressed)
		elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN and b.pressed:
			stretch(-1.0, b.shift_pressed, b.alt_pressed)
		elif b.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_drag = b.button_index if b.pressed else 0
		return
	var m := e as InputEventMouseMotion
	if m == null or _drag == 0:
		return
	drag(m.relative, _drag == MOUSE_BUTTON_RIGHT, m.shift_pressed, m.alt_pressed)


func drag(rel: Vector2, turn: bool, coarse: bool, fine: bool) -> void:
	var c := get_viewport().get_camera_3d()
	var hand: Node3D = av.get("_hand")
	if c == null or hand == null:
		return
	var p := current_pose()
	var k := 3.0 if coarse else (0.25 if fine else 1.0)
	var to_hand := hand.global_basis.orthonormalized().inverse()
	var cb := c.global_basis.orthonormalized()
	if turn:
		var a := deg_to_rad(0.4) * k
		var r := Basis(cb.y, rel.x * a) * Basis(cb.x, rel.y * a)
		var local := to_hand * r * hand.global_basis.orthonormalized() * Basis.from_euler(p.rot * PI / 180.0)
		# same turn can be written two ways, keep the one nearer the old numbers
		var e := local.get_euler() * 180.0 / PI
		var alt := Vector3(180.0 - e.x, e.y + 180.0, e.z + 180.0)
		p.rot = e if _angle_gap(e, p.rot) <= _angle_gap(alt, p.rot) else alt
	else:
		# metres per pixel at the tool's distance
		var dist := c.global_position.distance_to(hand.global_transform * p.pos)
		var per_px := 2.0 * dist * tan(deg_to_rad(c.fov) * 0.5) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
		var shift := (cb.x * rel.x - cb.y * rel.y) * per_px * k
		p.pos += to_hand * shift
	set_pose(p)


func set_free_mouse(on: bool) -> void:
	free_mouse = on
	_drag = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if on else Input.MOUSE_MODE_CAPTURED
	# keep the player from looking around while we click on things
	if player != null and is_instance_valid(player) and mp != null:
		player.set_process_input(not on)
		player.set_process_unhandled_input(not on)


# ---------------------------------------------------------------- view

func _update_cam() -> void:
	if cam == null:
		return
	if view == 0:
		if cam.current:
			cam.clear_current(false)
			if _player_cam != null and is_instance_valid(_player_cam):
				_player_cam.make_current()
		return
	if not cam.current:
		var cur := get_viewport().get_camera_3d()
		if cur != cam:
			_player_cam = cur
		cam.make_current()
	var hand: Node3D = av.get("_hand")
	var focus := hand.global_position if hand != null else spot + Vector3.UP
	var fwd := -av.global_basis.z
	var right := av.global_basis.x
	var from: Vector3
	match view:
		1:
			from = spot + fwd * 2.4 + Vector3.UP * 1.3
			focus = spot + Vector3.UP * 1.0
		2:
			from = spot + right * 2.2 + Vector3.UP * 1.2
			focus = spot + Vector3.UP * 1.0
		_:
			from = focus + (fwd * 0.8 + right * 0.6 + Vector3.UP * 0.25)
	cam.look_at_from_position(from, focus)


func _update_axes() -> void:
	var holder: Node3D = av.get("_tool_node")
	var hand: Node3D = av.get("_hand")
	_axes.visible = holder != null and is_instance_valid(holder) and not holder.is_queued_for_deletion()
	if _axes.visible:
		var xf := holder.global_transform
		_axes.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
	_palm.visible = hand != null
	if hand != null:
		_palm.global_position = hand.global_position


func _make_axes(size: float) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in 3:
		var dir := Vector3.ZERO
		dir[a] = size
		var col := Color(0, 0, 0)
		col[a] = 1.0
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_set_color(col)
		im.surface_add_vertex(dir)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := _flat(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _flat(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = c
	mat.render_priority = 10
	return mat


# ---------------------------------------------------------------- ui

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)

	_help = _text(20)
	_help.position = Vector2(20, 230)
	layer.add_child(_help)

	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -470
	panel.offset_right = -16
	panel.offset_top = 16
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_title = _text(24)
	box.add_child(_title)
	var tools := HBoxContainer.new()
	box.add_child(tools)
	for id in TOOLS:
		var btn := Button.new()
		btn.text = str(id)
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.tooltip_text = TOOLS[id]
		btn.custom_minimum_size = Vector2(40, 0)
		btn.pressed.connect(select_tool.bind(id))
		tools.add_child(btn)
		_tool_btns[id] = btn
	_state = _text(16)
	box.add_child(_state)

	var grid := GridContainer.new()
	grid.columns = 3
	box.add_child(grid)
	for f in FIELDS:
		var spec: Array = FIELDS[f]
		var l := Label.new()
		l.text = spec[0]
		grid.add_child(l)
		var sl := HSlider.new()
		sl.min_value = spec[1]
		sl.max_value = spec[2]
		sl.step = spec[3]
		sl.custom_minimum_size = Vector2(220, 0)
		sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sl.focus_mode = Control.FOCUS_NONE
		sl.value_changed.connect(_on_field.bind(f))
		grid.add_child(sl)
		var sp := SpinBox.new()
		sp.min_value = spec[1]
		sp.max_value = spec[2]
		sp.step = spec[3]
		sp.allow_greater = true
		sp.allow_lesser = true
		sp.custom_minimum_size = Vector2(120, 0)
		sp.value_changed.connect(_on_field.bind(f))
		grid.add_child(sp)
		_rows[f] = [sl, sp]

	var btns := HBoxContainer.new()
	box.add_child(btns)
	var auto := Button.new()
	auto.text = "Automatico (F8)"
	auto.focus_mode = Control.FOCUS_NONE
	auto.pressed.connect(reset_tool)
	btns.add_child(auto)
	var sv := Button.new()
	sv.text = "Guardar (F9)"
	sv.focus_mode = Control.FOCUS_NONE
	sv.pressed.connect(save)
	btns.add_child(sv)


func _text(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 8)
	return l


func _on_field(v: float, field: String) -> void:
	if _syncing or av == null:
		return
	edit(field, v)


func _sync_ui() -> void:
	if av == null:
		return
	var p := current_pose()
	var vals := {"px": p.pos.x, "py": p.pos.y, "pz": p.pos.z,
		"rx": p.rot.x, "ry": p.rot.y, "rz": p.rot.z, "len": p.length}
	_syncing = true
	for f in _rows:
		_rows[f][0].set_value_no_signal(vals[f])
		_rows[f][1].set_value_no_signal(vals[f])
	_syncing = false
	for id in _tool_btns:
		_tool_btns[id].set_pressed_no_signal(id == tool)
	_update_text()


func _update_text() -> void:
	if av == null:
		return
	var has_model: bool = av.get("_tool_node") != null
	_title.text = "%d  %s" % [tool, TOOLS[tool]]
	_state.text = "%s%s%s" % [
		"pose a mano" if has_pose() else "automatico (sin pose guardada)",
		"" if has_model else "\n(no se encuentra el modelo)",
		"\n* cambios sin guardar" if dirty else ""]
	_help.text = "\n".join([
		"POSICIONADOR DE HERRAMIENTAS",
		"",
		"1-6: herramienta      F10: raton %s" % ("libre (F10 para mirar)" if free_mouse else "capturado (F10 para el panel)"),
		"teclas en modo %s   (G: mover, R: girar)" % ("GIRAR" if rotating else "MOVER"),
		"J L: X (derecha)   U O: Y (arriba)   I K: Z (adelante)",
		"+ -: largo    Shift: pasos grandes    Alt: pasos finos",
		"raton libre: arrastrar izq. mueve, der. gira, rueda cambia el largo",
		"",
		"RePag/AvPag: mirar arriba/abajo (%.1f)   Inicio: recto" % pitch,
		"F5: camara (%s)   F6: %s   F7: %s" % [VIEWS[view], MOVE_NAMES[move], "agachado" if crouch else "de pie"],
		"B: traerlo delante   F8: automatico   F9: guardar",
		"",
		msg,
	])


func _notification(what: int) -> void:
	if mp == null:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
