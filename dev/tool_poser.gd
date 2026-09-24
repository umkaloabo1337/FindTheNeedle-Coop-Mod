# Place the held tools on the remote-player farmer by hand. When the game gets
# to the main menu this swaps in an empty stage with the farmer holding a tool,
# a move / rotate gizmo on the tool and a panel on the right.
#
#   1-6              tool (pala, horca, escoba, palita, detector, aspiradora)
#   7                the wheelbarrow, pushed with both hands
#   G                on 7: move the barrow / the left grip / the right grip
#   W / E            gizmo: move / rotate. left drag an arrow or a ring
#   Ctrl + drag      snap to 1 cm / 5 degrees, Esc cancels the drag
#   right drag       orbit        middle drag   pan        wheel   zoom
#   right + WASD/QE  fly (Shift faster)
#   F                frame the tool         R   reset the view
#   C                edit the standing pose / the optional crouch pose
#   F9               save (same as the Guardar button)
#
# The pose is in the farmer's hand space: X to their right, Y up, Z back (-Z
# is where they face), and it tilts with the look pitch. Saved to
# tool_poses.cfg next to mp_avatar.gd. Tools with no entry keep the automatic
# fit, and tools with no crouch pose use the standing one when crouched. dev/tool_poser.bat starts the game with this as a second autoload
# (ToolPoser) and puts override.cfg back when you close it.
#
# The wheelbarrow (7) is placed from the farmer's feet instead, same axes but
# no pitch, and the hands reach for its two handle grips. The grips are found
# on the model; the white dots move them if that's off (click one, or G),
# in the barrow's own space. Saved as [wheelbarrow].
extends Node

const OUT_FILE := "tool_poses.cfg"
const TOOLS := {1: "Pala", 2: "Horca", 3: "Escoba", 4: "Palita", 5: "Detector", 6: "Aspiradora",
	7: "Carretilla"}
const BARROW := 7
const GRIPS := ["Carretilla", "Agarre izq.", "Agarre der."]
const MOVES := [0.0, 1.3, 4.2]
const MOVE_NAMES := ["Quieto", "Andar", "Correr"]
# field -> [label, min, max, step]
const FIELDS := {
	"px": ["pos X", -1.0, 1.0, 0.001], "py": ["pos Y", -1.0, 1.0, 0.001],
	"pz": ["pos Z", -1.0, 1.0, 0.001], "rx": ["rot X", -180.0, 180.0, 0.1],
	"ry": ["rot Y", -180.0, 180.0, 0.1], "rz": ["rot Z", -180.0, 180.0, 0.1],
	"len": ["largo", 0.1, 2.5, 0.005],
}
const AXIS_COLORS := [Color(0.96, 0.2, 0.32), Color(0.53, 0.84, 0.01), Color(0.16, 0.55, 0.96)]
const ARROW_PX := 95.0  # gizmo arrow length on screen
const RING := 0.8  # ring radius, in arrow lengths
const PICK_PX := 10.0
const HOME_TARGET := Vector3(0.0, 1.1, 0.0)

var mp: Node
var save_dir := ""
var _menu_t := 0.0
var _opened := false
var av: Node3D
var cam: Camera3D

var tool := 1
var pitch := 0.0
var crouch := false
var edit_crouch := false  # editing the optional crouch pose instead of the standing one
var move := 0
var turntable := false
var rotating := false
var dirty := false
var msg := ""
var _yaw := 0.0
var _logged := -1
var _pending := {}  # pose from a drag, applied once per frame
var grip := -1  # on the barrow: -1 moves the barrow, 0 / 1 the left / right grip
var _barrow: Node3D

# camera
var _target := HOME_TARGET
var _cam_yaw := 2.5
var _cam_pitch := -0.2
var _dist := 2.8
var _orbit := false
var _pan := false

# gizmo
var _gizmo: Node3D
var _arrows: Node3D
var _rings: Node3D
var _palm: MeshInstance3D
var _dots := []  # the two grips
var _mats := []
var _hover := -1
var _drag := -1
var _drag_from := Vector2.ZERO
var _drag_dir := Vector2.RIGHT
var _drag_px := 1.0  # pixels per metre, or per radian when rotating
var _drag_pose := {}

# ui
var _view: Control
var _panel: Control
var _rows := {}  # field -> [slider, spinbox]
var _tool_btns := {}
var _mode_btns := []
var _move_btns := []
var _pitch_sl: HSlider
var _pitch_lbl: Label
var _crouch_cb: CheckBox
var _stance_btns := []
var _stance_row: Control
var _grip_row: Control
var _grip_btns := []
var _drop_crouch: Button
var _turn_cb: CheckBox
var _state: Label
var _unsaved: Label
var _msg: Label
var _syncing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# after the farmer, so the gizmo sits on this frame's hand
	process_priority = 100
	mp = get_node_or_null("/root/MPMod")
	if mp == null:
		push_warning("[ToolPoser] no MPMod autoload, nothing to do")
		return
	save_dir = mp.base_dir
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
	print("[ToolPoser] waiting for the main menu")


