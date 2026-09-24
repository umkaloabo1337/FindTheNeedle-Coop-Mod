# Live tuning for the remote-player farmer. Starts a throwaway game and puts a
# "mirror" farmer in front of you that copies your look, crouch and tool.
#
#   standing:  Up/Down (or PgUp/PgDn) change the model height, 1 cm a step
#   crouched:  the same keys change how far it sinks when crouching
#   Shift = 5 cm steps, R = bring it in front again, F9 = save
#
# Saved values go to user://avatar_calib.txt and the console; copy them into
# MODEL_HEIGHT and CROUCH_DROP in mp_avatar.gd.
#
# To use it, add a second autoload to the game's override.cfg under MPMod:
#   AvatarCalib="*C:/path/to/dev/avatar_calib.gd"
# and remove it again when done. Your own saves are not touched.
extends Node

const OUT := "user://avatar_calib.txt"
const EYE_FRAC := 0.914  # the eyes sit at this fraction of the model height

var mp: Node
var _t := 0.0
var _started := false
var av: Node3D
var spot := Vector3.ZERO
var height := 1.89
var base_h := 1.89
var holder: Node3D
var base_scale := Vector3.ONE
var base_y := 0.0
var cam_stand := 1.66
var label: Label
var saved_msg := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mp = get_node_or_null("/root/MPMod")
	if mp == null:
		queue_free()
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = Vector2i(1600, 900)
	w.title = "Find The Needle - AJUSTE DEL AVATAR"
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	label = Label.new()
	label.position = Vector2(20, 230)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 8)
	layer.add_child(label)


func _process(d: float) -> void:
	_t += d
	var cs := get_tree().current_scene
	if not _started and cs != null and cs.name == "MainMenu" and _t > 4.0:
		_started = true
		var sm := get_node("/root/SaveManager")
		sm.use_scratch_dir("user://avatar_calib")
		sm.begin_new_game(0, true)
		get_node("/root/Loading").enter_scene(mp.GAME_SCENE)
	if mp.world_sync == null:
		av = null
		return
	var p: Node3D = mp.world_sync.player
	if av == null or not is_instance_valid(av):
		_spawn(p)
		return
	var to := p.global_position - spot
	var pitch := float(p.get("_pitch")) if p.get("_pitch") != null else 0.0
	var tool := int(p.get("current_tool")) if p.get("current_tool") != null else 0
	av.set_target(spot, atan2(-to.x, -to.z), pitch, tool, _crouch(p), 0.0)
	var cam := get_viewport().get_camera_3d()
	var cam_h := cam.global_position.y - p.global_position.y if cam else 0.0
	if _crouch(p) < 0.1:
		cam_stand = cam_h
	var mode := "AGACHADO: las flechas cambian cuanto baja" if _crouch(p) > 0.5 else "DE PIE: las flechas cambian la altura"
	label.text = "%s\n\naltura: %.2f m   (ojos a ~%.2f m)\nbajada al agacharse: %.2f m\ntu camara: %.2f m   (baja %.2f m al agacharte)\n\nFlechas o RePag/AvPag +-1 cm (Shift 5 cm)   R: traerlo   F9: guardar\n%s" % [
		mode, height, height * EYE_FRAC, float(av.get("crouch_drop")), cam_h, cam_stand - cam_h, saved_msg]


func _crouch(p: Node) -> float:
	return float(p.call("crouch_amount")) if p.has_method("crouch_amount") else 0.0


func _spawn(p: Node3D) -> void:
	await get_tree().create_timer(2.0).timeout
	if av != null:
		return
	av = load(mp.base_dir + "/mp_avatar.gd").new()
	av.setup("Espejo", Color(0.3, 0.65, 0.98))
	mp.world_sync.world.add_child(av)
	# start in the open yard by the pile, not facing the loading door
	var world: Node = mp.world_sync.world
	var open_spot := Vector3(9.6, 0.0, 12.0)
	p.global_position = world._seat(open_spot) if world.has_method("_seat") else open_spot
	if p.has_method("set_look"):
		p.set_look(0.0, 0.0)
	await get_tree().process_frame
	_bring(p)
	av.set_target(spot, 0.0, 0.0, 0, 0.0, 0.0)
	await get_tree().process_frame
	var body: Node3D = av.get("_body")
	if body != null and body.get_child_count() > 0:
		holder = body.get_child(0)
		base_scale = holder.scale
		base_y = holder.position.y
		base_h = float(av.get_script().get_script_constant_map().get("MODEL_HEIGHT", 1.89))
		height = base_h


func _bring(p: Node3D) -> void:
	var fwd := -p.global_basis.z
	fwd.y = 0.0
	spot = p.global_position + fwd.normalized() * 1.6
	if mp.world_sync.world.has_method("_seat"):
		spot = mp.world_sync.world._seat(spot)


func _apply_height() -> void:
	if holder == null:
		return
	var f := height / base_h
	holder.scale = base_scale * f
	holder.position.y = base_y * f


func _input(e: InputEvent) -> void:
	if not (e is InputEventKey) or not e.pressed or av == null:
		return
	var step := 0.05 if e.shift_pressed else 0.01
	var dir := 0.0
	match e.keycode:
		KEY_UP, KEY_PAGEUP:
			dir = 1.0
		KEY_DOWN, KEY_PAGEDOWN:
			dir = -1.0
		KEY_R:
			_bring(mp.world_sync.player)
		KEY_F9:
			_save()
	if dir == 0.0:
		return
	if _crouch(mp.world_sync.player) > 0.5:
		av.set("crouch_drop", maxf(0.0, snappedf(float(av.get("crouch_drop")) + dir * step, 0.01)))
	else:
		height = snappedf(height + dir * step, 0.01)
		_apply_height()


func _save() -> void:
	var line := "MODEL_HEIGHT=%.2f CROUCH_DROP=%.2f" % [height, float(av.get("crouch_drop"))]
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f != null:
		f.store_line(line)
		f.close()
	saved_msg = ">> GUARDADO: " + line
	print("[AvatarCalib] ", line, " -> ", ProjectSettings.globalize_path(OUT))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://session.lock"))