func _process(d: float) -> void:
	if mp == null:
		return
	if not _opened:
		var cs := get_tree().current_scene
		if cs != null and cs.name == "MainMenu":
			_menu_t += d
			if _menu_t > 1.0:
				open_stage()
		return
	if av == null or not is_instance_valid(av) or not av.is_node_ready():
		return
	# the game likes to grab the mouse, we never want that here
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if turntable:
		_yaw = wrapf(_yaw + d * 0.6, -PI, PI)
	av.set_target(Vector3.ZERO, _yaw, pitch, _av_tool(), 1.0 if crouch else 0.0, MOVES[move])
	if _logged != tool:
		_log_tool()
		_sync_ui()
	if not _pending.is_empty():
		set_pose(_pending)
		_pending = {}
	_fly(d)
	_update_cam()
	_update_gizmo()


# ---------------------------------------------------------------- stage

func open_stage() -> void:
	_opened = true
	get_tree().paused = false
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = Vector2i(1600, 900)
	w.title = "Find The Needle - posicionador de herramientas"

	var stage := Node3D.new()
	stage.name = "ToolPoserStage"
	stage.process_mode = Node.PROCESS_MODE_ALWAYS
	_build_world(stage)
	cam = Camera3D.new()
	cam.fov = 50.0
	cam.current = true
	stage.add_child(cam)
	var script := load(save_dir + "/mp_avatar.gd") as Script
	if script == null:
		push_error("[ToolPoser] could not load %s/mp_avatar.gd" % save_dir)
		return
	av = script.new()
	av.setup("Maniquí", Color(0.3, 0.65, 0.98))
	# set_target waits for _ready (see _process), before it there is no hand
	# to hang the tool on
	stage.add_child(av)
	_barrow = av.barrow_model()
	if _barrow != null:
		stage.add_child(_barrow)
	_show_barrow()
	_build_gizmo(stage)
	var err := get_tree().change_scene_to_node(stage)
	_build_ui()
	reset_view()
	_sync_ui()
	print("[ToolPoser] stage open (error %d), poses save to %s" % [
		err, ProjectSettings.globalize_path(save_dir.path_join(OUT_FILE))])


func _build_world(stage: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	stage.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 40.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 25.0
	stage.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.46, 0.48, 0.43)
	gm.roughness = 1.0
	ground.material_override = gm
	stage.add_child(ground)

	# 1 m grid, with the X (red) and Z (blue) lines through the origin
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-20, 21):
		var cx := Color(0.9, 0.25, 0.3, 0.9) if i == 0 else Color(0, 0, 0, 0.25)
		var cz := Color(0.25, 0.5, 0.95, 0.9) if i == 0 else Color(0, 0, 0, 0.25)
		for v in [Vector3(-20, 0, i), Vector3(20, 0, i)]:
			im.surface_set_color(cx)
			im.surface_add_vertex(v)
		for v in [Vector3(i, 0, -20), Vector3(i, 0, 20)]:
			im.surface_set_color(cz)
			im.surface_add_vertex(v)
	im.surface_end()
	var grid := MeshInstance3D.new()
	grid.mesh = im
	grid.position.y = 0.003
	grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid.material_override = lm
	stage.add_child(grid)


func _build_gizmo(stage: Node3D) -> void:
	_gizmo = Node3D.new()
	stage.add_child(_gizmo)
	_arrows = Node3D.new()
	_gizmo.add_child(_arrows)
	_rings = Node3D.new()
	_gizmo.add_child(_rings)
	for a in 3:
		var mat := _flat(AXIS_COLORS[a])
		_mats.append(mat)
		# built along +Y, then turned onto the axis
		var arm := Node3D.new()
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.022
		shaft.bottom_radius = 0.022
		shaft.height = 0.7
		arm.add_child(_part(shaft, mat, Vector3(0, 0.45, 0)))
		var tip := CylinderMesh.new()
		tip.top_radius = 0.0
		tip.bottom_radius = 0.075
		tip.height = 0.22
		arm.add_child(_part(tip, mat, Vector3(0, 0.89, 0)))
		_arrows.add_child(arm)
		# torus lies flat around +Y
		var torus := TorusMesh.new()
		torus.inner_radius = RING - 0.025
		torus.outer_radius = RING + 0.025
		torus.rings = 64
		torus.ring_segments = 8
		var ring := _part(torus, mat, Vector3.ZERO)
		_rings.add_child(ring)
		match a:
			0:
				arm.rotation.z = -PI / 2.0
				ring.rotation.z = PI / 2.0
			2:
				arm.rotation.x = PI / 2.0
				ring.rotation.x = PI / 2.0
	var dot := SphereMesh.new()
	dot.radius = 0.05
	dot.height = 0.1
	_gizmo.add_child(_part(dot, _flat(Color(1, 1, 1, 0.9)), Vector3.ZERO))
	# where the hand is
	var palm := SphereMesh.new()
	palm.radius = 0.5
	palm.height = 1.0
	_palm = _part(palm, _flat(Color(1, 0.9, 0.2, 0.9)), Vector3.ZERO)
	stage.add_child(_palm)
	# the barrow's handle grips, clicked to move them
	for i in 2:
		var dot_mesh := SphereMesh.new()
		dot_mesh.radius = 0.5
		dot_mesh.height = 1.0
		var d := _part(dot_mesh, _flat(Color.WHITE), Vector3.ZERO)
		stage.add_child(d)
		_dots.append(d)


func _part(m: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# unshaded and drawn over everything
func _flat(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = c
	mat.render_priority = 100
	return mat


# ---------------------------------------------------------------- pose data

func _holder() -> Node3D:
	var h: Variant = av.get("_tool_node") if av != null else null
	if h == null or not is_instance_valid(h):
		return null
	var n := h as Node3D
	if n == null or n.is_queued_for_deletion() or not n.is_inside_tree():
		return null
	return n


func _const(name: String) -> Variant:
	return av.get_script().get_script_constant_map().get(name)


# the pose being edited: standing, or crouched (which starts as a copy of
# the standing one until it gets its own)
func current_pose() -> Dictionary:
	if tool == BARROW:
		return _barrow_edit()
	var st := _stand_pose()
	if not edit_crouch:
		return st
	var saved: Dictionary = av.tool_pose(tool)
	if saved.has("crouch"):
		return saved.crouch.duplicate()
	return {"pos": st.pos, "rot": st.rot, "length": st.length}


# the saved standing pose, or the automatic fit read back off the holder so
# editing starts from what you see
func _stand_pose() -> Dictionary:
	var p: Dictionary = av.tool_pose(tool)
	if not p.is_empty():
		return {"pos": p.pos, "rot": p.rot, "length": p.length}
	var lengths: Dictionary = _const("TOOL_LENGTHS")
	var out := {"pos": Vector3.ZERO, "rot": Vector3.ZERO, "length": float(lengths.get(tool, 1.2))}
	var holder := _holder()
	if holder != null:
		out.pos = holder.position
		out.rot = holder.rotation_degrees
	return out


func set_pose(p: Dictionary) -> void:
	p.pos = p.pos.snappedf(0.001)
	p.rot = Vector3(_wrap(p.rot.x), _wrap(p.rot.y), _wrap(p.rot.z)).snappedf(0.1)
	p.length = clampf(snappedf(p.length, 0.005), 0.1, 2.5)
	if tool == BARROW:
		_set_barrow(p)
		return
	var saved: Dictionary = av.tool_pose(tool)
	var full: Dictionary
	if edit_crouch:
		full = _stand_pose()
		full.crouch = {"pos": p.pos, "rot": p.rot, "length": p.length}
	else:
		full = {"pos": p.pos, "rot": p.rot, "length": p.length}
		if saved.has("crouch"):
			full.crouch = saved.crouch
	av.set_tool_pose(tool, full)
	dirty = true
	_sync_ui()


func has_crouch_pose() -> bool:
	return av.tool_pose(tool).has("crouch")


# ---------------------------------------------------------------- wheelbarrow

# the tool the farmer holds: none on the barrow, both hands are on it
func _av_tool() -> int:
	return 0 if tool == BARROW else tool


func _show_barrow() -> void:
	if _barrow == null:
		return
	_barrow.visible = tool == BARROW
	av.push_item(_barrow if tool == BARROW else null)


# the barrow's pose, or the grip being moved (in the barrow's own space)
func _barrow_edit() -> Dictionary:
	var bp: Dictionary = av.barrow_pose()
	if grip >= 0:
		return {"pos": bp.grip_l if grip == 0 else bp.grip_r, "rot": Vector3.ZERO, "length": 1.0}
	return {"pos": bp.pos, "rot": bp.rot, "length": 1.0}


# only what was touched gets saved: the grips stay automatic until moved
func _set_barrow(p: Dictionary) -> void:
	var bp: Dictionary = av.barrow_pose(false)
	if grip < 0:
		bp.pos = p.pos
		bp.rot = p.rot
	else:
		var full: Dictionary = av.barrow_pose()
		bp.grip_l = full.grip_l
		bp.grip_r = full.grip_r
		bp["grip_l" if grip == 0 else "grip_r"] = p.pos
	av.set_barrow_pose(bp)
	dirty = true
	_sync_ui()


func has_grips() -> bool:
	return av.barrow_pose(false).has("grip_l")


func select_grip(i: int) -> void:
	_end_drag()
	grip = i
	msg = ""
	_sync_ui()


# grips don't turn, they're just points
func _turning() -> bool:
	return rotating and not (tool == BARROW and grip >= 0)


func _grip_world(i: int) -> Vector3:
	var bp: Dictionary = av.barrow_pose()
	return _barrow.global_transform * (bp.grip_l if i == 0 else bp.grip_r)


# edit the standing pose or the crouch one. the crouch one shows the farmer
# crouched so you see what you're doing
func set_stance(crouched: bool) -> void:
	_end_drag()
	# the barrow has no crouch pose, C just crouches the farmer
	edit_crouch = crouched and tool != BARROW
	crouch = crouched
	msg = ""
	_sync_ui()


func drop_crouch() -> void:
	_end_drag()
	var saved: Dictionary = av.tool_pose(tool)
	if not saved.has("crouch"):
		return
	av.set_tool_pose(tool, {"pos": saved.pos, "rot": saved.rot, "length": saved.length})
	dirty = true
	msg = "%s agachado usa la pose de pie" % TOOLS[tool]
	_sync_ui()


func has_pose() -> bool:
	if tool == BARROW:
		return av.barrow_pose(false).has("pos")
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


func select_tool(id: int) -> void:
	if not TOOLS.has(id) or av == null:
		return
	_end_drag()
	tool = id
	msg = ""
	if tool == BARROW:
		edit_crouch = false
	_show_barrow()
	if av.is_node_ready():
		av.set_target(Vector3.ZERO, _yaw, pitch, _av_tool(), 1.0 if crouch else 0.0, MOVES[move])
		_log_tool()
	_sync_ui()


func _log_tool() -> void:
	_logged = tool
	if tool == BARROW:
		var model: String = _const("BARROW_MODEL")
		print("[ToolPoser] tool 7 %s: %s loaded=%s pose=%s grips=%s" % [TOOLS[tool], model,
			_barrow != null, "saved" if has_pose() else "default", av.barrow_pose()])
		if _barrow == null:
			msg = "No se pudo cargar el modelo de la carretilla (%s)" % model
			_update_text()
		return
	var models: Dictionary = _const("TOOL_MODELS")
	var path: String = models.get(tool, "")
	var exists := path != "" and ResourceLoader.exists(path)
	var loaded := _holder() != null
	print("[ToolPoser] tool %d %s: %s exists=%s loaded=%s pose=%s" % [
		tool, TOOLS[tool], path, exists, loaded, "saved" if has_pose() else "auto"])
	if not loaded:
		msg = "No se pudo cargar el modelo de %s (%s)" % [TOOLS[tool], path]
		_update_text()


func reset_tool() -> void:
	_end_drag()
	if tool == BARROW:
		var bp: Dictionary = av.barrow_pose(false)
		if grip < 0:
			bp.erase("pos")
			bp.erase("rot")
			msg = "Carretilla en su pose por defecto"
		else:
			bp.erase("grip_l")
			bp.erase("grip_r")
			msg = "Agarres automáticos"
		av.set_barrow_pose(bp)
		dirty = true
		_sync_ui()
		return
	av.set_tool_pose(tool, {})
	dirty = true
	msg = "%s vuelve a automático" % TOOLS[tool]
	_sync_ui()


func save() -> void:
	var cfg := ConfigFile.new()
	var names: Array = _const("TOOL_NAMES")
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
		if p.has("crouch"):
			cfg.set_value(sec, "pos_crouch", p.crouch.pos)
			cfg.set_value(sec, "rot_crouch", p.crouch.rot)
			cfg.set_value(sec, "length_crouch", p.crouch.length)
			lines.append("    crouch pos=%s rot=%s length=%.3f" % [p.crouch.pos, p.crouch.rot, p.crouch.length])
	var bp: Dictionary = av.barrow_pose(false)
	if not bp.is_empty():
		var bsec: String = _const("BARROW_SECTION")
		for k in bp:
			cfg.set_value(bsec, k, bp[k])
		lines.append("[%s] %s" % [bsec, bp])
	var path := ProjectSettings.globalize_path(save_dir.path_join(OUT_FILE))
	var err := cfg.save(path)
	if err != OK:
		# mod folder not writable, keep it somewhere at least
		path = ProjectSettings.globalize_path("user://" + OUT_FILE)
		err = cfg.save(path)
	if err == OK:
		dirty = false
		msg = "Guardado en %s (%d herramientas)" % [path, lines.size()]
	else:
		msg = "Error %d al guardar" % err
	print("[ToolPoser] saved %s error=%d" % [path, err])
	for l in lines:
		print("[ToolPoser]   ", l)
	_update_text()


func _wrap(a: float) -> float:
	return wrapf(a, -180.0, 180.0)


func _angle_gap(a: Vector3, b: Vector3) -> float:
	return absf(_wrap(a.x - b.x)) + absf(_wrap(a.y - b.y)) + absf(_wrap(a.z - b.z))


# the same turn can be written two ways, keep the one nearer the old numbers
func _euler_near(b: Basis, near: Vector3) -> Vector3:
	var e := b.get_euler() * (180.0 / PI)
	var alt := Vector3(180.0 - e.x, e.y + 180.0, e.z + 180.0)
	e = Vector3(_wrap(e.x), _wrap(e.y), _wrap(e.z))
	alt = Vector3(_wrap(alt.x), _wrap(alt.y), _wrap(alt.z))
	return e if _angle_gap(e, near) <= _angle_gap(alt, near) else alt


# ---------------------------------------------------------------- camera

func reset_view() -> void:
	_target = HOME_TARGET
	_cam_yaw = 2.5
	_cam_pitch = -0.2
	_dist = 2.8


func frame_tool() -> void:
	if tool == BARROW and _barrow != null:
		# the farmer and the barrow, or up close on a grip
		_target = _grip_world(grip) if grip >= 0 else (av.global_position + _barrow.global_position) * 0.5 + Vector3(0, 0.6, 0)
		_dist = 1.2 if grip >= 0 else 3.4
		return
	var holder := _holder()
	if holder == null:
		return
	_target = holder.global_position
	_dist = clampf(float(current_pose().length) * 2.0, 1.0, 4.0)


func _update_cam() -> void:
	var b := Basis.from_euler(Vector3(_cam_pitch, _cam_yaw, 0.0))
	cam.global_transform = Transform3D(b, _target + b * Vector3(0.0, 0.0, _dist))
	# keep the pivot in the middle of the part the panel doesn't cover
	var vp := get_viewport().get_visible_rect().size
	var half_w := _dist * tan(deg_to_rad(cam.fov) * 0.5) * vp.x / maxf(vp.y, 1.0)
	cam.h_offset = half_w * (_panel.size.x + 12.0) / maxf(vp.x, 1.0) if _panel != null else 0.0


# right mouse held + WASD / QE, like the godot editor
func _fly(d: float) -> void:
	if not _orbit:
		return
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		dir.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		dir.x += 1.0
	var up := 0.0
	if Input.is_physical_key_pressed(KEY_E):
		up += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		up -= 1.0
	if dir == Vector3.ZERO and up == 0.0:
		return
	var speed := 6.0 if Input.is_key_pressed(KEY_SHIFT) else 1.5
	var step := cam.global_basis * dir + Vector3.UP * up
	_target += step.normalized() * speed * d


# metres per screen pixel at that point's depth
func _m_per_px(p: Vector3) -> float:
	var depth := maxf((p - cam.global_position).dot(-cam.global_basis.z), 0.05)
	var h := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	return 2.0 * depth * tan(deg_to_rad(cam.fov) * 0.5) / h


# ---------------------------------------------------------------- gizmo

# on the tool's centre, lined up with the hand, same size on screen at any zoom
func _update_gizmo() -> void:
	var holder := _holder()
	var hand: Node3D = av.get("_hand")
	_palm.visible = hand != null
	if hand != null:
		var ps := _m_per_px(hand.global_position) * 9.0
		_palm.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * ps), hand.global_position)
	var on_barrow := tool == BARROW and _barrow != null
	for i in _dots.size():
		var dot: MeshInstance3D = _dots[i]
		dot.visible = on_barrow
		if on_barrow:
			var at := _grip_world(i)
			var c := Color(1.0, 0.45, 0.1) if i == grip else Color(1, 1, 1, 0.85)
			(dot.material_override as StandardMaterial3D).albedo_color = c
			dot.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * _m_per_px(at) * 12.0), at)
	# the barrow moves in the farmer's axes, its grips in the barrow's
	var o := Vector3.ZERO
	var axes := Basis.IDENTITY
	if on_barrow:
		o = _barrow.global_position if grip < 0 else _grip_world(grip)
		axes = (av.global_basis if grip < 0 else _barrow.global_basis).orthonormalized()
	elif holder != null and hand != null:
		o = holder.global_position
		axes = hand.global_basis.orthonormalized()
	_gizmo.visible = on_barrow or (holder != null and hand != null)
	if not _gizmo.visible:
		_hover = -1
		return
	var s := _m_per_px(o) * ARROW_PX
	_gizmo.global_transform = Transform3D(axes * Basis.from_scale(Vector3.ONE * s), o)
	_arrows.visible = not _turning()
	_rings.visible = _turning()
	for a in 3:
		var c: Color = AXIS_COLORS[a]
		if a == _drag or (_drag < 0 and a == _hover):
			c = c.lerp(Color(1.0, 1.0, 0.6), 0.6)
		_mats[a].albedo_color = c


func _axes() -> Array:
	var gb := _gizmo.global_basis
	return [gb.x, gb.y, gb.z]


func _ring_point(a: int, t: float) -> Vector3:
	var ax := _axes()
	var u: Vector3 = ax[(a + 1) % 3]
	var v: Vector3 = ax[(a + 2) % 3]
	return _gizmo.global_position + (u * cos(t) + v * sin(t)) * RING


# picked in screen space: the handle nearest the mouse, within a few pixels
func pick(m: Vector2) -> int:
	if _gizmo == null or not _gizmo.visible or cam.is_position_behind(_gizmo.global_position):
		return -1
	var o := _gizmo.global_position
	var ax := _axes()
	var best := -1
	var best_d := PICK_PX
	for a in 3:
		var d := INF
		if not _turning():
			var p0 := cam.unproject_position(o + ax[a] * 0.12)
			var p1 := cam.unproject_position(o + ax[a])
			# pointing (nearly) straight at us, too twitchy to drag
			if p0.distance_to(p1) > ARROW_PX * 0.25:
				d = _seg_dist(m, p0, p1)
		else:
			var prev := cam.unproject_position(_ring_point(a, 0.0))
			for k in range(1, 49):
				var cur := cam.unproject_position(_ring_point(a, TAU * k / 48.0))
				d = minf(d, _seg_dist(m, prev, cur))
				prev = cur
		if d < best_d:
			best = a
			best_d = d
	return best


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p)


func _start_drag(m: Vector2) -> void:
	var a := pick(m)
	if a < 0:
		# a click on a grip dot picks that grip
		if tool == BARROW and _barrow != null:
			for i in _dots.size():
				var at := _grip_world(i)
				if not cam.is_position_behind(at) and cam.unproject_position(at).distance_to(m) < PICK_PX * 1.5:
					select_grip(i)
					return
		return
	var o := _gizmo.global_position
	var ax := _axes()
	if not _turning():
		# mouse travel along the arrow on screen, over its pixels per metre
		var p0 := cam.unproject_position(o)
		var p1 := cam.unproject_position(o + ax[a])
		_drag_dir = (p1 - p0).normalized()
		_drag_px = p0.distance_to(p1) / ax[a].length()
	else:
		# grab the ring where the mouse is and drag along its tangent there
		var t := 0.0
		var near := INF
		for k in 48:
			var q := cam.unproject_position(_ring_point(a, TAU * k / 48.0))
			if q.distance_to(m) < near:
				near = q.distance_to(m)
				t = TAU * k / 48.0
		var p := _ring_point(a, t)
		var tangent: Vector3 = ax[a].normalized().cross(p - o)  # where a positive turn moves it
		var q0 := cam.unproject_position(p)
		var q1 := cam.unproject_position(p + tangent * 0.05)
		if q0.distance_to(q1) > 0.5:
			_drag_dir = (q1 - q0).normalized()
		else:
			_drag_dir = (q0 - cam.unproject_position(o)).normalized().orthogonal()
		# a radian per ring radius of travel, the same seen flat or edge on
		_drag_px = RING * ARROW_PX
	_drag = a
	_drag_from = m
	_drag_pose = current_pose()


func _drag_to(m: Vector2) -> void:
	var amount := (m - _drag_from).dot(_drag_dir) / _drag_px
	var snap := Input.is_key_pressed(KEY_CTRL)
	var p := _drag_pose.duplicate()
	if not _turning():
		if snap:
			amount = snappedf(amount, 0.01)
		var pos: Vector3 = p.pos
		pos[_drag] += amount
		p.pos = pos
	else:
		if snap:
			amount = snappedf(amount, deg_to_rad(5.0))
		# turn around the hand's axis, then back to euler degrees
		var axis := Vector3.ZERO
		axis[_drag] = 1.0
		var b := Basis(axis, amount) * Basis.from_euler(p.rot * (PI / 180.0))
		p.rot = _euler_near(b, p.rot)
	_pending = p


func _end_drag() -> void:
	if _drag >= 0 and not _pending.is_empty():
		set_pose(_pending)
	_pending = {}
	_drag = -1


func set_mode(rot: bool) -> void:
	_end_drag()
	rotating = rot
	_sync_ui()


# ---------------------------------------------------------------- input

func _input(e: InputEvent) -> void:
	if not _opened or av == null:
		return
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo or k.ctrl_pressed or k.alt_pressed:
		return
	# typing a number into a box
	if get_viewport().gui_get_focus_owner() is LineEdit and k.keycode != KEY_F9:
		return
	var used := true
	match k.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
			select_tool(k.keycode - KEY_0)
		KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_7:
			select_tool(k.keycode - KEY_KP_0)
		KEY_G:
			# barrow -> left grip -> right grip -> barrow
			used = tool == BARROW
			if used:
				select_grip((grip + 2) % 3 - 1)
		KEY_W, KEY_E:
			# flying while the right button is down
			used = not _orbit
			if used:
				set_mode(k.keycode == KEY_E)
		KEY_F:
			frame_tool()
		KEY_C:
			set_stance(not (crouch if tool == BARROW else edit_crouch))
		KEY_R, KEY_HOME:
			reset_view()
		KEY_F9:
			save()
		KEY_ESCAPE:
			used = _drag >= 0
			if used:
				_pending = {}
				_drag = -1
				set_pose(_drag_pose)
		_:
			used = false
	if used:
		get_viewport().set_input_as_handled()


# mouse over the 3D view (the panel sits on top and takes its own clicks)
func _view_input(e: InputEvent) -> void:
	var b := e as InputEventMouseButton
	if b != null:
		if b.pressed:
			get_viewport().gui_release_focus()
		match b.button_index:
			MOUSE_BUTTON_LEFT:
				if b.pressed:
					_start_drag(b.position)
				else:
					_end_drag()
			MOUSE_BUTTON_RIGHT:
				_orbit = b.pressed
			MOUSE_BUTTON_MIDDLE:
				_pan = b.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if b.pressed:
					_dist = maxf(_dist * 0.9, 0.25)
			MOUSE_BUTTON_WHEEL_DOWN:
				if b.pressed:
					_dist = minf(_dist / 0.9, 40.0)
		_view.accept_event()
		return
	var mm := e as InputEventMouseMotion
	if mm == null:
		return
	if _drag >= 0:
		_drag_to(mm.position)
	elif _orbit:
		_cam_yaw -= mm.relative.x * 0.008
		_cam_pitch = clampf(_cam_pitch - mm.relative.y * 0.008, -1.5, 1.5)
	elif _pan:
		var k := _m_per_px(_target)
		_target += (-cam.global_basis.x * mm.relative.x + cam.global_basis.y * mm.relative.y) * k
	else:
		_hover = pick(mm.position)
	_view.accept_event()


# ---------------------------------------------------------------- ui

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)

	# catches the mouse for the 3D view, under the panel
	_view = Control.new()
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.gui_input.connect(_view_input)
	_view.mouse_exited.connect(func() -> void: _hover = -1)
	layer.add_child(_view)

	var help := _text(15)
	help.text = "\n".join([
		"Clic izq. en el gizmo: mover / rotar    Ctrl: a saltos    Esc: deshacer el arrastre",
		"W: mover    E: rotar    C: pose de pie / agachado    1-7: herramienta    F9: guardar",
		"Clic der.: orbitar    Clic central: desplazar    Rueda: zoom",
		"Clic der. + WASD / Q E: volar (Mayús: más rápido)    F: encuadrar    R: vista inicial",
		"Ejes de la mano: X derecha (rojo), Y arriba (verde), Z atrás (azul)",
		"Carretilla (7): ejes del granjero. G o clic en un punto blanco: mover un agarre",
	])
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	help.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(help)

	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -440
	panel.offset_right = -12
	panel.offset_top = 12
	layer.add_child(panel)
	_panel = panel
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	var title := _text(22)
	title.text = "Posicionador de herramientas"
	box.add_child(title)
	var tools := GridContainer.new()
	tools.columns = 3
	box.add_child(tools)
	var tool_group := ButtonGroup.new()
	for id in TOOLS:
		var btn := _button("%d  %s" % [id, TOOLS[id]], tool_group)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(select_tool.bind(id))
		tools.add_child(btn)
		_tool_btns[id] = btn
	_state = _text(16)
	box.add_child(_state)
	_unsaved = _text(16)
	_unsaved.text = "• sin guardar"
	_unsaved.add_theme_color_override("font_color", Color(1.0, 0.62, 0.2))
	box.add_child(_unsaved)

	box.add_child(HSeparator.new())
	var modes := HBoxContainer.new()
	box.add_child(modes)
	var ml := Label.new()
	ml.text = "Gizmo:"
	modes.add_child(ml)
	var mode_group := ButtonGroup.new()
	for i in 2:
		var btn := _button("Mover (W)" if i == 0 else "Rotar (E)", mode_group)
		btn.pressed.connect(set_mode.bind(i == 1))
		modes.add_child(btn)
		_mode_btns.append(btn)

	var stance := HBoxContainer.new()
	box.add_child(stance)
	var stl := Label.new()
	stl.text = "Pose:"
	stance.add_child(stl)
	var stance_group := ButtonGroup.new()
	for i in 2:
		var btn := _button("De pie" if i == 0 else "Agachado (C)", stance_group)
		btn.pressed.connect(set_stance.bind(i == 1))
		stance.add_child(btn)
		_stance_btns.append(btn)
	_drop_crouch = _button("Quitar agachado", null)
	_drop_crouch.tooltip_text = "Borra la pose de agachado, agachado usará la de pie"
	_drop_crouch.pressed.connect(drop_crouch)
	stance.add_child(_drop_crouch)
	_stance_row = stance

	# on the barrow, what the gizmo moves
	var grips := HBoxContainer.new()
	box.add_child(grips)
	var gl := Label.new()
	gl.text = "Mover (G):"
	grips.add_child(gl)
	var grip_group := ButtonGroup.new()
	for i in GRIPS.size():
		var btn := _button(GRIPS[i], grip_group)
		btn.pressed.connect(select_grip.bind(i - 1))
		grips.add_child(btn)
		_grip_btns.append(btn)
	_grip_row = grips

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
		sp.custom_minimum_size = Vector2(110, 0)
		sp.value_changed.connect(_on_field.bind(f))
		grid.add_child(sp)
		_rows[f] = [sl, sp]

	var btns := HBoxContainer.new()
	box.add_child(btns)
	var auto := _button("Automático", null)
	auto.tooltip_text = "Quita la pose de esta herramienta y usa el ajuste automático"
	auto.pressed.connect(reset_tool)
	btns.add_child(auto)
	var sv := _button("Guardar (F9)", null)
	sv.pressed.connect(save)
	btns.add_child(sv)

	box.add_child(HSeparator.new())
	var prev := _text(16)
	prev.text = "Vista previa"
	box.add_child(prev)
	var look := HBoxContainer.new()
	box.add_child(look)
	var ll := Label.new()
	ll.text = "Mirar"
	look.add_child(ll)
	_pitch_sl = HSlider.new()
	_pitch_sl.min_value = -80.0
	_pitch_sl.max_value = 80.0
	_pitch_sl.step = 1.0
	_pitch_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pitch_sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_pitch_sl.focus_mode = Control.FOCUS_NONE
	_pitch_sl.value_changed.connect(_on_pitch)
	look.add_child(_pitch_sl)
	_pitch_lbl = Label.new()
	_pitch_lbl.custom_minimum_size = Vector2(44, 0)
	look.add_child(_pitch_lbl)
	var moves := HBoxContainer.new()
	box.add_child(moves)
	var move_group := ButtonGroup.new()
	for i in MOVE_NAMES.size():
		var btn := _button(MOVE_NAMES[i], move_group)
		btn.pressed.connect(_on_move.bind(i))
		moves.add_child(btn)
		_move_btns.append(btn)
	var checks := HBoxContainer.new()
	box.add_child(checks)
	_crouch_cb = CheckBox.new()
	_crouch_cb.text = "Agachado"
	_crouch_cb.focus_mode = Control.FOCUS_NONE
	_crouch_cb.toggled.connect(func(on: bool) -> void:
		crouch = on
		if not on and edit_crouch:
			set_stance(false))
	checks.add_child(_crouch_cb)
	_turn_cb = CheckBox.new()
	_turn_cb.text = "Girar sobre sí mismo"
	_turn_cb.focus_mode = Control.FOCUS_NONE
	_turn_cb.toggled.connect(func(on: bool) -> void: turntable = on)
	checks.add_child(_turn_cb)

	_msg = _text(14)
	_msg.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_msg.custom_minimum_size = Vector2(400, 0)
	box.add_child(_msg)


func _button(txt: String, group: ButtonGroup) -> Button:
	var btn := Button.new()
	btn.text = txt
	btn.focus_mode = Control.FOCUS_NONE
	if group != null:
		btn.toggle_mode = true
		btn.button_group = group
	return btn


func _text(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	return l


func _on_field(v: float, field: String) -> void:
	if _syncing or av == null:
		return
	edit(field, v)


func _on_pitch(v: float) -> void:
	pitch = deg_to_rad(v)
	_pitch_lbl.text = "%d°" % int(v)


func _on_move(i: int) -> void:
	move = i


func _sync_ui() -> void:
	if av == null or _state == null:
		return
	var p := current_pose()
	var vals := {"px": p.pos.x, "py": p.pos.y, "pz": p.pos.z,
		"rx": p.rot.x, "ry": p.rot.y, "rz": p.rot.z, "len": p.length}
	# plain value sets so the spinbox text follows, the flag stops the loop
	_syncing = true
	# the barrow sits further out, has no length and its grips don't turn
	var on_barrow := tool == BARROW
	for f in _rows:
		var spec: Array = FIELDS[f]
		var wide: bool = on_barrow and f.begins_with("p")
		_rows[f][0].min_value = spec[1] * (2.0 if wide else 1.0)
		_rows[f][0].max_value = spec[2] * (2.0 if wide else 1.0)
		var off: bool = on_barrow and (f == "len" or (grip >= 0 and f.begins_with("r")))
		_rows[f][0].editable = not off
		_rows[f][1].editable = not off
	for f in _rows:
		_rows[f][0].value = vals[f]
		_rows[f][1].value = vals[f]
	_syncing = false
	_stance_row.visible = not on_barrow
	_grip_row.visible = on_barrow
	for i in _grip_btns.size():
		_grip_btns[i].set_pressed_no_signal(i - 1 == grip)
	for id in _tool_btns:
		_tool_btns[id].set_pressed_no_signal(id == tool)
	_mode_btns[0].set_pressed_no_signal(not rotating)
	_mode_btns[1].set_pressed_no_signal(rotating)
	for i in _move_btns.size():
		_move_btns[i].set_pressed_no_signal(i == move)
	_pitch_sl.set_value_no_signal(rad_to_deg(pitch))
	_pitch_lbl.text = "%d°" % roundi(rad_to_deg(pitch))
	_crouch_cb.set_pressed_no_signal(crouch)
	_stance_btns[0].set_pressed_no_signal(not edit_crouch)
	_stance_btns[1].set_pressed_no_signal(edit_crouch)
	_drop_crouch.disabled = not has_crouch_pose()
	_turn_cb.set_pressed_no_signal(turntable)
	_update_text()


func _update_text() -> void:
	if av == null or _state == null:
		return
	if tool == BARROW:
		_state.text = "%d  %s  ·  %s  ·  agarres: %s%s%s" % [tool, TOOLS[tool],
			"pose a mano" if has_pose() else "por defecto",
			"a mano" if has_grips() else "automáticos",
			"" if grip < 0 else "
MOVIENDO EL %s" % GRIPS[grip + 1].to_upper(),
			"" if _barrow != null else "
¡modelo no encontrado!"]
		_unsaved.visible = dirty
		_msg.text = msg
		return
	var loaded := _holder() != null or not av.is_node_ready()
	_state.text = "%d  %s  ·  %s  ·  agachado: %s%s%s" % [tool, TOOLS[tool],
		"pose a mano" if has_pose() else "automático",
		"propia" if has_crouch_pose() else "usa la de pie",
		"\nEDITANDO LA POSE DE AGACHADO" if edit_crouch else "",
		"" if loaded else "\n¡modelo no encontrado!"]
	_unsaved.visible = dirty
	_msg.text = msg


func _notification(what: int) -> void:
	if mp == null:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
